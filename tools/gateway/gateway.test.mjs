// SPDX-License-Identifier: AGPL-3.0-or-later
// Tests for tools/gateway/gateway.mjs, with a hand-written WebSocket client standing in for a ComputerCraft computer.
//   node tools/gateway/gateway.test.mjs
import assert from 'node:assert/strict';
import { request } from 'node:http';
import { randomBytes } from 'node:crypto';
import { startGateway, encodeFrame, createParser } from './gateway.mjs';

const TOKEN = 'test-token-0123456789';
let failures = 0;
async function test(name, fn) {
  try { await fn(); console.log(` ok   ${name}`); } catch (e) { failures++; console.log(` FAIL ${name}\n      ${e.stack ?? e}`); }
}

const http = (port, method, path, { token = TOKEN, body } = {}) => new Promise((resolve, reject) => {
  const req = request({ host: '127.0.0.1', port, method, path, headers: token ? { authorization: `Bearer ${token}`, 'content-type': 'application/json' } : {} }, (res) => {
    let text = '';
    res.on('data', (c) => (text += c));
    res.on('end', () => resolve({ status: res.statusCode, json: text ? JSON.parse(text) : null }));
  });
  req.on('error', reject);
  if (body !== undefined) req.write(typeof body === 'string' ? body : JSON.stringify(body));
  req.end();
});

/** A masked client frame, as a real WebSocket client sends. */
function clientFrame(text, opcode = 0x1) {
  const payload = Buffer.from(text);
  const mask = randomBytes(4);
  const head = payload.length < 126 ? Buffer.from([0x80 | opcode, 0x80 | payload.length]) : Buffer.from([0x80 | opcode, 0x80 | 126, payload.length >> 8, payload.length & 255]);
  const masked = Buffer.from(payload);
  for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i % 4];
  return Buffer.concat([head, mask, masked]);
}

/** Connect as a computer. Returns { socket, messages (async queue), status }. */
function connectComputer(port, { token = TOKEN, name = 'hub' } = {}) {
  return new Promise((resolve, reject) => {
    const req = request({ host: '127.0.0.1', port, path: '/ws', headers: {
      Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': randomBytes(16).toString('base64'),
      ...(token ? { Authorization: `Bearer ${token}` } : {}), 'X-Computer': name,
    } });
    req.on('upgrade', (res, socket, head) => {
      const feed = createParserClient();
      const queue = [], waiters = [];
      const push = (m) => (waiters.length ? waiters.shift()(m) : queue.push(m));
      const handle = (chunk) => { for (const m of feed(chunk)) push(m); };
      if (head.length) handle(head);
      socket.on('data', handle);
      resolve({ socket, status: res.statusCode, next: () => (queue.length ? Promise.resolve(queue.shift()) : new Promise((r) => waiters.push(r))) });
    });
    req.on('response', (res) => resolve({ status: res.statusCode, socket: null }));
    req.on('error', reject);
    req.end();
  });
}

/** Parser for unmasked server frames (what the gateway sends). */
function createParserClient() {
  let buf = Buffer.alloc(0);
  return (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    const out = [];
    while (buf.length >= 2) {
      let len = buf[1] & 0x7f, off = 2;
      if (len === 126) { if (buf.length < 4) break; len = buf.readUInt16BE(2); off = 4; }
      if (buf.length < off + len) break;
      out.push({ opcode: buf[0] & 0x0f, text: buf.subarray(off, off + len).toString() });
      buf = buf.subarray(off + len);
    }
    return out;
  };
}

const gw = await startGateway({ port: 0, token: TOKEN });

