// SPDX-License-Identifier: AGPL-3.0-or-later
// Builds an offline bundle from the output of tools/build/build.mjs (dist/site).
//
//   node tools/build/bundle.mjs <package>... [--name <bundle name>] [--chunk <chars>]
//
// The named packages plus everything they require are packed together with the registry index entries and every
// payload. Writes dist/bundles/<name>.tsrbundle (drag-and-drop file) and dist/bundles/<name>.txt (numbered TSR1 lines
// for pasting). With no package names the whole registry is bundled.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { root } from '../lib/craftos.mjs';
import { KIND, buildContainer, toChunks, toFile } from '../lib/bundle.mjs';

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const flagged = new Set(['--name', '--chunk']);
const wanted = args.filter((a, i) => !a.startsWith('--') && !flagged.has(args[i - 1]));

const site = join(root, 'dist', 'site');
if (!existsSync(join(site, 'registry', 'index.json'))) {
  console.error('dist/site not found - run tools/build/build.mjs first');
  process.exit(1);
}
const index = JSON.parse(readFileSync(join(site, 'registry', 'index.json'), 'utf8'));
const pkgDoc = (n) => JSON.parse(readFileSync(join(site, 'registry', 'packages', `${n}.json`), 'utf8'));

const names = new Set();
const visit = (n) => {
  if (names.has(n)) return;
  if (!index.packages[n]) throw new Error(`unknown package ${n}`);
  names.add(n);
  const doc = pkgDoc(n);
  for (const dep of Object.keys(doc.versions[doc.latest].requires ?? {})) {
    if (index.packages[dep]) visit(dep);
  }
};
for (const n of wanted.length ? wanted : Object.keys(index.packages)) visit(n);

const entries = [];
const subIndex = { format: 1, packages: {} };
const blobs = new Set();
for (const n of [...names].sort()) {
  subIndex.packages[n] = index.packages[n];
  const doc = pkgDoc(n);
  entries.push({ kind: KIND.package, name: n, data: JSON.stringify(doc) });
  for (const f of doc.versions[doc.latest].files) blobs.add(f.sha256);
}
entries.unshift({ kind: KIND.index, name: 'index', data: JSON.stringify(subIndex) });
for (const sha of [...blobs].sort()) {
  entries.push({ kind: KIND.blob, name: sha, data: readFileSync(join(site, 'blobs', sha)) });
}

const container = buildContainer(entries);
const name = opt('--name', wanted.length ? wanted.join('+') : 'full');
const outDir = join(root, 'dist', 'bundles');
mkdirSync(outDir, { recursive: true });
const file = toFile(container);
writeFileSync(join(outDir, `${name}.tsrbundle`), file);
const { id, lines } = toChunks(container, Number(opt('--chunk', 400)));
writeFileSync(join(outDir, `${name}.txt`), lines.join('\n') + '\n');
console.log(`bundle ${name}: ${names.size} packages, ${blobs.size} payloads, ${file.length} bytes file, ${lines.length} paste lines (id ${id})`);
