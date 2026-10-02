// SPDX-License-Identifier: AGPL-3.0-or-later
// Registry signing for the build tooling, with Node's crypto. Same scheme as src/crypto/.../sign.lua:
//   Ed25519 over  "tessera-signature-v1" 0x00 <context> 0x00 SHA-256(document)
// Signature files are JSON: { format: 1, alg: "ed25519", keyid: <16 hex>, sig: <base64 of 64 bytes> }.
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign as edSign, verify as edVerify } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

export const CONTEXT = 'registry-index';
export const TRUST_CONTEXT = 'registry-trust';

const PKCS8 = Buffer.from('302e020100300506032b657004220420', 'hex');
const sha256 = (b) => createHash('sha256').update(b).digest();

export const keyId = (publicHex) => sha256(Buffer.from(publicHex, 'hex')).toString('hex').slice(0, 16);

const statement = (data, context) => Buffer.concat([Buffer.from('tessera-signature-v1\0' + context + '\0', 'latin1'), sha256(data)]);

const privateKey = (seedHex) => createPrivateKey({ key: Buffer.concat([PKCS8, Buffer.from(seedHex, 'hex')]), format: 'der', type: 'pkcs8' });
const publicHexOf = (seedHex) => createPublicKey(privateKey(seedHex)).export({ format: 'der', type: 'spki' }).subarray(-32).toString('hex');

/** A new key: { format, alg, name, seed, public, keyid }. */
export function generateKey(name = 'Tessera registry key') {
  const { privateKey: priv } = generateKeyPairSync('ed25519');
  const seed = priv.export({ format: 'der', type: 'pkcs8' }).subarray(-32).toString('hex');
  const pub = publicHexOf(seed);
  return { format: 1, alg: 'ed25519', name, seed, public: pub, keyid: keyId(pub) };
}

export function saveKey(path, key) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(key, null, 2) + '\n', { mode: 0o600 });
  try { chmodSync(path, 0o600); } catch { /* Windows: permissions come from the folder */ }
}

export function loadKey(path) {
  if (!existsSync(path)) throw new Error(`signing key file not found: ${path}`);
  const key = JSON.parse(readFileSync(path, 'utf8'));
  if (key.alg !== 'ed25519' || !/^[0-9a-f]{64}$/.test(key.seed ?? '')) throw new Error(`${path} is not a Tessera signing key file`);
  key.public = publicHexOf(key.seed);
  key.keyid = keyId(key.public);
  return key;
}

/** Signature file text for `data` (Buffer or string). */
export function signText(key, data, context = CONTEXT) {
  const sig = edSign(null, statement(Buffer.from(data), context), privateKey(key.seed));
  return JSON.stringify({ format: 1, alg: 'ed25519', keyid: key.keyid ?? keyId(key.public), sig: sig.toString('base64') });
}

export function verifyText(publicHex, data, sigText, context = CONTEXT) {
  const doc = JSON.parse(sigText);
  const pub = createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(publicHex, 'hex')]), format: 'der', type: 'spki' });
  return edVerify(null, statement(Buffer.from(data), context), pub, Buffer.from(doc.sig, 'base64'));
}
