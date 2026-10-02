// SPDX-License-Identifier: AGPL-3.0-or-later
// Checks that the unified diffs made by the Lua code (left by the unit tests in .scratch/out/interop-diff) are accepted by real git:
// `git apply` must turn the .a text into the .b text. Run right after `node tools/test/run.mjs`.
import { readdirSync, readFileSync, writeFileSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { root } from '../lib/craftos.mjs';

const dir = join(root, '.scratch', 'out', 'interop-diff');
if (!existsSync(dir)) { console.error('no interop files: run the unit tests first'); process.exit(1); }
const work = mkdtempSync(join(tmpdir(), 'tsr-gitapply-'));
let bad = 0, n = 0;
try {
  for (const f of readdirSync(dir).filter((x) => x.endsWith('.patch'))) {
    const name = f.slice(0, -6);
    const a = readFileSync(join(dir, name + '.a'));
    const b = readFileSync(join(dir, name + '.b'));
    writeFileSync(join(work, 'f'), a);
    writeFileSync(join(work, 'p.patch'), readFileSync(join(dir, f)));
    const r = spawnSync('git', ['-c', 'core.autocrlf=false', '-c', 'core.eol=lf', 'apply', '-p0', '--unidiff-zero', '--whitespace=nowarn', 'p.patch'], { cwd: work, encoding: 'utf8' });
    n++;
    if (r.status !== 0) { console.error(`FAIL ${name}: git apply: ${r.stderr.trim()}`); bad++; continue; }
    const got = existsSync(join(work, 'f')) ? readFileSync(join(work, 'f')) : Buffer.alloc(0);
    if (!got.equals(b)) { console.error(`FAIL ${name}: result differs from the expected text`); bad++; }
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}
console.log(bad ? `${bad} diff interop check(s) FAILED` : `diff interop ok: git applied ${n} patches made by the Lua code`);
process.exit(bad ? 1 : 0);
