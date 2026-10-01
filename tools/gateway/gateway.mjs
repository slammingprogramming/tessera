// SPDX-License-Identifier: AGPL-3.0-or-later
// Tessera web gateway: a small HTTP + WebSocket server (no dependencies) that sits between the web and ComputerCraft computers
// running the `webgw` package. Computers connect OUT to ws://<this machine>:<port>/ws; browsers and scripts call
//
//   GET  /api/computers                      -> [{ "name": "hub", "connected": "2026-10-01T12:00:00.000Z" }]
//   POST /api/computers/<name>/call          body {"service":"metrics","method":"get","args":{},"target":"local"}
//   POST /api/computers/<name>/ping | /list
//
// Every request needs the header  Authorization: Bearer <token>.  Usage:
//   node tools/gateway/gateway.mjs [--host 127.0.0.1] [--port 8080] [--token <secret>]   (or GATEWAY_TOKEN in the environment)
// Without --token a random one is printed once at start. Keep the default host (loopback) unless you put a TLS proxy in front:
// the token travels in clear text otherwise.
import { createServer } from 'node:http';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const CALL_TIMEOUT_MS = 15000;
const MAX_BODY = 64 * 1024;
const MAX_FRAME = 1024 * 1024;

function safeEqual(a, b) {
  const x = Buffer.from(String(a)), y = Buffer.from(String(b));
  return x.length === y.length && timingSafeEqual(x, y);
}

/** Encode one unmasked text frame (server -> client). */
export function encodeFrame(text, opcode = 0x1) {
  const payload = Buffer.from(text);
  const n = payload.length;
  let head;
  if (n < 126) head = Buffer.from([0x80 | opcode, n]);
  else if (n < 65536) { head = Buffer.alloc(4); head[0] = 0x80 | opcode; head[1] = 126; head.writeUInt16BE(n, 2); }
  else { head = Buffer.alloc(10); head[0] = 0x80 | opcode; head[1] = 127; head.writeBigUInt64BE(BigInt(n), 2); }
  return Buffer.concat([head, payload]);
}

/** Incremental frame parser. feed(buffer) returns completed messages [{ opcode, data }]; throws on protocol errors. */
export function createParser() {
  let buf = Buffer.alloc(0);
  let fragments = [];
  let fragOpcode = 0;
  return function feed(chunk) {
    buf = Buffer.concat([buf, chunk]);
    const out = [];
    for (;;) {
      if (buf.length < 2) break;
      const fin = (buf[0] & 0x80) !== 0;
      const opcode = buf[0] & 0x0f;
      const masked = (buf[1] & 0x80) !== 0;
      let len = buf[1] & 0x7f;
      let off = 2;
      if (len === 126) { if (buf.length < 4) break; len = buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (buf.length < 10) break; len = Number(buf.readBigUInt64BE(2)); off = 10; }
      if (len > MAX_FRAME) throw new Error('frame too large');
      if (!masked) throw new Error('client frames must be masked');
      if (buf.length < off + 4 + len) break;
      const mask = buf.subarray(off, off + 4);
      const data = Buffer.from(buf.subarray(off + 4, off + 4 + len));
      for (let i = 0; i < len; i++) data[i] ^= mask[i % 4];
      buf = buf.subarray(off + 4 + len);
      if (opcode >= 0x8) { out.push({ opcode, data }); continue; }          // control frames are never fragmented
      if (opcode !== 0) { fragments = [data]; fragOpcode = opcode; } else fragments.push(data);
      if (fin) { out.push({ opcode: fragOpcode, data: Buffer.concat(fragments) }); fragments = []; }
      else if (fragments.reduce((s, f) => s + f.length, 0) > MAX_FRAME) throw new Error('message too large');
    }
    return out;
  };
}

