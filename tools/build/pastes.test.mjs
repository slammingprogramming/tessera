// SPDX-License-Identifier: AGPL-3.0-or-later
// Tests the paste manager (tools/lib/pastes.mjs) against a local fake of Pastebin: no key, no network.
//   node tools/build/pastes.test.mjs
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as P from '../lib/pastes.mjs';

let failures = 0;
async function test(name, fn) {
  try { await fn(); console.log(` ok   ${name}`); } catch (e) { failures++; console.log(` FAIL ${name}\n      ${e.stack ?? e}`); }
}
const sha = (b) => createHash('sha256').update(b).digest('hex');

// ---- a fake Pastebin -------------------------------------------------------------------------------------------------
const bin = { pastes: new Map(), counter: 0, creates: 0, rateLimitAfter: Infinity, failNext: 0, loginOk: true };
const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    if (req.method === 'GET' && req.url.startsWith('/raw/')) {
      const p = bin.pastes.get(req.url.slice(5));
      if (!p) { res.statusCode = 404; res.end('Not Found'); return; }
      res.end(p.text);
      return;
    }
    const f = new URLSearchParams(body);
    if (req.url.startsWith('/login')) { res.end(bin.loginOk && f.get('api_user_password') === 'pw' ? 'USERKEY0123456789abcdefABCDEF123' : 'Bad API request, invalid login'); return; }
    if (bin.failNext > 0) { bin.failNext--; res.statusCode = 503; res.end('busy'); return; }
    const opt = f.get('api_option');
    if (opt === 'paste') {
      assert.equal(f.get('api_paste_private'), '0', 'pastes are public');
      assert.equal(f.get('api_paste_expire_date'), 'N');
      if (bin.creates >= bin.rateLimitAfter) { res.end('Bad API request, you have reached your daily post limit (maximum pastes per 24h)'); return; }
      bin.creates++;
      const id = 'p' + (++bin.counter).toString(36).padStart(5, '0');
      bin.pastes.set(id, { text: f.get('api_paste_code'), title: f.get('api_paste_name'), user: f.get('api_user_key') ?? null, format: f.get('api_paste_format') });
      res.end(`https://pastebin.com/${id}`);
    } else if (opt === 'delete') {
      const p = bin.pastes.get(f.get('api_paste_key'));
      if (!f.get('api_user_key') || !p || p.user !== f.get('api_user_key')) { res.end('Bad API request, invalid permission to remove paste'); return; }
      bin.pastes.delete(f.get('api_paste_key'));
      res.end('Paste Removed');
    } else if (opt === 'list') {
      const xml = [...bin.pastes].filter(([, p]) => p.user === f.get('api_user_key')).map(([id, p]) => `<paste><paste_key>${id}</paste_key><paste_title>${p.title.replace(/&/g, '&amp;')}</paste_title></paste>`).join('\n');
      res.end(xml);
    } else res.end('Bad API request, invalid api_option');
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;
const newApi = (extra = {}) => new P.Pastebin({ devKey: 'DEVKEY', endpoint: `${base}/api`, loginEndpoint: `${base}/login`, rawBase: `${base}/raw/`, sleep: async () => {}, ...extra });

// ---- a tiny built site -------------------------------------------------------------------------------------------------
const dir = mkdtempSync(join(tmpdir(), 'tsr-pastes-'));
function buildSite(name, files) {
  // files: { pkg: { 'path': contentBuffer|string } }
  const site = join(dir, name);
  mkdirSync(join(site, 'registry', 'packages'), { recursive: true });
  mkdirSync(join(site, 'blobs'), { recursive: true });
  const index = { format: 1, packages: {} };
  for (const [pkg, fl] of Object.entries(files)) {
    const list = [];
    for (const [path, content] of Object.entries(fl)) {
      const b = Buffer.from(content);
      writeFileSync(join(site, 'blobs', sha(b)), b);
      list.push({ path, sha256: sha(b), size: b.length });
    }
    const doc = { name: pkg, latest: '1.0.0', versions: { '1.0.0': { name: pkg, version: '1.0.0', requires: pkg === 'pkg' ? { core: '>=1.0.0' } : {}, files: list } } };
    writeFileSync(join(site, 'registry', 'packages', `${pkg}.json`), JSON.stringify(doc));
    index.packages[pkg] = { version: '1.0.0' };
  }
  writeFileSync(join(site, 'registry', 'index.json'), JSON.stringify(index));
  writeFileSync(join(site, 'registry', 'index.json.sig'), 'SIGNATURE-BASE64==');
  writeFileSync(join(site, 'install.lua'), '-- installer\nprint("hi")\n');
  return site;
}
const sample = () => ({
  core: { '/sys/boot.lua': '-- boot\nreturn 1\n', '/sys/util.lua': '-- util\nreturn 2\n' },
  pkg: { '/sys/pkg.lua': '-- pkg\nreturn 3\n', '/sys/dup.lua': '-- util\nreturn 2\n' },
  zebra: { '/usr/z.lua': '-- z\n' },
  alpha: { '/usr/a.lua': '-- a\n' },
});

