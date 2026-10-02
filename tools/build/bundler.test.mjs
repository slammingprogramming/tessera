// SPDX-License-Identifier: AGPL-3.0-or-later
// Checks that the browser-side bundle builder (site/bundler.js) produces exactly what the Lua importer expects, by comparing it with
// the reference encoder in tools/lib/bundle.mjs and by reading its output back.
//   node tools/build/bundler.test.mjs
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { crc32 as nodeCrc32, inflateRawSync } from 'node:zlib';
import { buildContainer as refContainer, KIND as REF_KIND } from '../lib/bundle.mjs';
import { KIND, assemble, buildContainer, crc32, resolve, toChunks, toFile } from '../../site/bundler.js';

let failures = 0;
async function test(name, fn) {
  try { await fn(); console.log(` ok   ${name}`); } catch (e) { failures++; console.log(` FAIL ${name}\n      ${e.stack ?? e}`); }
}

const sha = (b) => createHash('sha256').update(b).digest('hex');

// a tiny registry
const files = { app: Buffer.from("print('app')"), lib: Buffer.from('return 1'), other: Buffer.from(Array.from({ length: 5000 }, (_, i) => i % 251)) };
const blobs = Object.fromEntries(Object.entries(files).map(([k, v]) => [sha(v), v]));
const doc = (name, requires, file) => ({ name, latest: '1.0.0', versions: { '1.0.0': { name, version: '1.0.0', requires, files: [{ path: `/usr/${name}`, sha256: sha(file), size: file.length }] } } });
const docs = { app: doc('app', { lib: '>=1.0.0' }, files.app), lib: doc('lib', {}, files.lib), other: doc('other', {}, files.other) };
const index = { format: 1, packages: { app: { version: '1.0.0' }, lib: { version: '1.0.0' }, other: { version: '1.0.0' } } };
const fetchBytes = async (url) => new Uint8Array(blobs[url.replace('blobs/', '')]);

await test('crc32 matches the reference', () => {
  for (const s of ['', 'a', 'hello world', 'TSR1 test payload']) assert.equal(crc32(new TextEncoder().encode(s)), nodeCrc32(Buffer.from(s)));
  assert.equal(crc32(new Uint8Array(files.other)), nodeCrc32(files.other));
});

await test('the container is byte-identical to the reference encoder', () => {
  const entries = [
    { kind: KIND.index, name: 'index', data: '{"format":1}' },
    { kind: KIND.package, name: 'app', data: JSON.stringify(docs.app) },
    { kind: KIND.blob, name: sha(files.lib), data: new Uint8Array(files.lib) },
  ];
  const ours = Buffer.from(buildContainer(entries));
  const ref = refContainer(entries.map((e) => ({ ...e, data: typeof e.data === 'string' ? e.data : Buffer.from(e.data) })));
  assert.deepEqual(KIND, REF_KIND);
  assert.equal(ours.toString('hex'), ref.toString('hex'));
});

await test('dependencies are resolved and unknown packages refused', () => {
  assert.deepEqual(resolve(['app'], index, docs), ['app', 'lib']);
  assert.deepEqual(resolve(['other', 'app'], index, docs), ['app', 'lib', 'other']);
  assert.throws(() => resolve(['ghost'], index, docs), /unknown package ghost/);
});

await test('assemble downloads, verifies and packs', async () => {
  const progress = [];
  const { container, names, size } = await assemble(['app'], { index, docs, fetchBytes, progress: (d, t) => progress.push([d, t]) });
  assert.deepEqual(names, ['app', 'lib']);
  assert.equal(size, container.length);
  assert.deepEqual(progress.at(-1), [2, 2]);
  assert.equal(Buffer.from(container).subarray(0, 4).toString(), 'TSRB');
  // a corrupted download is refused
  await assert.rejects(assemble(['lib'], { index, docs, fetchBytes: async () => new Uint8Array([1, 2, 3]) }), /failed its checksum/);
});

await test('the drag-and-drop file inflates back to the container', async () => {
  const { container } = await assemble(['other'], { index, docs, fetchBytes });
  const file = Buffer.from(await toFile(container));
  assert.equal(file.subarray(0, 4).toString(), 'TSRZ');
  assert.equal(file[4], 1);
  assert.equal(inflateRawSync(file.subarray(5)).toString('hex'), Buffer.from(container).toString('hex'));
});

await test('paste lines carry valid checksums and reassemble to the container', async () => {
  const { container } = await assemble(['app', 'other'], { index, docs, fetchBytes });
  const { id, lines } = await toChunks(container, 120);
  assert.ok(lines.length > 3);
  const parts = [];
  lines.forEach((line, i) => {
    const m = line.match(/^TSR1 (\w{8}) (\d+)\/(\d+) ([0-9a-f]{8}) (\S+)$/);
    assert.ok(m, line);
    assert.equal(m[1], id);
    assert.equal(Number(m[2]), i + 1);
    assert.equal(Number(m[3]), lines.length);
    assert.equal(parseInt(m[4], 16), nodeCrc32(Buffer.from(m[5])), 'crc of line ' + (i + 1));
    assert.ok(m[5].length <= 120);
    parts.push(m[5]);
  });
  const inflated = inflateRawSync(Buffer.from(parts.join(''), 'base64'));
  assert.equal(inflated.toString('hex'), Buffer.from(container).toString('hex'));
});

if (failures) { console.log(`\n${failures} failed`); process.exit(1); }
console.log('\nbundler tests passed');
