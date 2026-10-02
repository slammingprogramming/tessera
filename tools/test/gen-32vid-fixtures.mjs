// SPDX-License-Identifier: AGPL-3.0-or-later
// Generates tests/fixtures/vid32_fixtures.lua: small 32vid files in every compression mode (none, DEFLATE, custom Huffman, ANS), as
// separate streams and as combined audio/video/subtitle streams, written by an encoder that follows sanjuuni's format description
// (README "32vid file format") and NOT the Lua decoder under test. The expected screens are recorded next to each file.
//   node tools/test/gen-32vid-fixtures.mjs
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { deflateRawSync } from 'node:zlib';
import { root } from '../lib/craftos.mjs';

function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const r = rng(32032);
const rint = (n) => Math.floor(r() * n);

// ---- content --------------------------------------------------------------------------------------------------------------------
function makeFrame(w, h, style) {
  const n = w * h;
  const text = new Array(n), fg = new Array(n), bg = new Array(n);
  for (let i = 0; i < n; i++) {
    if (style === 'solid-char') text[i] = 17;
    else text[i] = r() < 0.6 ? [0, 31, 15, 3][rint(4)] : rint(32);
    if (style === 'solid-color') { fg[i] = 5; bg[i] = 5; }
    else if (style === 'runs') { const band = Math.floor(i / (w * 3)); fg[i] = band % 3 === 0 ? 1 : band % 3 === 1 ? 7 : 12; bg[i] = i < n * 0.6 ? 0 : 9; }
    else { fg[i] = r() < 0.7 ? 1 : rint(16); bg[i] = r() < 0.7 ? 0 : rint(16); }
  }
  const palette = Array.from({ length: 16 }, () => [rint(256), rint(256), rint(256)]);
  return { text, fg, bg, palette };
}

// ---- bit and byte helpers -------------------------------------------------------------------------------------------------------
class Bits {
  constructor() { this.bits = []; }
  push(value, n) { for (let i = n - 1; i >= 0; i--) this.bits.push((value >> i) & 1); }
  bytes() {
    const out = [];
    for (let i = 0; i < this.bits.length; i += 8) {
      let b = 0;
      for (let k = 0; k < 8; k++) b = (b << 1) | (this.bits[i + k] ?? 0);
      out.push(b);
    }
    return Buffer.from(out);
  }
}
const u16 = (n) => Buffer.from([n & 255, (n >> 8) & 255]);
const u32 = (n) => Buffer.from([n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >>> 24) & 255]);
const paletteBytes = (p) => Buffer.from(p.flat());

// ---- raw ------------------------------------------------------------------------------------------------------------------------
function encodeRaw(f) {
  const n = f.text.length;
  const parts = [];
  for (let i = 0; i < n; i += 8) {
    let v = 0n;
    for (let k = 0; k < 8; k++) v = (v << 5n) | BigInt(f.text[i + k] ?? 0);
    const b = Buffer.alloc(5);
    for (let k = 4; k >= 0; k--) { b[k] = Number(v & 0xffn); v >>= 8n; }
    parts.push(b);
  }
  parts.push(Buffer.from(f.text.map((_, i) => (f.bg[i] << 4) | f.fg[i])));
  parts.push(paletteBytes(f.palette));
  return Buffer.concat(parts);
}