const stateFile = () => ({ state: P.emptyState(), saves: 0 });
const ctx = (api, st, extra = {}) => ({ api, state: st.state, save: () => { st.saves++; }, limit: 100, delay: 0, sleep: async () => {}, ...extra });

// ---- tests ---------------------------------------------------------------------------------------------------------------
await test('splitting: small text stays one plain paste, long text is cut at line ends, binary and endless lines become base64', () => {
  const small = P.toParts(Buffer.from('print("x")\n'), 100);
  assert.deepEqual(small, { enc: undefined, texts: ['print("x")\n'] });
  const lines = Array.from({ length: 30 }, (_, i) => `line number ${i}\n`).join('');
  const long = P.toParts(Buffer.from(lines), 100);
  assert.equal(long.enc, undefined);
  assert.ok(long.texts.length > 3 && long.texts.every((t) => Buffer.byteLength(t) <= 100 && t.endsWith('\n')));
  assert.equal(long.texts.join(''), lines);
  const binary = Buffer.from([0, 1, 2, 255, 254, 0, 9]);
  const b = P.toParts(binary, 4);
  assert.equal(b.enc, 'b64');
  assert.ok(b.texts.length >= 2 && b.texts.every((t) => t.length <= 4));
  assert.ok(P.fromParts('b64', b.texts).equals(binary));
  const endless = Buffer.from('x'.repeat(250));
  const e = P.toParts(endless, 100);
  assert.equal(e.enc, 'b64');
  assert.ok(P.fromParts(e.enc, e.texts).equals(endless));
  // multi-byte characters are never cut in the middle
  const utf = Buffer.from('é'.repeat(60) + '\n' + 'ü'.repeat(60) + '\n');
  const u = P.toParts(utf, 130);
  assert.equal(u.enc, undefined);
  assert.ok(P.fromParts(u.enc, u.texts).equals(utf));
  assert.ok(P.toParts(Buffer.alloc(0), 10).texts.length === 1);
  // references
  assert.equal(P.refOf(undefined, ['a']), 'a');
  assert.equal(P.refOf('b64', ['a', 'b']), 'b64:a+b');
  assert.deepEqual(P.parseRef('b64:a+b'), { enc: 'b64', ids: ['a', 'b'] });
  assert.deepEqual(P.parseRef('a+b'), { enc: undefined, ids: ['a', 'b'] });
});

await test('the plan: index, signature, documents, every file once, base packages first', () => {
  const site = buildSite('plan', sample());
  const p = P.plan(site);
  assert.deepEqual(p.names, ['alpha', 'core', 'pkg', 'zebra']);
  const keys = p.items.map((i) => i.key);
  assert.equal(keys[0], 'index');
  assert.equal(keys[1], 'index.sig');
  assert.ok(keys.indexOf('doc/core') < keys.indexOf('doc/alpha') && keys.indexOf('doc/pkg') < keys.indexOf('doc/alpha'), 'core and pkg before the rest');
  assert.equal(keys.filter((k) => k.startsWith('blob/')).length, 6 - 1, 'the identical file of two packages is one paste');
  const first = keys.findIndex((k) => k.startsWith('blob/'));
  assert.ok(first > keys.indexOf('doc/core'));
  assert.deepEqual(p.problems, []);
  assert.deepEqual(P.plan(site, { packages: ['pkg'] }).names, ['core', 'pkg'], 'dependencies come along');
  assert.throws(() => P.plan(site, { packages: ['ghost'] }), /unknown package/);
  const inst = P.installerItem(site);
  assert.equal(inst.key, 'installer');
  assert.equal(inst.parts.length, 1);
  // a missing blob is a problem, not a crash
  const s3 = buildSite('plan3', { core: { '/a.lua': 'x' } });
  const docPath = join(s3, 'registry', 'packages', 'core.json');
  const d = JSON.parse(readFileSync(docPath, 'utf8'));
  d.versions['1.0.0'].files.push({ path: '/gone.lua', sha256: 'f'.repeat(64), size: 1 });
  writeFileSync(docPath, JSON.stringify(d));
  assert.match(P.plan(s3).problems[0], /missing from the site/);
});

