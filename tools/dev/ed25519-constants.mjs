// SPDX-License-Identifier: AGPL-3.0-or-later
// Prints the Curve25519 / Ed25519 field constants as 16 little-endian 16-bit limbs (the representation used by
// src/crypto/.../fe.lua), computed with exact BigInt arithmetic.
//   node tools/dev/ed25519-constants.mjs
const p = (1n << 255n) - 19n;
const mod = (a) => ((a % p) + p) % p;
const pow = (b, e) => { let r = 1n; b = mod(b); while (e > 0n) { if (e & 1n) r = mod(r * b); b = mod(b * b); e >>= 1n; } return r; };
const inv = (a) => pow(a, p - 2n);
const limbs = (v) => Array.from({ length: 16 }, (_, i) => '0x' + ((v >> BigInt(16 * i)) & 0xffffn).toString(16).padStart(4, '0')).join(', ');

const d = mod(-121665n * inv(121666n));
const I = pow(2n, (p - 1n) / 4n);
const y = mod(4n * inv(5n));
let x = pow(mod((y * y - 1n) * inv(d * y * y + 1n)), (p + 3n) / 8n);
if (mod(x * x - (y * y - 1n) * inv(d * y * y + 1n)) !== 0n) x = mod(x * I);
if (x & 1n) x = p - x; // the base point has an even x
console.error('check B.x =', x.toString(), '(expect 15112221349535400772501151409588531511454012693041857206046113283949847762202)');
console.error('check B.y =', y.toString(), '(expect 46316835694926478169428394003475163141307993866256225615783033603165251855960)');
console.log('M.D = { ' + limbs(d) + ' }');
console.log('M.D2 = { ' + limbs(mod(2n * d)) + ' }');
console.log('M.BX = { ' + limbs(x) + ' }');
console.log('M.BY = { ' + limbs(y) + ' }');
console.log('M.SQRTM1 = { ' + limbs(I) + ' }');
