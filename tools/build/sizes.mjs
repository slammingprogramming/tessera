// SPDX-License-Identifier: AGPL-3.0-or-later
// Size report against the limits of real ComputerCraft computers, and a guard that fails when a limit is exceeded.
//   node tools/build/sizes.mjs        (needs dist/ from tools/build/build.mjs)
// Limits: a computer's disk is 1,000,000 bytes by default, a floppy about 125,000, the clipboard paste route is practical up to a few
// hundred lines. The budgets below are what we promise users: the installer fits on a floppy with room for the bundle, and the
// base system leaves most of the disk free.
import { existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { root } from '../lib/craftos.mjs';

const DISK = 1_000_000;
const FLOPPY = 125_000;
const LIMITS = {
  installer: 40_000,                 // install.lua alone
  floppyKit: 100_000,                // install.lua + the offline bundle of core + pkg (compressed)
  baseInstalled: 200_000,            // core + pkg + installer + ui-tui + shell, installed and minified
  pasteLines: 150,                   // lines to paste for the base bundle at the default chunk size
};

const site = join(root, 'dist', 'site');
if (!existsSync(join(site, 'registry', 'index.json'))) { console.error('dist/site not found - run tools/build/build.mjs first'); process.exit(1); }
const index = JSON.parse(readFileSync(join(site, 'registry', 'index.json'), 'utf8'));

const rows = [];
const check = (name, value, limit, unit = 'B') => rows.push({ name, value, limit, ok: value <= limit, unit });

const installer = statSync(join(site, 'install.lua')).size;
check('install.lua', installer, LIMITS.installer);

const sizeOf = (names) => names.reduce((s, n) => s + (index.packages[n]?.size ?? 0), 0);
const base = ['core', 'pkg', 'installer', 'ui-tui', 'shell'].filter((n) => index.packages[n]);
check(`installed size of ${base.join('+')}`, sizeOf(base), LIMITS.baseInstalled);

const bundle = join(root, 'dist', 'bundles', 'boot.tsrbundle');
if (existsSync(bundle)) {
  const bundleSize = statSync(bundle).size;
  check('floppy kit (install.lua + core/pkg bundle)', installer + bundleSize, Math.min(LIMITS.floppyKit, FLOPPY));
  const txt = join(root, 'dist', 'bundles', 'boot.txt');
  if (existsSync(txt)) check('paste lines for core+pkg', readFileSync(txt, 'utf8').split('\n').filter(Boolean).length, LIMITS.pasteLines, ' lines');
}

let all = 0;
for (const e of Object.values(index.packages)) all += e.size ?? 0;
rows.push({ name: `every package installed (${Object.keys(index.packages).length})`, value: all, limit: DISK, ok: all < DISK * 0.9, unit: 'B', info: true });

console.log('size report');
for (const r of rows) {
  const pct = ((r.value / r.limit) * 100).toFixed(0);
  console.log(` ${r.ok ? ' ok ' : 'FAIL'}  ${r.name.padEnd(52)} ${String(r.value).padStart(8)}${r.unit} of ${r.limit}${r.unit}  (${pct}%)${r.info ? '  [for information: a disk is 1 MB]' : ''}`);
}
const bad = rows.filter((r) => !r.ok && !r.info);
if (bad.length) { console.error(`\n${bad.length} size limit(s) exceeded`); process.exit(1); }
