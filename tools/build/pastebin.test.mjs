// SPDX-License-Identifier: AGPL-3.0-or-later
// Tests the Pastebin snapshot publisher against a local fake of the Pastebin API (no key, no network).
//   node tools/build/pastebin.test.mjs
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPaste, plan, publish, verify } from './pastebin.mjs';

let failures = 0;
async function test(name, fn) {
  try { await fn(); console.log(` ok   ${name}`); } catch (e) { failures++; console.log(` FAIL ${name}\n      ${e.stack ?? e}`); }
}
const sha = (b) => createHash('sha256').update(b).digest('hex');

// a tiny built site
const dir = mkdtempSync(join(tmpdir(), 'tsr-pb-'));
const site = join(dir, 'site');
mkdirSync(join(site, 'registry', 'packages'), { recursive: true });
mkdirSync(join(site, 'blobs'));
const blob = (text) => { const b = Buffer.from(text); writeFileSync(join(site, 'blobs', sha(b)), b); return { path: '/x', sha256: sha(b), size: b.length }; };
const doc = (name, requires, ...texts) => ({ name, latest: '1.0.0', versions: { '1.0.0': { name, version: '1.0.0', requires, files: texts.map(blob) } } });
const docs = { core: doc('core', {}, '-- core a', '-- core b'), pkg: doc('pkg', { core: '>=1.0.0' }, '-- pkg'), big: doc('big', {}, '-- never uploaded') };
for (const [n, d] of Object.entries(docs)) writeFileSync(join(site, 'registry', 'packages', `${n}.json`), JSON.stringify(d));
writeFileSync(join(site, 'registry', 'index.json'), JSON.stringify({ format: 1, packages: { core: { version: '1.0.0' }, pkg: { version: '1.0.0' }, big: { version: '1.0.0' } } }));

// a fake Pastebin
let counter = 0;
const received = [];
let failAfter = Infinity;
const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const form = new URLSearchParams(body);
    received.push({ name: form.get('api_paste_name'), code: form.get('api_paste_code'), devKey: form.get('api_dev_key'), userKey: form.get('api_user_key') });
    if (received.length > failAfter) { res.end('Bad API request, invalid api_dev_key'); return; }
    res.end(`https://pastebin.com/id${++counter}`);
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const endpoint = `http://127.0.0.1:${server.address().port}/api`;

await test('the plan covers the packages, their dependencies and each file once', () => {
  const p = plan(site, ['pkg']);
  assert.deepEqual(p.names, ['core', 'pkg']);
  assert.equal(p.items.length, 2 + 3, '2 package documents + 3 blobs');
  assert.ok(p.items.some((i) => i.key === 'packages/core'));
  assert.deepEqual(Object.keys(p.index.packages), ['core', 'pkg']);
  assert.deepEqual(p.problems, []);
  assert.throws(() => plan(site, ['ghost']), /unknown package/);
});

await test('binary files are reported instead of being uploaded broken', () => {
  const bad = Buffer.from([0xff, 0xfe, 0x00, 0x80]);
  writeFileSync(join(site, 'blobs', sha(bad)), bad);
  const d = doc('binary', {});
  d.versions['1.0.0'].files = [{ path: '/b.bin', sha256: sha(bad), size: 4 }];
  writeFileSync(join(site, 'registry', 'packages', 'binary.json'), JSON.stringify(d));
  const idx = JSON.parse(JSON.stringify({ format: 1, packages: { binary: { version: '1.0.0' } } }));
  writeFileSync(join(site, 'registry', 'index.json'), JSON.stringify({ format: 1, packages: { core: { version: '1.0.0' }, pkg: { version: '1.0.0' }, big: { version: '1.0.0' }, binary: { version: '1.0.0' } } }));
  const p = plan(site, ['binary']);
  assert.equal(p.problems.length, 1);
  assert.match(p.problems[0], /not valid UTF-8/);
});

