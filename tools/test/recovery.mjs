// SPDX-License-Identifier: AGPL-3.0-or-later
// Boot recovery end-to-end tests: each scenario builds a computer that has been left in a bad state (interrupted writes and package
// installs, garbage configuration, crashing daemons, a broken boot file, ...), boots it for real in headless CraftOS-PC one or more
// times and checks that Tessera recovered, stepped aside or carried on as designed. The checks run inside the computer
// (tests/e2e/recovery/probe-checks.lua); this file prepares the state and judges multi-boot sequences.
//   node tools/test/recovery.mjs [--filter <name>] [--timeout <seconds>] [--keep]
import { spawn } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { findCraftOS, installOverlays, root } from '../lib/craftos.mjs';

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const filter = opt('--filter', null);
const timeout = Number(opt('--timeout', 90)) * 1000;

const put = (dir, rel, text) => {
  const p = join(dir, ...rel.split('/').filter(Boolean));
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, text);
};

/** name, mode ('daemon': the probe runs inside the booted Tessera; 'startup': after /startup.lua returned), boots, prepare(dir), beforeBoot(dir, n), verify(results) */
export const scenarios = [
  {
    name: 'interrupted-file-writes', mode: 'daemon',
    prepare(dir) {
      put(dir, 'etc/tsr/e2e/a.cfg.tsr-tmp', 'partial');
      put(dir, 'etc/tsr/e2e/b.cfg', 'old b');
      put(dir, 'etc/tsr/e2e/b.cfg.tsr-new', 'new b');
      put(dir, 'etc/tsr/e2e/c.cfg.tsr-old', 'old c');
    },
  },
  {
    // the new version of x.lua was moved into place while the old one waits as x.lua.tsr-old: the package journal knows, a plain
    // atomic-write repair must not delete that old copy before the package manager has rolled back
    name: 'interrupted-install-rolls-back', mode: 'daemon',
    prepare(dir) {
      put(dir, 'usr/e2e/x.lua', 'NEW X');
      put(dir, 'usr/e2e/x.lua.tsr-old', 'OLD X');
      put(dir, 'usr/e2e/y.lua', 'NEW Y');
      put(dir, 'var/cache/tsr/stage/junk/file', 'stage');
      put(dir, 'var/lib/tsr/pkg/txn.json', JSON.stringify({ phase: 'commit', files: [{ path: '/usr/e2e/x.lua', existed: true }, { path: '/usr/e2e/y.lua', existed: false }], obsolete: [] }));
    },
  },
  {
    name: 'finished-install-is-cleaned-up', mode: 'daemon',
    prepare(dir) {
      put(dir, 'usr/e2e/z.lua', 'NEW Z');
      put(dir, 'usr/e2e/z.lua.tsr-old', 'OLD Z');
      put(dir, 'usr/e2e/gone.lua', 'gone');
      put(dir, 'var/lib/tsr/pkg/txn.json', JSON.stringify({ phase: 'done', files: [{ path: '/usr/e2e/z.lua', existed: true, backup: true }], obsolete: ['/usr/e2e/gone.lua'] }));
    },
  },
  { name: 'garbage-config', mode: 'daemon', prepare(dir) { put(dir, 'etc/tsr/system.cfg', 'this is { not lua ((('); } },
  {
    name: 'crashing-daemon', mode: 'daemon',
    prepare(dir) {
      put(dir, 'etc/tsr/init.d/50-crash.lua', 'error("boom")\n');
      put(dir, 'etc/tsr/init.d/51-ok.lua', 'local h = fs.open("/etc/tsr/e2e-flag", "w") h.write("ok") h.close()\n');
    },
  },
  {
    name: 'broken-service-definition', mode: 'daemon',
    prepare(dir) {
      put(dir, 'etc/tsr/services.d/brokensvc.lua', 'return { description = "broken", module = \n');
      put(dir, 'etc/tsr/services.d/hungsvc.lua', 'return { description = "no such module", module = "tsr.does.not.exist", entry = "main", autostart = true }\n');
    },
  },
  {
    name: 'missing-front-end', mode: 'daemon',
    prepare(dir) {
      rmSync(join(dir, 'sys', 'lib', 'tsr', 'gui'), { recursive: true, force: true });
      put(dir, 'etc/tsr/system.cfg', '{ ui = { default = "gui" } }');
    },
  },
  { name: 'corrupt-package-database', mode: 'daemon', prepare(dir) { put(dir, 'var/lib/tsr/pkg/db.json', '{{{ garbage'); } },
  {
    name: 'stable-boot-resets-counter', mode: 'daemon', wait: 1.5,
    prepare(dir) {
      put(dir, 'var/lib/tsr/boot.count', '2');
      put(dir, 'etc/tsr/system.cfg', '{ boot = { stable_after = 1 } }');
    },
  },
  {
    // boots 1-3: stage 0 loads a boot file with a syntax error and returns to CraftOS (each counts as a failed boot);
    // boot 4: the guard sees three failures, resets the counter and does not even try
    name: 'crash-loop-guard', mode: 'startup', boots: 4,
    beforeBoot(dir) { put(dir, 'sys/boot.lua', 'this is not lua !!!\n'); },
    verify(results) {
      const counts = results.map((r) => r.bootCount);
      const ok = JSON.stringify(counts) === JSON.stringify([1, 2, 3, 0]);
      return [{ name: 'the boot counter goes 1, 2, 3 and is reset by the guard (got ' + JSON.stringify(counts) + ')', ok }];
    },
  },
  { name: 'disabled-flag', mode: 'startup', prepare(dir) { put(dir, 'etc/tsr/disabled', ''); } },
  {
    // holding R at the banner: simulated by queueing the key before stage 0 starts
    name: 'recovery-key', mode: 'startup',
    prepare(dir) {
      renameSync(join(dir, 'startup.lua'), join(dir, 'startup-tessera.lua'));
      put(dir, 'startup.lua', 'os.queueEvent("key", keys.r, false)\nlocal f = assert(loadfile("/startup-tessera.lua", "t", _ENV))\nf()\n');
    },
  },
];

