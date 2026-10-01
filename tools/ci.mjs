// SPDX-License-Identifier: AGPL-3.0-or-later
// Full local verification, in the order that fails fastest:
//   node tools/ci.mjs [--no-emulator]
// 1. public branch has no private paths   2. build (size budgets)   3. unit tests on sources   4. unit tests on the
// minified build   5. boot end-to-end   6. bootstrap installer end-to-end (web-less channels)
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { root, findCraftOS } from './lib/craftos.mjs';

const node = process.execPath;
const steps = [
  ['split check', ['tools/split/sync-public.mjs', '--check']],
  ['build + budgets', ['tools/build/build.mjs']],
  ['gateway tests', ['tools/gateway/gateway.test.mjs']],
];
if (!process.argv.includes('--no-emulator')) {
  if (!findCraftOS()) {
    console.error('CraftOS-PC not found: run with --no-emulator or set TSR_CRAFTOS');
    process.exit(2);
  }
  steps.push(
    ['unit tests (sources)', ['tools/test/run.mjs']],
    ['unit tests (minified)', ['tools/test/run.mjs', '--minified']],
    ['boot e2e', ['tools/test/run.mjs', '--e2e', '--timeout', '60']],
    ['bootstrap e2e', ['tools/test/run.mjs', '--bootstrap', '--timeout', '120']],
  );
}

let failed = 0;
for (const [name, args] of steps) {
  process.stdout.write(`\n=== ${name}\n`);
  const r = spawnSync(node, [join(root, args[0]), ...args.slice(1)], { cwd: root, stdio: 'inherit' });
  if (r.status !== 0) { failed++; console.error(`*** FAILED: ${name}`); break; }
}
console.log(failed ? '\nCI FAILED' : '\nCI OK');
process.exit(failed ? 1 : 0);
