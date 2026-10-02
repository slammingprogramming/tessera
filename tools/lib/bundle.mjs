// SPDX-License-Identifier: AGPL-3.0-or-later
// Encoder for Tessera offline bundles (format documented in src/core/root/sys/lib/tsr/bundle.lua).
import { createHash } from 'node:crypto';
import { deflateRawSync } from 'node:zlib';

export const KIND = { index: 1, package: 2, blob: 3, signature: 4 };

const sha256 = (b) => createHash('sha256').update(b).digest('hex');

function crc32(buf) {
  let crc = 0xffffffff;
  for (const b of buf) {
    crc ^= b;
    for (let i = 0; i < 8; i++) crc = crc & 1 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/** entries: [{ kind, name, data: Buffer|string }] -> uncompressed container Buffer */
export function buildContainer(entries) {
  const parts = [Buffer.from('TSRB'), Buffer.from([1]), Buffer.from([(entries.length >> 8) & 255, entries.length & 255])];
  for (const e of entries) {
    const name = Buffer.from(e.name);
    const data = Buffer.isBuffer(e.data) ? e.data : Buffer.from(e.data);
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    parts.push(Buffer.from([e.kind, name.length]), name, len, data);
  }
  return Buffer.concat(parts);
}

/** Bundle for the file-drop path: "TSRZ" + version byte + raw deflate. */
export function toFile(container) {
  return Buffer.concat([Buffer.from('TSRZ'), Buffer.from([1]), deflateRawSync(container, { level: 9 })]);
}

/** Bundle for the paste path: array of "TSR1 <id> <n>/<total> <crc> <base64>" lines. */
export function toChunks(container, chunkSize = 400) {
  const compressed = deflateRawSync(container, { level: 9 });
  const id = sha256(compressed).slice(0, 8);
  const b64 = compressed.toString('base64');
  const total = Math.ceil(b64.length / chunkSize);
  const lines = [];
  for (let i = 0; i < total; i++) {
    const payload = b64.slice(i * chunkSize, (i + 1) * chunkSize);
    lines.push(`TSR1 ${id} ${i + 1}/${total} ${crc32(Buffer.from(payload)).toString(16).padStart(8, '0')} ${payload}`);
  }
  return { id, lines, compressedSize: compressed.length };
}
