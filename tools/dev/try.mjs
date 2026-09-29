// SPDX-License-Identifier: AGPL-3.0-or-later
// Opens a CraftOS-PC window so you can try Tessera by hand.
//
//   node tools/dev/try.mjs            fresh empty computer + the built site mounted at /site and bundles at /bundles.
//                                     In the emulator run:   /site/install.lua /site
//                                     (offline paths:        /site/install.lua --bundle /bundles/boot.tsrbundle)
//   node tools/dev/try.mjs --installed  Tessera already installed (all package files copied in), boots straight into it
//   node tools/dev/try.mjs --keep       reuse the previous computer instead of starting fresh
//
// Everything lives under .scratch/try (git-ignored); your normal CraftOS-PC computers are never touched.
import { spawn, spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { root, installOverlays } from '../lib/craftos.mjs';

const args = process.argv.slice(2);
const installed = args.includes('--installed');
const keep = args.includes('--keep');

const gui = ['C:\\Program Files\\CraftOS-PC\\CraftOS-PC.exe', 'C:\\Program Files (x86)\\CraftOS-PC\\CraftOS-PC.exe', '/usr/bin/craftos']
  .find((p) => existsSync(p));
if (!gui) { console.error('CraftOS-PC GUI executable not found'); process.exit(2); }

for (const cmd of [['build/build.mjs'], ['build/bundle.mjs', '--name', 'boot', 'core', 'pkg'], ['build/bundle.mjs', '--name', 'full']]) {
  const r = spawnSync(process.execPath, [join(root, 'tools', ...cmd[0].split('/')), ...cmd.slice(1)], { encoding: 'utf8' });
  if (r.status !== 0) { console.error(r.stdout + r.stderr); process.exit(1); }
}

const work = join(root, '.scratch', 'try');
const computer = join(work, 'computer', '0');
if (!keep) rmSync(work, { recursive: true, force: true });
mkdirSync(computer, { recursive: true });
if (installed && !keep) {
  installOverlays(computer);
  mkdirSync(join(computer, 'etc', 'tsr'), { recursive: true });
  writeFileSync(join(computer, 'etc', 'tsr', 'system.cfg'),
    '{ pkg = { sources = { { name = "mirror", type = "dir", path = "/site" } } } }');
}

const cli = ['-d', work, '--id', '0',
  '--mount-ro', `site=${join(root, 'dist', 'site')}`, '--mount-ro', `bundles=${join(root, 'dist', 'bundles')}`];
spawn(gui, cli, { detached: true, stdio: 'ignore' }).unref();
console.log(installed
  ? 'Opened CraftOS-PC with Tessera installed. Hold R at the banner to skip it; /site is the local package mirror.'
  : 'Opened an empty CraftOS-PC computer. Run:  /site/install.lua /site');
console.log(`computer files: ${dirname(computer)}`);