await test('frames round-trip through the parser', () => {
  const feed = createParser();
  const big = 'x'.repeat(70000).slice(0, 5000);
  const [m] = feed(clientFrame(big));
  assert.equal(m.data.toString(), big);
  const two = feed(Buffer.concat([clientFrame('a'), clientFrame('b')]));
  assert.deepEqual(two.map((x) => x.data.toString()), ['a', 'b']);
  // split across chunks
  const f = clientFrame('split me');
  assert.equal(feed(f.subarray(0, 3)).length, 0);
  assert.equal(feed(f.subarray(3))[0].data.toString(), 'split me');
  assert.throws(() => feed(encodeFrame('unmasked')), /masked/);
});

await test('requests without the token are refused', async () => {
  assert.equal((await http(gw.port, 'GET', '/api/computers', { token: null })).status, 401);
  assert.equal((await http(gw.port, 'GET', '/api/computers', { token: 'wrong' })).status, 401);
  assert.equal((await http(gw.port, 'GET', '/nothing')).status, 404);
});

await test('computers need the token to connect', async () => {
  const bad = await connectComputer(gw.port, { token: 'wrong' });
  assert.equal(bad.status, 401);
  const noName = await connectComputer(gw.port, { name: '../x/y' });
  assert.equal(noName.status, 401);
});

await test('a connected computer is listed and answers calls', async () => {
  const c = await connectComputer(gw.port, { name: 'hub' });
  assert.equal(c.status, 101);
  const list = await http(gw.port, 'GET', '/api/computers');
  assert.deepEqual(list.json.map((x) => x.name), ['hub']);

  const pending = http(gw.port, 'POST', '/api/computers/hub/call', { body: { service: 'metrics', method: 'get', args: { a: 1 } } });
  const asked = JSON.parse((await c.next()).text);
  assert.equal(asked.op, 'call');
  assert.equal(asked.service, 'metrics');
  assert.deepEqual(asked.args, { a: 1 });
  c.socket.write(clientFrame(JSON.stringify({ id: asked.id, ok: true, result: { up: 7 } })));
  const answer = await pending;
  assert.equal(answer.status, 200);
  assert.deepEqual(answer.json.result, { up: 7 });

  // an error from the computer is a 502, bad requests never reach it
  const failing = http(gw.port, 'POST', '/api/computers/hub/ping');
  const ping = JSON.parse((await c.next()).text);
  c.socket.write(clientFrame(JSON.stringify({ id: ping.id, ok: false, error: 'nope' })));
  assert.equal((await failing).status, 502);
  assert.equal((await http(gw.port, 'POST', '/api/computers/hub/call', { body: { method: 'get' } })).status, 400);
  assert.equal((await http(gw.port, 'POST', '/api/computers/hub/call', { body: '{not json' })).status, 400);
  assert.equal((await http(gw.port, 'POST', '/api/computers/ghost/ping')).status, 404);

  // websocket pings are answered
  c.socket.write(clientFrame('hello', 0x9));
  const pong = await c.next();
  assert.equal(pong.opcode, 0xA);
  assert.equal(pong.text, 'hello');
  c.socket.destroy();
});

await test('a disconnecting computer fails its pending calls and disappears', async () => {
  const c = await connectComputer(gw.port, { name: 'temp' });
  const pending = http(gw.port, 'POST', '/api/computers/temp/ping');
  await c.next();
  c.socket.destroy();
  const r = await pending;
  assert.equal(r.status, 502);
  assert.match(r.json.error, /disconnected/);
  await new Promise((r2) => setTimeout(r2, 50));
  const list = await http(gw.port, 'GET', '/api/computers');
  assert.ok(!list.json.some((x) => x.name === 'temp'));
});

await test('reconnecting replaces the old connection', async () => {
  const a = await connectComputer(gw.port, { name: 'dup' });
  const b = await connectComputer(gw.port, { name: 'dup' });
  const list = await http(gw.port, 'GET', '/api/computers');
  assert.equal(list.json.filter((x) => x.name === 'dup').length, 1);
  a.socket.destroy();
  b.socket.destroy();
});

await gw.close();
if (failures) { console.log(`\n${failures} failed`); process.exit(1); }
console.log('\ngateway tests passed');