// ---- custom Huffman -------------------------------------------------------------------------------------------------------------
function huffmanLengths(symbols, size) {
  const freq = new Array(size).fill(0);
  for (const s of symbols) freq[s]++;
  const used = freq.map((f, s) => ({ s, f })).filter((x) => x.f > 0);
  if (used.length <= 1) return { lengths: new Array(size).fill(0), solid: used[0]?.s ?? 0 };
  let nodes = used.map((x) => ({ f: x.f, syms: [x.s] }));
  const depth = new Array(size).fill(0);
  while (nodes.length > 1) {
    nodes.sort((a, b) => a.f - b.f || a.syms[0] - b.syms[0]);
    const [a, b] = nodes.splice(0, 2);
    for (const s of [...a.syms, ...b.syms]) depth[s]++;
    nodes.push({ f: a.f + b.f, syms: [...a.syms, ...b.syms] });
  }
  if (Math.max(...depth) > 15) throw new Error('code too long for a 4-bit length: adjust the test data');
  return { lengths: depth, solid: null };
}
function canonicalCodes(lengths) {
  const list = lengths.map((l, s) => ({ l, s })).filter((x) => x.l > 0).sort((a, b) => a.l - b.l || a.s - b.s);
  const codes = new Map();
  let code = 0;
  list.forEach((e, i) => { if (i > 0) code = (code + 1) << (e.l - list[i - 1].l); codes.set(e.s, { code, len: e.l }); });
  return codes;
}
const lengthsTable = (lengths) => { const b = []; for (let i = 0; i < lengths.length; i += 2) b.push((lengths[i] << 4) | lengths[i + 1]); return Buffer.from(b); };

/** colour planes -> symbols: a literal, then run symbols (16 + k adds 2^(k+1) copies) */
function colorSymbols(values) {
  const out = [];
  let i = 0;
  while (i < values.length) {
    const v = values[i];
    let run = 1;
    while (i + run < values.length && values[i + run] === v) run++;
    out.push(v);
    let left = run - 1;
    while (left >= 2) {
      let k = 1;
      while (k < 8 && 2 ** (k + 1) <= left) k++;
      out.push(15 + k);
      left -= 2 ** k;
    }
    if (left === 1) out.push(v);
    i += run;
  }
  return out;
}

function encodeHuffman(f) {
  const parts = [];
  const { lengths, solid } = huffmanLengths(f.text, 32);
  parts.push(lengthsTable(lengths));
  if (solid !== null) parts.push(Buffer.from([solid]));
  else {
    const codes = canonicalCodes(lengths);
    const bits = new Bits();
    for (const s of f.text) { const c = codes.get(s); bits.push(c.code, c.len); }
    parts.push(bits.bytes());
  }
  const symbols = [...colorSymbols(f.fg), ...colorSymbols(f.bg)];
  const c = huffmanLengths(symbols, 24);
  parts.push(lengthsTable(c.lengths));
  if (c.solid !== null) parts.push(Buffer.from([c.solid]));
  else {
    const codes = canonicalCodes(c.lengths);
    const bits = new Bits();
    for (const s of symbols) { const e = codes.get(s); bits.push(e.code, e.len); }
    parts.push(bits.bytes());
  }
  parts.push(paletteBytes(f.palette));
  return Buffer.concat(parts);
}

// ---- ANS ------------------------------------------------------------------------------------------------------------------------
function ansBlock(symbols, size) {
  const freq = new Array(size).fill(0);
  for (const s of symbols) freq[s]++;
  const used = [];
  freq.forEach((f, s) => { if (f > 0) used.push(s); });
  const dictBytes = (codes) => { const b = []; for (let i = 0; i < size; i += 2) b.push((codes[i] << 4) | codes[i + 1]); return Buffer.from(b); };
  if (used.length === 1) return Buffer.concat([Buffer.from([0]), dictBytes(new Array(size).fill(0)), Buffer.from([used[0]])]);
  let R = 8;
  while (2 ** R < 8 * used.length) R++;
  const L = 2 ** R;
  // each used symbol owns a power of two of the L states; start with 1 and double the symbol with the best count/share ratio while it fits
  const Ls = new Array(size).fill(0);
  used.forEach((s) => { Ls[s] = 1; });
  let rest = L - used.length;
  for (;;) {
    let best = -1, bestScore = -1;
    for (const s of used) {
      if (Ls[s] <= rest && Ls[s] < 2 ** 14) {
        const score = freq[s] / Ls[s];
        if (score > bestScore) { best = s; bestScore = score; }
      }
    }
    if (best < 0) break;
    rest -= Ls[best];
    Ls[best] *= 2;
  }
  if (rest !== 0) throw new Error('could not normalise the ANS table');
  const codes = Ls.map((l) => (l === 0 ? 0 : Math.log2(l) + 1));
  // the decoder's table (spread and per-state transitions), reproduced from the format description
  const step = 0.625 * L + 3;
  const next = new Array(size).fill(0);
  const symbolAt = new Array(L).fill(-1);
  let x = 0;
  for (let s = 0; s < size; s++) {
    next[s] = Ls[s];
    for (let k = 0; k < Ls[s]; k++) {
      while (symbolAt[x] !== -1) x = (x + 1) % L;
      symbolAt[x] = s;
      x = (x + step) % L;
    }
  }
  const entries = Array.from({ length: size }, () => []);
  for (let st = 0; st < L; st++) {
    const s = symbolAt[st];
    const n = R - Math.floor(Math.log2(next[s]));
    entries[s].push({ state: st, n, base: (next[s] * 2 ** n) - L });
    next[s]++;
  }
  // encode backwards
  let X = 0;
  const emitted = [];
  for (let i = symbols.length - 1; i >= 0; i--) {
    const e = entries[symbols[i]].find((c) => X >= c.base && X < c.base + 2 ** c.n);
    if (!e) throw new Error('no ANS transition: table is not a partition');
    emitted.push({ bits: X - e.base, n: e.n });
    X = e.state;
  }
  const bits = new Bits();
  bits.push(X, R);
  for (let i = emitted.length - 1; i >= 0; i--) bits.push(emitted[i].bits, emitted[i].n);
  return Buffer.concat([Buffer.from([R]), dictBytes(codes), bits.bytes()]);
}

