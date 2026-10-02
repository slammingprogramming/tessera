// SPDX-License-Identifier: AGPL-3.0-or-later
// Client-side builder for Tessera offline bundles (the format of src/core/root/sys/lib/tsr/bundle.lua). It runs in the browser
// (and in Node 18+ for tests): nothing is uploaded anywhere. The page fetches the registry files from the same site, chooses the
// packages with their dependencies, and packs them.
export const KIND = { index: 1, package: 2, blob: 3, signature: 4 };

const enc = new TextEncoder();

/** CRC-32 (IEEE) of a byte array, as an unsigned number. */
export function crc32(bytes) {
  let table = crc32.table;
  if (!table) {
    table = crc32.table = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[n] = c >>> 0;
    }
  }
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) crc = table[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

export async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Dependency closure of `wanted` over the registry index and package documents. Returns the sorted list of package names. */
export function resolve(wanted, index, docs) {
  const names = new Set();
  const visit = (n) => {
    if (names.has(n)) return;
    if (!index.packages[n]) throw new Error(`unknown package ${n}`);
    names.add(n);
    const doc = docs[n];
    const manifest = doc.versions[doc.latest];
    for (const dep of Object.keys(manifest.requires ?? {})) if (index.packages[dep]) visit(dep);
  };
  for (const n of wanted) visit(n);
  return [...names].sort();
}

/** entries: [{ kind, name, data: Uint8Array | string }] -> the uncompressed container ("TSRB"). */
export function buildContainer(entries) {
  const chunks = [enc.encode('TSRB'), Uint8Array.of(1), Uint8Array.of((entries.length >> 8) & 255, entries.length & 255)];
  for (const e of entries) {
    const name = enc.encode(e.name);
    const data = typeof e.data === 'string' ? enc.encode(e.data) : e.data;
    const len = new Uint8Array(4);
    new DataView(len.buffer).setUint32(0, data.length);
    chunks.push(Uint8Array.of(e.kind, name.length), name, len, data);
  }
  let total = 0;
  for (const c of chunks) total += c.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { out.set(c, off); off += c.length; }
  return out;
}

/** Raw DEFLATE of a byte array using the browser's (or Node's) CompressionStream. */
export async function deflateRaw(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** The drag-and-drop file: "TSRZ" + version + raw deflate. */
export async function toFile(container) {
  const z = await deflateRaw(container);
  const out = new Uint8Array(5 + z.length);
  out.set(enc.encode('TSRZ'), 0);
  out[4] = 1;
  out.set(z, 5);
  return out;
}

export function toBase64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

/** The paste lines: "TSR1 <id> <n>/<total> <crc> <base64>". */
export async function toChunks(container, chunkSize = 400) {
  const z = await deflateRaw(container);
  const id = (await sha256Hex(z)).slice(0, 8);
  const b64 = toBase64(z);
  const total = Math.ceil(b64.length / chunkSize);
  const lines = [];
  for (let i = 0; i < total; i++) {
    const payload = b64.slice(i * chunkSize, (i + 1) * chunkSize);
    lines.push(`TSR1 ${id} ${i + 1}/${total} ${crc32(enc.encode(payload)).toString(16).padStart(8, '0')} ${payload}`);
  }
  return { id, lines, compressedSize: z.length };
}

/** Everything the page does after the user picked packages: fetch blobs, build the container. fetchBytes(url) -> Uint8Array.
 *  A signed registry passes `indexRaw` + `indexSig` (the files exactly as served) and `docsRaw` (name -> text): they are packed
 *  unchanged so the signatures and hashes stay valid. Calls progress(done, total). Returns { container, names, size }. */
export async function assemble(wanted, { index, docs, indexRaw, indexSig, docsRaw, fetchBytes, progress }) {
  const names = resolve(wanted, index, docs);
  const subIndex = { format: 1, packages: {} };
  const entries = [];
  const blobs = new Set();
  for (const n of names) {
    subIndex.packages[n] = index.packages[n];
    entries.push({ kind: KIND.package, name: n, data: docsRaw?.[n] ?? JSON.stringify(docs[n]) });
    for (const f of docs[n].versions[docs[n].latest].files) blobs.add(f.sha256);
  }
  if (indexSig && indexRaw) {
    entries.unshift({ kind: KIND.signature, name: 'index', data: indexSig });
    entries.unshift({ kind: KIND.index, name: 'index', data: indexRaw });
  } else {
    entries.unshift({ kind: KIND.index, name: 'index', data: JSON.stringify(subIndex) });
  }
  const list = [...blobs].sort();
  let done = 0;
  for (const sha of list) {
    const data = await fetchBytes(`blobs/${sha}`);
    if ((await sha256Hex(data)) !== sha) throw new Error(`blob ${sha.slice(0, 12)} failed its checksum`);
    entries.push({ kind: KIND.blob, name: sha, data });
    progress?.(++done, list.length);
  }
  const container = buildContainer(entries);
  return { container, names, size: container.length };
}