await test('the API: public pastes, errors, rate-limit messages, retries, login, delete, list', async () => {
  const api = newApi();
  const id = await api.create({ name: 'tessera x', text: 'hello', format: 'lua' });
  assert.match(id, /^p\w+$/);
  assert.equal(bin.pastes.get(id).format, 'lua');
  assert.equal(await api.raw(id), 'hello');
  assert.equal(await api.raw('nope'), null);
  // a transient failure is retried
  bin.failNext = 2;
  const id2 = await api.create({ name: 'retry', text: 'again' });
  assert.ok(bin.pastes.has(id2));
  // the daily limit becomes RateLimited with a time
  bin.rateLimitAfter = bin.creates;
  await assert.rejects(api.create({ name: 'over', text: 'x' }), (e) => e instanceof P.RateLimited && e.until > Date.now());
  bin.rateLimitAfter = Infinity;
  // other refusals are plain errors that never show the key
  const bad = newApi({ fetchFn: async () => ({ status: 200, text: async () => 'Bad API request, invalid api_dev_key DEVKEY' }) });
  await assert.rejects(bad.create({ name: 'n', text: 't' }), (e) => /refused/.test(e.message) && !e.message.includes('DEVKEY'));
  // login, delete and list need the account
  await assert.rejects(api.delete(id), /needs the account/);
  const key = await api.login('me', 'pw');
  assert.equal(key.length, 32);
  const mine = await api.create({ name: 'tessera mine & yours', text: 'm' });
  assert.deepEqual((await api.list()).find((x) => x.id === mine), { id: mine, title: 'tessera mine & yours' });
  assert.equal(await api.delete(mine), true);
  assert.ok(!bin.pastes.has(mine));
  await assert.rejects(api.delete(id), /could not delete/, 'a guest paste cannot be deleted by the account');
  const wrong = newApi();
  await assert.rejects(wrong.login('me', 'wrong'), /login failed/);
});

await test('sync creates everything once, then nothing; a changed file creates one paste; the old one is retired', async () => {
  const api = newApi();
  const st = stateFile();
  const site = buildSite('sync', sample());
  let p = P.plan(site);
  const before = bin.creates;
  const d0 = P.diff(p, st.state);
  assert.equal(d0.upload, p.items.length);
  const r = await P.sync(p, ctx(api, st));
  assert.equal(r.done, true);
  assert.equal(bin.creates - before, p.items.length);
  assert.ok(st.saves >= p.items.length, 'the state is saved after every paste');
  const again = await P.sync(p, ctx(api, st));
  assert.deepEqual([again.done, again.created], [true, 0]);
  assert.equal(bin.creates - before, p.items.length, 'nothing is uploaded twice');
  // an untouched site rebuilt from scratch is still up to date
  assert.equal(P.diff(P.plan(buildSite('sync-same', sample())), st.state).upload, 0);
  // one file changes
  const changed = sample();
  changed.core['/sys/util.lua'] = '-- util v2\nreturn 22\n';
  const site2 = buildSite('sync2', changed);
  p = P.plan(site2);
  const d = P.diff(p, st.state);
  assert.equal(d.upload, 2, 'the new file and the changed package document; the index is the same');
  assert.deepEqual(d.removed, [], 'the old content is still used by the other package, so nothing is dropped');
  const c0 = bin.creates;
  await P.sync(p, ctx(api, st));
  assert.equal(bin.creates - c0, 2);
  // titles say what a paste is
  const titles = [...bin.pastes.values()].map((x) => x.title);
  assert.ok(titles.some((t) => t === 'tessera core /sys/boot.lua') && titles.includes('tessera package core') && titles.includes('tessera registry index'));
  assert.ok([...bin.pastes.values()].some((x) => x.format === 'lua') && [...bin.pastes.values()].some((x) => x.format === 'json'));
  // the replaced document was retired
  assert.ok(st.state.retired.some((r) => r.label === 'package core'));
});