function encodeAns(f) {
  const color = [...colorSymbols(f.bg), ...colorSymbols(f.fg)];      // background first, then foreground (as sanjuuni's reader expects)
  return Buffer.concat([ansBlock(f.text, 32), ansBlock(color, 24), paletteBytes(f.palette)]);
}

// ---- containers -----------------------------------------------------------------------------------------------------------------
const ENCODERS = { 0: encodeRaw, 2: encodeRaw, 3: encodeHuffman, 1: encodeAns };

function header(w, h, fps, streams, flags) {
  return Buffer.concat([Buffer.from('32VD'), u16(w), u16(h), Buffer.from([fps, streams]), u16(flags)]);
}
const streamHeader = (size, count, type) => Buffer.concat([u32(size), u32(count), Buffer.from([type])]);
const frameHeader = (size, type) => Buffer.concat([u32(size), Buffer.from([type])]);

function subtitleBytes(s) {
  const text = Buffer.from(s.text);
  return Buffer.concat([u32(s.frame), u32(s.length), u16(s.x), u16(s.y), Buffer.from([s.color, 0]), u16(text.length), text]);
}

/** Combined stream: video frames with audio chunks and subtitles in between. */
function buildCombo(w, h, fps, comp, frames, audio, subtitles) {
  const flags = comp | 16;
  const chunks = [];
  let count = 0;
  const sub = [...subtitles];
  frames.forEach((f, i) => {
    for (const s of sub.filter((x) => x.frame === i)) { const b = subtitleBytes(s); chunks.push(frameHeader(b.length, 8), b); count++; }
    if (audio[i]) { chunks.push(frameHeader(audio[i].length, 1), audio[i]); count++; }
    const data = ENCODERS[comp](f);
    chunks.push(frameHeader(data.length, 0), data);
    count++;
  });
  const body = Buffer.concat(chunks);
  return Buffer.concat([header(w, h, fps, 1, flags), streamHeader(body.length, count, 12), body]);
}

/** Separate streams: video, audio, subtitles. */
function buildSeparate(w, h, fps, comp, frames, audioBytes, subtitles) {
  const flags = comp | 16;
  let video = Buffer.concat(frames.map((f) => ENCODERS[comp](f)));
  if (comp === 2) video = deflateRawSync(video, { level: 9 });
  const streams = [Buffer.concat([streamHeader(video.length, frames.length, 0), video])];
  if (audioBytes) streams.push(Buffer.concat([streamHeader(audioBytes.length, audioBytes.length, 1), audioBytes]));
  if (subtitles.length) {
    const subs = Buffer.concat(subtitles.map(subtitleBytes));
    streams.push(Buffer.concat([streamHeader(subs.length, subtitles.length, 8), subs]));
  }
  return Buffer.concat([header(w, h, fps, streams.length, flags), ...streams]);
}