await test('a paste is created through the API and the id extracted', async () => {
  received.length = 0;
  const id = await createPaste({ endpoint, devKey: 'DEVKEY', userKey: 'USERKEY', name: 'n', text: 'hello' });
  assert.match(id, /^id\d+$/);
  assert.deepEqual(received[0], { name: 'n', code: 'hello', devKey: 'DEVKEY', userKey: 'USERKEY' });
  failAfter = received.length;
  await assert.rejects(createPaste({ endpoint, devKey: 'x', name: 'n', text: 't' }), /Pastebin refused: Bad API request/);
  failAfter = Infinity;
});

await test('publishing uploads everything and a snapshot that maps keys to paste ids', async () => {
  received.length = 0;
  const statePath = join(dir, 'state.json');
  const p = plan(site, ['pkg']);
  const log = [];
  const snapshotId = await publish(p, { devKey: 'K', endpoint, delay: 0, statePath, log: (t) => log.push(t) });
  assert.equal(received.length, p.items.length + 1);
  assert.ok(received.every((r) => r.devKey === 'K'));
  const snap = JSON.parse(received.at(-1).code);
  assert.deepEqual(Object.keys(snap.index.packages), ['core', 'pkg']);
  for (const item of p.items) assert.match(snap.pastes[item.key], /^id\d+$/, item.key);
  assert.equal(JSON.parse(received.find((r) => r.name.includes('package core')).code).name, 'core');
  assert.match(snapshotId, /^id\d+$/);
});

await test('an interrupted upload resumes without repeating pastes', async () => {
  received.length = 0;
  counter = 100;
  const statePath = join(dir, 'state2.json');
  const p = plan(site, ['pkg']);
  failAfter = 3;
  await assert.rejects(publish(p, { devKey: 'K', endpoint, delay: 0, statePath }), /Pastebin refused/);
  const first = received.length;
  failAfter = Infinity;
  received.length = 0;
  await publish(p, { devKey: 'K', endpoint, delay: 0, statePath, log: () => {} });
  assert.equal(received.length, p.items.length + 1 - 3, 'only the missing pastes and the snapshot were created');
  assert.ok(first >= 4);
});

await test('verification reads every paste back and notices damage', async () => {
  // the fake Pastebin keeps what it was sent; "raw" URLs answer with it
  const store = new Map();
  let n = 500;
  const rawServer = createServer((req, res) => {
    if (req.method === 'POST') {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => { const id = 'v' + ++n; store.set(id, new URLSearchParams(body).get('api_paste_code')); res.end('https://pastebin.com/' + id); });
    } else { const t = store.get(req.url.slice(1)); if (t === undefined) { res.statusCode = 404; res.end(); } else res.end(t); }
  });
  await new Promise((r) => rawServer.listen(0, '127.0.0.1', r));
  const base = 'http://127.0.0.1:' + rawServer.address().port;
  const statePath = join(dir, 'verify-state.json');
  const p = plan(site, ['pkg']);
  const id = await publish(p, { devKey: 'K', endpoint: base + '/api', delay: 0, statePath, log: () => {} });
  assert.deepEqual(await verify(p, id, { statePath, rawBase: base + '/', delay: 0 }), []);
  // damage one paste
  const state = JSON.parse((await import('node:fs')).readFileSync(statePath, 'utf8'));
  const victim = Object.values(state.pastes)[0];
  store.set(victim, 'tampered');
  const problems = await verify(p, id, { statePath, rawBase: base + '/', delay: 0 });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /differs from the file/);
  store.delete(victim);
  assert.match((await verify(p, id, { statePath, rawBase: base + '/', delay: 0 }))[0], /cannot be read back/);
  rawServer.close();
});

server.close();
rmSync(dir, { recursive: true, force: true });
if (failures) { console.log(`\n${failures} failed`); process.exit(1); }
console.log('\npastebin tests passed');