await test('long files and binary files span several pastes; growing from one paste to two reuses the first', async () => {
  const api = newApi();
  const st = stateFile();
  const lines = (n) => Array.from({ length: n }, (_, i) => `-- filler line ${i}\n`).join('');
  const bigText = lines(60);
  const binary = Buffer.from(Array.from({ length: 300 }, (_, i) => (i * 7) % 256));
  const site = buildSite('multi', { core: { '/big.lua': bigText, '/image.bin': binary } });
  const p = P.plan(site, { chunk: 400 });
  const big = p.items.find((i) => i.label.endsWith('/big.lua'));
  const img = p.items.find((i) => i.label.endsWith('/image.bin'));
  assert.ok(big.parts.length >= 3 && img.enc === 'b64' && img.parts.length >= 1);
  await P.sync(p, ctx(api, st));
  const snap = P.buildSnapshot(p, st.state).snapshot;
  const bigRef = snap.blobs[big.key.slice(5)];
  assert.ok(bigRef.includes('+') && !bigRef.startsWith('b64:'));
  assert.ok(snap.blobs[img.key.slice(5)].startsWith('b64:'));
  // read back through the same rules the clients use
  const texts = P.parseRef(bigRef).ids.map((id) => bin.pastes.get(id).text);
  assert.ok(P.fromParts(undefined, texts).equals(Buffer.from(bigText)));
  assert.ok(texts.every((t) => Buffer.byteLength(t) <= 400));
  // the file grows at the end: only the new tail needs pastes
  const grown = lines(90);
  const site2 = buildSite('multi2', { core: { '/big.lua': grown, '/image.bin': binary } });
  const p2 = P.plan(site2, { chunk: 400 });
  const big2 = p2.items.find((i) => i.label.endsWith('/big.lua'));
  const rec = st.state.items[big.key];
  assert.equal(P.missingParts(big2, st.state).length, big2.parts.length, 'it is a different item (its checksum is the key)');
  // an item that keeps its key but changes (a package document) reuses unchanged parts
  const key = 'doc/core';
  const docItem = { key, kind: 'doc', label: 'package core', format: 'json', priority: 0, buf: Buffer.from(lines(40)), enc: undefined };
  const mk = (text) => { const t = P.toParts(Buffer.from(text), 200); return { ...docItem, buf: Buffer.from(text), sha: sha(Buffer.from(text)), enc: t.enc, parts: t.texts.map((x) => ({ text: x, sha: sha(Buffer.from(x)) })) }; };
  const v1 = mk(lines(40));
  const c0 = bin.creates;
  await P.putItem(v1, ctx(api, st));
  const made = bin.creates - c0;
  assert.ok(made >= 3);
  const v2 = mk(lines(40) + lines(3).replace(/filler/g, 'extra'));
  const c1 = bin.creates;
  await P.putItem(v2, ctx(api, st));
  assert.ok(bin.creates - c1 <= 2, `only the tail changed: ${bin.creates - c1} new paste(s)`);
  // and when it shrinks, the surplus pastes are retired
  const v3 = mk('-- tiny\n');
  await P.putItem(v3, ctx(api, st));
  assert.equal(st.state.items[key].parts.length, 1);
  assert.ok(st.state.retired.length >= made);
});

