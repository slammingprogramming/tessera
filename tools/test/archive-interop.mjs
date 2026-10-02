// SPDX-License-Identifier: AGPL-3.0-or-later
// Checks, with real zlib and the system tar format, the archives that the Lua tests left in .scratch/out/interop (run it right after
// `node tools/test/run.mjs`): every .gz must be a valid gzip file that decompresses to the matching .orig, and the tar must parse.
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { root } from '../lib/craftos.mjs';

const dir = join(root, '.scratch', 'out', 'interop');
if (!existsSync(dir)) { console.error('no interop files: run the unit tests first'); process.exit(1); }
let bad = 0, n = 0;
for (const f of readdirSync(dir).filter((x) => x.endsWith('.gz'))) {
  const base = f.slice(0, -3);
  const gz = readFileSync(join(dir, f));
  const orig = readFileSync(join(dir, base + '.orig'));
  n++;
  try {
    const out = gunzipSync(gz);
    if (!out.equals(orig)) throw new Error(`content differs (${out.length} vs ${orig.length} bytes)`);
  } catch (e) { console.error(`FAIL ${base}: ${e.message}`); bad++; }
}
// the Lua-made tar: walk the ustar headers like any tar reader
const tarBytes = readFileSync(join(dir, 'lua-tar.orig'));
let pos = 0, entries = 0;
while (pos + 512 <= tarBytes.length && tarBytes[pos] !== 0) {
  const h = tarBytes.subarray(pos, pos + 512);
  let sum = 0;
  for (let i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? 32 : h[i];
  const stored = parseInt(h.subarray(148, 154).toString('latin1'), 8);
  if (sum !== stored) { console.error(`FAIL tar header checksum at ${pos}`); bad++; break; }
  const size = parseInt(h.subarray(124, 135).toString('latin1'), 8);
  pos += 512 + Math.ceil(size / 512) * 512;
  entries++;
}
if (entries < 4) { console.error(`FAIL tar: only ${entries} entries`); bad++; }
console.log(bad ? `${bad} interop check(s) FAILED` : `archive interop ok: ${n} gzip files read by zlib, tar of ${entries} entries parsed`);
process.exit(bad ? 1 : 0);
