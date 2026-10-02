// SPDX-License-Identifier: AGPL-3.0-or-later
// Generates the API reference (docs/api/*.md) from the documentation comments in the Lua sources: the `---` lines above a public
// function become its description, the first comment block of a file its overview.
//   node tools/docs/apidoc.mjs            write docs/api
//   node tools/docs/apidoc.mjs --check    fail when docs/api is out of date (used by CI)
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { packageNames, root } from '../lib/craftos.mjs';

const LIB_ROOTS = [['root', 'sys', 'lib'], ['root', 'usr', 'lib']];

const walk = (dir) => (existsSync(dir) ? readdirSync(dir).flatMap((n) => {
  const p = join(dir, n);
  return statSync(p).isDirectory() ? walk(p) : [p];
}) : []);

/** "src/core/root/sys/lib/tsr/vfs.lua" -> "tsr.vfs";  ".../tsr/net/init.lua" -> "tsr.net" */
export function moduleName(file, libRoot) {
  let rel = relative(libRoot, file).split(sep).join('/').replace(/\.lua$/, '');
  rel = rel.replace(/\/init$/, '');
  return rel.replace(/\//g, '.');
}

/** The overview (leading comment block after the SPDX line) and the documented public functions of one Lua file. */
export function parseLua(text) {
  const lines = text.split(/\r?\n/);
  const overview = [];
  let i = 0;
  if (lines[0]?.startsWith('-- SPDX')) i = 1;
  while (i < lines.length && lines[i].startsWith('--') && !lines[i].startsWith('---')) { overview.push(lines[i].replace(/^--\s?/, '')); i++; }
  const functions = [];
  for (let n = 0; n < lines.length; n++) {
    const m = lines[n].match(/^function\s+([A-Za-z_][\w]*)([.:])([A-Za-z_][\w]*)\s*\(([^)]*)\)/);
    if (!m) continue;
    const [, owner, sep2, name, params] = m;
    if (name.startsWith('_')) continue;
    const doc = [];
    let k = n - 1;
    while (k >= 0 && lines[k].startsWith('---')) { doc.unshift(lines[k].replace(/^---\s?/, '')); k--; }
    if (doc.length === 0) continue;
    functions.push({ owner, name, params: params.trim(), method: sep2 === ':', doc: doc.join('\n') });
  }
  return { overview: overview.join('\n').trim(), functions };
}

function render(name, pkg, parsed) {
  const out = [`# ${name}`, '', `Package: \`${pkg}\``, ''];
  if (parsed.overview) out.push(parsed.overview.split('\n').map((l) => l).join('\n'), '');
  for (const f of parsed.functions) {
    const sig = `${f.owner}${f.method ? ':' : '.'}${f.name}(${f.params})`;
    out.push(`## \`${sig}\``, '', f.doc, '');
  }
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n';
}

/** Build the whole reference: { "tsr.vfs.md": text, ..., "index.md": text }. */
export function build() {
  const pages = {};
  const index = {};
  for (const pkg of packageNames()) {
    for (const parts of LIB_ROOTS) {
      const libRoot = join(root, 'src', pkg, ...parts);
      for (const file of walk(libRoot).filter((f) => f.endsWith('.lua')).sort()) {
        const parsed = parseLua(readFileSync(file, 'utf8'));
        if (parsed.functions.length === 0) continue;
        const name = moduleName(file, libRoot);
        pages[`${name}.md`] = render(name, pkg, parsed);
        (index[pkg] ??= []).push({ name, count: parsed.functions.length });
      }
    }
  }
  const lines = ['# Tessera API reference', '',
    'Generated from the documentation comments in the sources (`node tools/docs/apidoc.mjs`). Load a module with `require("<module>")`',
    '(or `tsr.require`). Only documented public functions are listed; the module overviews explain how they fit together.', ''];
  for (const pkg of Object.keys(index).sort()) {
    lines.push(`## Package \`${pkg}\``, '');
    for (const m of index[pkg]) lines.push(`- [${m.name}](${m.name}.md) (${m.count} functions)`);
    lines.push('');
  }
  pages['index.md'] = lines.join('\n').trimEnd() + '\n';
  return pages;
}

const isMain = process.argv[1] && process.argv[1].endsWith('apidoc.mjs');
if (isMain) {
  const dir = join(root, 'docs', 'api');
  const pages = build();
  if (process.argv.includes('--check')) {
    const stale = [];
    for (const [n, t] of Object.entries(pages)) if (!existsSync(join(dir, n)) || readFileSync(join(dir, n), 'utf8') !== t) stale.push(n);
    if (existsSync(dir)) for (const n of readdirSync(dir)) if (!(n in pages)) stale.push(n + ' (no longer generated)');
    if (stale.length) { console.error('docs/api is out of date; run: node tools/docs/apidoc.mjs\n  ' + stale.slice(0, 10).join('\n  ')); process.exit(1); }
    console.log(`docs/api is up to date (${Object.keys(pages).length} pages)`);
  } else {
    rmSync(dir, { recursive: true, force: true });
    mkdirSync(dir, { recursive: true });
    for (const [n, t] of Object.entries(pages)) writeFileSync(join(dir, n), t);
    console.log(`wrote ${Object.keys(pages).length} pages to docs/api`);
  }
}