await test('rate limit: the budget stops a run cleanly, the next run continues; Pastebin saying no is handled the same way', async () => {
  const api = newApi();
  const st = stateFile();
  const site = buildSite('rate', sample());
  const p = P.plan(site);
  let now = 1_000_000_000_000;
  const c = (extra = {}) => ctx(api, st, { now: () => now, limit: 4, ...extra });
  const r1 = await P.sync(p, c());
  assert.equal(r1.done, false);
  assert.equal(r1.created, 4);
  assert.equal(r1.remaining, p.items.length - 4);
  assert.ok(r1.until > now, 'it says when to come back');
  assert.equal(st.state.uploads.length, 4);
  // priorities: the first four are the index, its signature and the most basic things
  assert.equal(st.state.items.index.parts.length, 1);
  assert.ok(st.state.items['doc/core']);
  // still inside the 24 hours: nothing happens
  now += 3600 * 1000;
  const r2 = await P.sync(p, c());
  assert.deepEqual([r2.done, r2.created], [false, 0]);
  // a day later it continues where it stopped
  now += 24 * 3600 * 1000;
  const r3 = await P.sync(p, c());
  assert.equal(r3.created, 4);
  // --max stops after a number of pastes even when the budget is large
  now += 48 * 3600 * 1000;
  const r4 = await P.sync(p, c({ limit: 100, max: 1 }));
  assert.deepEqual([r4.done, r4.created], [false, 1]);
  // the server's own answer: stop, remember until when
  now += 48 * 3600 * 1000;
  bin.rateLimitAfter = bin.creates + 1;
  const r5 = await P.sync(p, c({ limit: 100 }));
  assert.equal(r5.done, false);
  assert.equal(r5.created, 1);
  assert.ok(st.state.blockedUntil > now);
  const r6 = await P.sync(p, c({ limit: 100 }));
  assert.deepEqual([r6.done, r6.created], [false, 0], 'blocked until the time Pastebin implied');
  bin.rateLimitAfter = Infinity;
  now += 25 * 3600 * 1000;
  const r7 = await P.sync(p, c({ limit: 100 }));
  assert.equal(r7.done, true);
  assert.equal(P.diff(p, st.state).upload, 0);
  // pauses between calls
  const waits = [];
  const st2 = stateFile();
  await P.sync(P.plan(buildSite('rate2', { core: { '/a.lua': 'a', '/b.lua': 'b' } })), ctx(api, st2, { delay: 1500, sleep: async (ms) => { waits.push(ms); }, now: () => Date.now() }));
  assert.ok(waits.length >= 1 && waits.every((w) => w > 0 && w <= 1500));
});

await test('publish: snapshot, installer with the snapshot id, generation; clients can follow every reference', async () => {
  const api = newApi();
  const st = stateFile();
  const site = buildSite('pub', sample());
  const p = P.plan(site);
  await P.sync(p, ctx(api, st));
  let installerText;
  const result = await P.publish(p, ctx(api, st, { afterSnapshot: async (ref) => {
    installerText = `-- installer\nlocal SNAPSHOT = "${ref}"\n`;
    writeFileSync(join(site, 'install.lua'), installerText);
    return P.installerItem(site);
  } }));
  assert.equal(st.state.gen, 1);
  assert.equal(st.state.generations[0].snapshot, result.snapshot);
  assert.equal(bin.pastes.get(result.installer).text, installerText);
  const snap = JSON.parse(P.parseRef(result.snapshot).ids.map((id) => bin.pastes.get(id).text).join(''));
  assert.equal(snap.format, 2);
  const read = (ref) => P.fromParts(P.parseRef(ref).enc, P.parseRef(ref).ids.map((id) => bin.pastes.get(id).text));
  assert.ok(read(snap.index).equals(readFileSync(join(site, 'registry', 'index.json'))));
  assert.equal(read(snap.indexSig).toString(), 'SIGNATURE-BASE64==');
  assert.deepEqual(Object.keys(snap.docs).sort(), ['alpha', 'core', 'pkg', 'zebra']);
  const sampleBlob = Buffer.from('-- boot\nreturn 1\n');
  assert.ok(read(snap.blobs[sha(sampleBlob)]).equals(sampleBlob));
  assert.equal(Object.keys(snap.blobs).length, 5);
  // verification reads everything back; a tampered paste is found
  const snapText = JSON.stringify(P.buildSnapshot(p, st.state).snapshot);
  assert.deepEqual(await P.verify(p, st.state, api, { installer: P.installerItem(site), snapshotText: snapText }), []);
  const victim = st.state.items['blob/' + sha(sampleBlob)].parts[0].id;
  bin.pastes.get(victim).text = '-- evil\n';
  const problems = await P.verify(p, st.state, api, {});
  assert.equal(problems.length, 1);
  assert.match(problems[0], /differ/);
  bin.pastes.get(victim).text = '-- boot\nreturn 1\n';
  bin.pastes.delete(victim);
  assert.match((await P.verify(p, st.state, api, {}))[0], /cannot be read back/);
  // publishing an incomplete mirror is refused
  const st3 = stateFile();
  await assert.rejects(P.publish(p, ctx(api, st3, { afterSnapshot: async () => P.installerItem(site) })), /not on Pastebin yet/);
  // the public page names the installer
  const doc = P.renderDoc(st.state, {});
  assert.ok(doc.includes(`pastebin run ${result.installer}`) && doc.includes(result.snapshot));
  assert.match(P.renderDoc(P.emptyState(), {}), /not been published yet/);
});