async function runEmulator(exe, work, out) {
  const child = spawn(exe, ['--headless', '-d', work, '--id', '0', '--mount-rw', `out=${out}`], { stdio: 'ignore', windowsHide: true });
  return new Promise((resolve) => {
    const timer = setTimeout(() => { child.kill(); resolve(true); }, timeout);
    child.on('exit', () => { clearTimeout(timer); resolve(false); });
    child.on('error', () => { clearTimeout(timer); resolve(false); });
  });
}

async function runScenario(exe, sc) {
  const work = join(root, '.scratch', 'recovery');
  const out = join(root, '.scratch', 'recovery-out');
  rmSync(work, { recursive: true, force: true });
  rmSync(out, { recursive: true, force: true });
  const dir = join(work, 'computer', '0');
  mkdirSync(dir, { recursive: true });
  mkdirSync(out, { recursive: true });
  installOverlays(dir);
  cpSync(join(root, 'tests', 'e2e', 'recovery', 'probe-checks.lua'), join(dir, 'probe-checks.lua'));
  const probe = readFileSync(join(root, 'tests', 'e2e', 'recovery', 'probe.lua'), 'utf8');
  put(dir, sc.mode === 'daemon' ? 'etc/tsr/init.d/99-probe.lua' : 'startup/99-probe.lua', probe);
  sc.prepare?.(dir);
  const results = [];
  const checks = [];
  let fatal = null;
  const boots = sc.boots ?? 1;
  for (let boot = 1; boot <= boots; boot++) {
    sc.beforeBoot?.(dir, boot);
    put(dir, 'probe.json', JSON.stringify({ scenario: sc.name, boot, mode: sc.mode, wait: sc.wait }));
    const timedOut = await runEmulator(exe, work, out);
    const file = join(out, `recovery-${sc.name}-${boot}.json`);
    if (!existsSync(file)) {
      fatal = timedOut ? `boot ${boot}: the emulator timed out` : `boot ${boot}: no result (the probe never ran: the boot failed or hung)`;
      const log = join(dir, 'var', 'log', 'tsr.log');
      if (existsSync(log)) fatal += '\n--- /var/log/tsr.log ---\n' + readFileSync(log, 'utf8').split('\n').slice(-25).join('\n');
      break;
    }
    const res = JSON.parse(readFileSync(file, 'utf8'));
    results.push(res);
    for (const c of res.results) checks.push({ ...c, name: (boots > 1 ? `boot ${boot}: ` : '') + c.name });
    if (res.fatal) { fatal = `boot ${boot}: ${res.fatal}`; break; }
  }
  if (!fatal && sc.verify) checks.push(...sc.verify(results));
  if (!args.includes('--keep')) { rmSync(work, { recursive: true, force: true }); rmSync(out, { recursive: true, force: true }); }
  return { name: sc.name, checks, fatal };
}

const exe = findCraftOS();
if (!exe) { console.error('CraftOS-PC not found (set TSR_CRAFTOS)'); process.exit(2); }
let failed = 0, total = 0;
for (const sc of scenarios) {
  if (filter && !sc.name.includes(filter)) continue;
  const res = await runScenario(exe, sc);
  const bad = res.checks.filter((c) => !c.ok);
  total += res.checks.length;
  failed += bad.length + (res.fatal ? 1 : 0);
  console.log(`${bad.length || res.fatal ? 'FAIL' : ' ok '}  ${res.name}  (${res.checks.length} checks)`);
  for (const c of res.checks) if (!c.ok) console.log(`      x ${c.name}\n        ${String(c.err ?? '').split('\n').join('\n        ')}`);
  if (res.fatal) console.log(`      ! ${res.fatal.split('\n').join('\n        ')}`);
}
console.log(`\n${total - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