/** Start a gateway. Returns { server, token, port, close() }. */
export function startGateway({ host = '127.0.0.1', port = 8080, token } = {}) {
  token ??= randomBytes(16).toString('hex');
  const computers = new Map();     // name -> { socket, since, pending: Map(id -> { resolve, timer }), nextId }

  const authorized = (req) => {
    const h = req.headers.authorization ?? '';
    return h.startsWith('Bearer ') && safeEqual(h.slice(7), token);
  };

  const server = createServer(async (req, res) => {
    const send = (code, body) => {
      res.writeHead(code, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    if (!authorized(req)) return send(401, { error: 'missing or wrong bearer token' });
    const url = new URL(req.url, 'http://x');
    if (req.method === 'GET' && url.pathname === '/api/computers') {
      return send(200, [...computers].map(([name, c]) => ({ name, connected: c.since })));
    }
    const m = url.pathname.match(/^\/api\/computers\/([^/]+)\/(call|ping|list)$/);
    if (req.method === 'POST' && m) {
      const comp = computers.get(decodeURIComponent(m[1]));
      if (!comp) return send(404, { error: 'that computer is not connected' });
      let body = '';
      for await (const chunk of req) {
        body += chunk;
        if (body.length > MAX_BODY) return send(413, { error: 'body too large' });
      }
      let args = {};
      if (body.trim()) { try { args = JSON.parse(body); } catch { return send(400, { error: 'body is not JSON' }); } }
      const msg = m[2] === 'call'
        ? { op: 'call', service: args.service, method: args.method, args: args.args, target: args.target }
        : { op: m[2] };
      if (m[2] === 'call' && (typeof msg.service !== 'string' || typeof msg.method !== 'string')) {
        return send(400, { error: 'service and method are required' });
      }
      const reply = await ask(comp, msg);
      return send(reply.error === 'timeout' ? 504 : reply.ok ? 200 : 502, reply);
    }
    send(404, { error: 'not found' });
  });

  function ask(comp, msg) {
    return new Promise((resolve) => {
      const id = comp.nextId++;
      const timer = setTimeout(() => { comp.pending.delete(id); resolve({ ok: false, error: 'timeout' }); }, CALL_TIMEOUT_MS);
      comp.pending.set(id, { resolve, timer });
      comp.socket.write(encodeFrame(JSON.stringify({ ...msg, id })));
    });
  }

  server.on('upgrade', (req, socket) => {
    const url = new URL(req.url, 'http://x');
    const key = req.headers['sec-websocket-key'];
    const name = String(req.headers['x-computer'] ?? '').slice(0, 64);
    if (url.pathname !== '/ws' || !key || !authorized(req) || !/^[\w .-]+$/.test(name)) {
      socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      return;
    }
    const accept = createHash('sha1').update(key + GUID).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    const old = computers.get(name);
    if (old) old.socket.destroy();
    const comp = { socket, since: new Date().toISOString(), pending: new Map(), nextId: 1 };
    computers.set(name, comp);
    const feed = createParser();
    const drop = () => {
      if (computers.get(name) === comp) computers.delete(name);
      for (const { resolve, timer } of comp.pending.values()) { clearTimeout(timer); resolve({ ok: false, error: 'computer disconnected' }); }
      comp.pending.clear();
    };
    socket.on('data', (chunk) => {
      let messages;
      try { messages = feed(chunk); } catch { socket.destroy(); return; }
      for (const { opcode, data } of messages) {
        if (opcode === 0x8) { socket.end(encodeFrame('', 0x8)); }
        else if (opcode === 0x9) socket.write(encodeFrame(data.toString(), 0xA));
        else if (opcode === 0x1) {
          let reply;
          try { reply = JSON.parse(data.toString()); } catch { continue; }
          const p = comp.pending.get(reply.id);
          if (p) { clearTimeout(p.timer); comp.pending.delete(reply.id); p.resolve(reply); }
        }
      }
    });
    socket.on('end', () => socket.end());
    socket.on('close', drop);
    socket.on('error', drop);
  });

  return new Promise((resolve) => {
    server.listen(port, host, () => {
      resolve({
        server, token, port: server.address().port, computers,
        close: () => new Promise((done) => {
          for (const c of computers.values()) c.socket.destroy();
          server.close(() => done());
        }),
      });
    });
  });
}

// CLI
if (import.meta.url === new URL(process.argv[1], 'file://').href || process.argv[1]?.endsWith('gateway.mjs')) {
  const argv = process.argv.slice(2);
  const opt = (name, def) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : def; };
  const gw = await startGateway({
    host: opt('--host', '127.0.0.1'), port: Number(opt('--port', 8080)), token: opt('--token', process.env.GATEWAY_TOKEN),
  });
  console.log(`Tessera gateway listening on http://${opt('--host', '127.0.0.1')}:${gw.port}`);
  if (!opt('--token', process.env.GATEWAY_TOKEN)) console.log(`Token (shown once): ${gw.token}`);
  console.log('Computers: webgw setup ws://<this machine>:' + gw.port + '/ws <token>');
}