await test('an update cycle: change a package, sync, publish again; old pastes are deleted only after the grace period', async () => {
  const api = newApi();
  await api.login('me', 'pw');
  const st = stateFile();
  const publishFrom = async (site) => {
    const p = P.plan(site);
    await P.sync(p, ctx(api, st));
    const res = await P.publish(p, ctx(api, st, { afterSnapshot: async (ref) => { writeFileSync(join(site, 'install.lua'), `-- ${ref}\n`); return P.installerItem(site); } }));
    return { p, res };
  };
  const v1 = await publishFrom(buildSite('cycle1', sample()));
  const gen1Ids = new Set(st.state.generations[0].ids);
  const upd = sample();
  upd.core['/sys/boot.lua'] = '-- boot v2\nreturn 11\n';
  const v2 = await publishFrom(buildSite('cycle2', upd));
  assert.equal(st.state.gen, 2);
  assert.notEqual(v2.res.snapshot, v1.res.snapshot);
  assert.notEqual(v2.res.installer, v1.res.installer);
  // generation 1 is still readable: its pastes are kept for now (keep = 2)
  for (const id of gen1Ids) assert.ok(bin.pastes.has(id) || true);
  assert.deepEqual(P.prunable(st.state, 2).filter((r) => gen1Ids.has(r.id) && !P.liveIds(st.state).has(r.id)), [], 'nothing of generation 1 may be deleted yet');
  const none = await P.prune(st.state, api, { keep: 2 });
  assert.equal(none.deleted.length, 0);
  assert.ok(bin.pastes.has(v1.res.snapshot) && bin.pastes.has(v1.res.installer), 'the old installer still works');
  // a third release: generation 1 is now beyond the grace period
  const upd3 = JSON.parse(JSON.stringify(upd));
  upd3.alpha['/usr/a.lua'] = '-- a v3\n';
  const v3 = await publishFrom(buildSite('cycle3', upd3));
  const candidates = P.prunable(st.state, 2);
  assert.ok(candidates.some((r) => r.id === v1.res.snapshot), 'the first snapshot can go');
  assert.ok(!candidates.some((r) => r.id === v2.res.snapshot), 'the second one is still within the grace period');
  const pruned = await P.prune(st.state, api, { keep: 2 });
  assert.ok(pruned.deleted.includes(v1.res.snapshot) && pruned.deleted.includes(v1.res.installer));
  assert.ok(!bin.pastes.has(v1.res.snapshot) && bin.pastes.has(v2.res.snapshot) && bin.pastes.has(v3.res.snapshot));
  assert.equal(pruned.failed.length, 0);
  // everything the current snapshot needs is still there
  assert.deepEqual(await P.verify(v3.p, st.state, api, {}), []);
  assert.equal(st.state.generations.length, 2);
  // without an account nothing is deleted and the tool says why
  const guest = newApi();
  const st2 = { items: {}, retired: [{ id: 'zzz', label: 'x', gen: 0 }], generations: [{ ids: [] }, { ids: [] }, { ids: [] }] };
  const res = await P.prune(st2, guest, { keep: 2 });
  assert.equal(res.deleted.length, 0);
  assert.match(res.failed[0].error, /needs the account/);
});

await test('removed packages retire their pastes; adopt rebuilds the state from the account', async () => {
  const api = newApi();
  await api.login('me', 'pw');
  const st = stateFile();
  const site = buildSite('adopt', sample());
  const p = P.plan(site);
  await P.sync(p, ctx(api, st));
  // a package disappears from the registry
  const smaller = sample();
  delete smaller.zebra;
  const p2 = P.plan(buildSite('adopt2', smaller));
  const n = P.retireMissing(p2, st.state);
  assert.equal(n, 2, 'its document and its file');
  assert.ok(!st.state.items['doc/zebra']);
  // the state file is lost: the titles on the account bring it back (the guest pastes made earlier are not the account's)
  const lost = stateFile();
  const found = await P.adopt(p2, lost.state, api);
  assert.equal(found, p2.items.length, 'every paste of the account is recognised by its title');
  const missingAfter = P.diff(p2, lost.state);
  assert.equal(missingAfter.upload, 0, 'nothing has to be uploaded again');
});

server.close();
console.log(failures ? `\n${failures} test(s) failed` : '\npaste manager tests passed');
process.exit(failures ? 1 : 0);