// ---- the fixtures ---------------------------------------------------------------------------------------------------------------
const W = 24, H = 10;
const styles = ['noise', 'runs', 'solid-char', 'solid-color', 'noise'];
const frames = styles.map((s) => makeFrame(W, H, s));
const pcm = (n, salt) => Buffer.from(Array.from({ length: n }, (_, i) => (i * 7 + salt) & 255));
const audio = [pcm(480, 1), null, pcm(240, 2), null, pcm(120, 3)];
const subtitles = [{ frame: 1, length: 2, x: 3, y: 4, color: 0xf0, text: 'hello 32vid' }, { frame: 3, length: 1, x: 1, y: 1, color: 0x0f, text: 'bye' }];

const cases = [
  { name: 'combo ANS', data: buildCombo(W, H, 10, 1, frames, audio, subtitles) },
  { name: 'combo custom Huffman', data: buildCombo(W, H, 12, 3, frames, audio, subtitles) },
  { name: 'combo uncompressed', data: buildCombo(W, H, 8, 0, frames.slice(0, 3), audio, []) },
  { name: 'separate uncompressed', data: buildSeparate(W, H, 10, 0, frames, pcm(900, 5), subtitles) },
  { name: 'separate DEFLATE', data: buildSeparate(W, H, 10, 2, frames, pcm(300, 9), []) },
  { name: 'separate custom Huffman', data: buildSeparate(W, H, 10, 3, frames, null, subtitles) },
  { name: 'separate ANS', data: buildSeparate(W, H, 10, 1, frames, null, []) },
];
const COUNTS = { 'combo uncompressed': 3 };

const HEX = '0123456789abcdef';
const luaStr = (buf) => '"' + [...buf].map((b) => (b >= 32 && b < 127 && b !== 34 && b !== 92 ? String.fromCharCode(b) : '\\' + String(b).padStart(3, '0'))).join('') + '"';
function expectedFrame(f) {
  const lines = [];
  for (let y = 0; y < H; y++) {
    const t = [], fgs = [], bgs = [];
    for (let x = 0; x < W; x++) { const i = y * W + x; t.push(128 + f.text[i]); fgs.push(HEX[f.fg[i]]); bgs.push(HEX[f.bg[i]]); }
    lines.push(`{ ${luaStr(Buffer.from(t))}, "${fgs.join('')}", "${bgs.join('')}" }`);
  }
  return `{ lines = { ${lines.join(', ')} }, palette = { ${f.palette.map((p) => `{ ${p.join(', ')} }`).join(', ')} } }`;
}

const out = ['-- SPDX-License-Identifier: AGPL-3.0-or-later', '-- GENERATED by tools/test/gen-32vid-fixtures.mjs - do not edit.', 'return {', `  width = ${W}, height = ${H},`];
out.push('  expected = {');
frames.forEach((f) => out.push('    ' + expectedFrame(f) + ','));
out.push('  },');
out.push(`  audio = { ${audio.map((a) => (a ? luaStr(a) : 'false')).join(', ')} },`);
out.push(`  subtitles = { ${subtitles.map((s) => `{ frame = ${s.frame}, length = ${s.length}, x = ${s.x}, y = ${s.y}, text = ${JSON.stringify(s.text)} }`).join(', ')} },`);
out.push('  files = {');
for (const c of cases) out.push(`    { name = ${JSON.stringify(c.name)}, frames = ${COUNTS[c.name] ?? frames.length}, b64 = "${c.data.toString('base64')}" },`);
out.push('  },');
out.push('}');
mkdirSync(join(root, 'tests', 'fixtures'), { recursive: true });
writeFileSync(join(root, 'tests', 'fixtures', 'vid32_fixtures.lua'), out.join('\n') + '\n');
console.log(`wrote tests/fixtures/vid32_fixtures.lua: ${cases.map((c) => `${c.name} ${c.data.length} B`).join(', ')}`);
