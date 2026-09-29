// SPDX-License-Identifier: AGPL-3.0-or-later
// Runs the Lua test-suites inside headless CraftOS-PC.
//
//   node tools/test/run.mjs [--filter <substr>] [--e2e] [--minified] [--keep] [--timeout <s>] [--verbose]
//
//   (default)   unit tests: every /tests/**/*_test.lua is run by tests/harness.lua inside a computer that has all
//               package overlays installed.
//   --e2e       boot test: the computer boots Tessera for real (/startup.lua) with tests/e2e/*.lua installed as init.d
//               daemons; those scripts drive the system and write the results.
//   --bootstrap installer test: builds the site, makes offline bundles, and runs tests/e2e/bootstrap_e2e.lua on a
//               computer with nothing installed (mounts: /site = dist/site, /bundles = dist/bundles).
//   --minified  install the minified build output (dist/overlay, produced by tools/build) instead of raw sources.
//
// A fresh emulated computer is built under .scratch/cpc; results come back through a mounted directory
// (.scratch/out -> /out) because the emulator's stdout is only a terminal dump.
import { spawn, spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { findCraftOS, installOverlays, root } from '../lib/craftos.mjs';

const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };

async function main() {
  const exe = findCraftOS();
  if (!exe) { console.error('CraftOS-PC not found (set TSR_CRAFTOS to the console executable)'); process.exit(2); }
  const e2e = flag('--e2e');
  const bootstrap = flag('--bootstrap');

  const work = join(root, '.scratch', 'cpc');
  const out = join(root, '.scratch', 'out');
  rmSync(work, { recursive: true, force: true });
  rmSync(out, { recursive: true, force: true });
  const computer = join(work, 'computer', '0');
  mkdirSync(computer, { recursive: true });
  mkdirSync(out, { recursive: true });

  if (bootstrap) {
    for (const cmd of [['build/build.mjs'], ['build/bundle.mjs', 'core', 'pkg', '--name', 'boot']]) {
      const r = spawnSync(process.execPath, [join(root, 'tools', ...cmd[0].split('/')), ...cmd.slice(1)], { encoding: 'utf8' });
      if (r.status !== 0) { console.error(r.stdout + r.stderr); process.exit(1); }
    }
  } else if (flag('--minified')) {
    const r = spawnSync(process.execPath, [join(root, 'tools', 'build', 'build.mjs')], { encoding: 'utf8' });
    if (r.status !== 0) { console.error(r.stdout + r.stderr); process.exit(1); }
    cpSync(join(root, 'dist', 'overlay'), computer, { recursive: true });
  } else {
    installOverlays(computer);
  }
  cpSync(join(root, 'tests'), join(computer, 'tests'), { recursive: true });
  if (e2e) {
    const dir = join(computer, 'etc', 'tsr', 'init.d');
    mkdirSync(dir, { recursive: true });
    for (const f of readdirSync(join(root, 'tests', 'e2e'))) {
      if (f.endsWith('.lua') && !f.startsWith('bootstrap')) cpSync(join(root, 'tests', 'e2e', f), join(dir, f));
    }
  }
  writeFileSync(join(out, 'config.json'), JSON.stringify({ filter: opt('--filter', null) }));

  const timeout = Number(opt('--timeout', 120)) * 1000;
  const cliArgs = ['--headless', '-d', work, '--id', '0', '--mount-rw', `out=${out}`];
  if (bootstrap) {
    cliArgs.push('--mount-ro', `site=${join(root, 'dist', 'site')}`, '--mount-ro', `bundles=${join(root, 'dist', 'bundles')}`,
      '--script', join(root, 'tests', 'e2e', 'bootstrap_e2e.lua'));
  } else if (!e2e) cliArgs.push('--script', join(root, 'tests', 'harness.lua'));
  const child = spawn(exe, cliArgs, { stdio: 'ignore', windowsHide: true });

  const timedOut = await new Promise((resolve) => {
    const timer = setTimeout(() => { child.kill(); resolve(true); }, timeout);
    child.on('exit', () => { clearTimeout(timer); resolve(false); });
    child.on('error', (e) => { clearTimeout(timer); console.error(e.message); resolve(false); });
  });

  const resultsPath = join(out, 'results.json');
  if (!existsSync(resultsPath)) {
    console.error(timedOut ? `FAIL: emulator timed out after ${timeout / 1000}s` : 'FAIL: no results were written');
    const log = join(computer, 'var', 'log', 'tsr.log');
    if (existsSync(log)) console.error('--- /var/log/tsr.log ---\n' + readFileSync(log, 'utf8'));
    process.exit(1);
  }
  const res = JSON.parse(readFileSync(resultsPath, 'utf8'));
  for (const f of res.files ?? []) {
    const bad = f.tests.filter((t) => !t.ok);
    console.log(`${bad.length ? 'FAIL' : ' ok '}  ${f.file}  (${f.tests.length} tests)`);
    for (const t of f.tests) {
      if (!t.ok) console.log(`      x ${t.name}\n        ${String(t.err).split('\n').join('\n        ')}`);
      else if (flag('--verbose')) console.log(`      ${t.skipped ? '-' : '+'} ${t.name}${t.skipped ? ` (skipped: ${t.err})` : ''}`);
    }
  }
  if (res.fatal) console.log(`FATAL: ${res.fatal}`);
  console.log(`\n${res.passed} passed, ${res.failed} failed, ${res.skipped} skipped`);
  if (res.failed && e2e) {
    const log = join(computer, 'var', 'log', 'tsr.log');
    if (existsSync(log)) console.log('\n--- /var/log/tsr.log ---\n' + readFileSync(log, 'utf8'));
  }
  if (!flag('--keep')) rmSync(work, { recursive: true, force: true });
  process.exit(res.failed || timedOut ? 1 : 0);
}

await main();
