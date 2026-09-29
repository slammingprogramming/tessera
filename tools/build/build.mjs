// SPDX-License-Identifier: AGPL-3.0-or-later
// Builds the static site that GitHub Pages serves (registry + content-addressed blobs + bootstrap installer) and a
// minified overlay used for testing.
//
//   node tools/build/build.mjs [--no-minify] [--check-only]
//
// Output (dist/, git-ignored):
//   dist/overlay/                      merged, minified overlay of all packages (what a full install would contain)
//   dist/site/registry/index.json      { format, generated, packages: { name: { version, type, description, size } } }
//   dist/site/registry/packages/<name>.json   { name, latest, versions: { "<v>": <manifest> } }
//   dist/site/blobs/<sha256>           file payloads (minified), content-addressed
//   dist/site/install.lua              bootstrap installer (from src/installer/site/install.lua when present)
//   dist/site/mirrors.json             backup channel ids (pastebin etc.), maintained by hand / release tooling
//
// Package layout: src/<pkg>/package.json (metadata) + src/<pkg>/root/** (files installed to the same path on device).
// Fails (exit 1) when a package exceeds its `budget` (bytes installed, minified) or lacks required metadata.
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { deflateRawSync } from 'node:zlib';
import { root, packageNames } from '../lib/craftos.mjs';
import { tryGit } from '../lib/git.mjs';
import { minifyLua } from './minify.mjs';

const args = process.argv.slice(2);
const noMinify = args.includes('--no-minify');
const dist = join(root, 'dist');
const config = JSON.parse(readFileSync(join(root, 'tools', 'build', 'config.json'), 'utf8'));
// In GitHub Actions the real repository is known: derive the URLs so a fork/rename needs no config edits.
if (process.env.GITHUB_REPOSITORY) {
  const [owner, repo] = process.env.GITHUB_REPOSITORY.split('/');
  config.repo = `https://github.com/${owner}/${repo}`;
  config.pagesBase = `https://${owner.toLowerCase()}.github.io/${repo}`;
}

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const walk = (dir) => readdirSync(dir).flatMap((n) => {
  const p = join(dir, n);
  return statSync(p).isDirectory() ? walk(p) : [p];
});

const PLACEHOLDERS = [
  ['https://OWNER.github.io/REPO', config.pagesBase],
  ['https://github.com/OWNER/REPO', config.repo],
  ['@PASTEBIN_SNAPSHOT@', config.pastebinSnapshot ?? ''],
];
/** Replace release placeholders in a text payload. */
function substitute(text) {
  let out = text;
  for (const [from, to] of PLACEHOLDERS) if (to && from !== to) out = out.split(from).join(to);
  return out;
}

/** Find src/<pkg>/root/sys/lib/<module path>.lua for a module name like "tsr.hash". */
function moduleSource(name) {
  const rel = ['root', 'sys', 'lib', ...name.split('.')];
  const last = rel.pop() + '.lua';
  for (const pkg of packageNames()) {
    const p = join(root, 'src', pkg, ...rel, last);
    if (existsSync(p)) return readFileSync(p, 'utf8');
  }
  throw new Error(`cannot inline unknown module ${name}`);
}

/** Expand a `--@inline tsr.a tsr.b` line into a tiny module table + require shim holding those modules. */
function inlineModules(src) {
  return src.replace(/^--@inline (.+)$/m, (_, list) => {
    const NL = '\n';
    const names = list.trim().split(/\s+/);
    // `require` is declared BEFORE the module bodies so their own require() calls resolve to the shim below
    let out = 'local __inline, __loaded = {}, {}' + NL + 'local __outerRequire = require' + NL + 'local require' + NL;
    for (const n of names) {
      out += `__inline[${JSON.stringify(n)}] = function(...)` + NL + minifyLua(moduleSource(n)) + NL + 'end' + NL;
    }
    out += ['require = function(n)',
      '  if __loaded[n] ~= nil then return __loaded[n] end',
      '  local f = __inline[n]',
      '  if f then local v = f(n) if v == nil then v = true end __loaded[n] = v return v end',
      '  return __outerRequire(n)',
      'end'].join(NL);
    return out;
  });
}

rmSync(dist, { recursive: true, force: true });
mkdirSync(join(dist, 'site', 'blobs'), { recursive: true });
mkdirSync(join(dist, 'site', 'registry', 'packages'), { recursive: true });
mkdirSync(join(dist, 'overlay'), { recursive: true });

const commit = tryGit(['rev-parse', '--verify', 'refs/heads/main']) ?? tryGit(['rev-parse', 'HEAD']) ?? 'unknown';
const errors = [];
const index = { format: 1, generated: new Date().toISOString(), packages: {} };
let totalInstalled = 0;

for (const name of packageNames()) {
  const meta = JSON.parse(readFileSync(join(root, 'src', name, 'package.json'), 'utf8'));
  for (const k of ['name', 'version', 'type', 'description', 'license']) {
    if (!meta[k]) errors.push(`${name}: package.json is missing "${k}"`);
  }
  if (meta.name !== name) errors.push(`${name}: package.json name "${meta.name}" does not match its directory`);
  const overlayDir = join(root, 'src', name, 'root');
  const files = [];
  let installed = 0;
  let download = 0;
  if (existsSync(overlayDir)) {
    for (const file of walk(overlayDir).sort()) {
      const rel = '/' + relative(overlayDir, file).split(sep).join('/');
      let data = readFileSync(file);
      if (rel.endsWith('.lua')) {
        try {
          const text = substitute(data.toString('utf8'));
          data = Buffer.from(noMinify ? text : minifyLua(text), 'utf8');
        } catch (e) { errors.push(`${name}: ${rel}: ${e.message}`); continue; }
      }
      const hash = sha256(data);
      writeFileSync(join(dist, 'site', 'blobs', hash), data);
      const dest = join(dist, 'overlay', ...rel.split('/').filter(Boolean));
      mkdirSync(join(dest, '..'), { recursive: true });
      writeFileSync(dest, data);
      files.push({ path: rel, sha256: hash, size: data.length });
      installed += data.length;
      download += deflateRawSync(data).length;
    }
  }
  if (meta.budget && installed > meta.budget) {
    errors.push(`${name}: installed size ${installed} B exceeds budget ${meta.budget} B`);
  }
  totalInstalled += installed;
  const manifest = {
    format: 1,
    name,
    version: meta.version,
    type: meta.type,
    description: meta.description,
    requires: meta.requires ?? {},
    provides: meta.provides ?? [],
    conflicts: meta.conflicts ?? [],
    platforms: meta.platforms ?? {},
    license: meta.license,
    source: { repo: config.repo, commit, path: `src/${name}` },
    size: { installed, download },
    files,
    ...(meta.hooks ? { hooks: meta.hooks } : {}),
    ...(meta.lazy ? { lazy: meta.lazy } : {}),
  };
  writeFileSync(join(dist, 'site', 'registry', 'packages', `${name}.json`),
    JSON.stringify({ name, latest: meta.version, versions: { [meta.version]: manifest } }));
  index.packages[name] = { version: meta.version, type: meta.type, description: meta.description, size: installed, provides: meta.provides ?? [] };
  console.log(`${name.padEnd(24)} ${meta.version.padEnd(8)} ${String(files.length).padStart(3)} files  ${String(installed).padStart(7)} B installed  ${String(download).padStart(7)} B deflated`);
}

writeFileSync(join(dist, 'site', 'registry', 'index.json'), JSON.stringify(index));
const mirrorsPath = join(root, 'tools', 'build', 'mirrors.json');
writeFileSync(join(dist, 'site', 'mirrors.json'), existsSync(mirrorsPath) ? readFileSync(mirrorsPath) : '{"pastebin":{}}');
const installer = join(root, 'src', 'installer', 'site', 'install.lua');
if (existsSync(installer)) {
  const src = substitute(inlineModules(readFileSync(installer, 'utf8')));
  writeFileSync(join(dist, 'site', 'install.lua'), noMinify ? src : minifyLua(src));
}
const siteAssets = join(root, 'site');
if (existsSync(siteAssets)) {
  cpSync(siteAssets, join(dist, 'site'), { recursive: true });
  for (const f of readdirSync(siteAssets)) {
    if (/\.(html|txt|md|json)$/.test(f)) {
      const p = join(dist, 'site', f);
      writeFileSync(p, substitute(readFileSync(p, 'utf8')));
    }
  }
}

console.log(`\ntotal installed size (all packages, minified): ${totalInstalled} B`);
if (errors.length) {
  console.error('\nBUILD FAILED:\n  ' + errors.join('\n  '));
  process.exit(1);
}
