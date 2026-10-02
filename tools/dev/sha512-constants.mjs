// SPDX-License-Identifier: AGPL-3.0-or-later
// Prints the SHA-512 constants (FIPS 180-4) as Lua tables of 32-bit halves, computed with exact integer arithmetic:
// the first 64 bits of the fractional parts of the cube roots (K) and square roots (H0) of the first primes.
//   node tools/dev/sha512-constants.mjs
const primes = [];
for (let n = 2; primes.length < 80; n++) if (primes.every((p) => p * p > n || n % p !== 0)) primes.push(n);

function iroot(n, k) { // floor of the k-th root of a BigInt
  let lo = 0n, hi = 1n << (BigInt(n.toString(2).length) / BigInt(k) + 2n);
  while (lo < hi) {
    const mid = (lo + hi + 1n) >> 1n;
    if (mid ** BigInt(k) <= n) lo = mid; else hi = mid - 1n;
  }
  return lo;
}
const frac64 = (p, k) => iroot(BigInt(p) << (BigInt(k) * 64n), k) & ((1n << 64n) - 1n); // frac(p^(1/k)) * 2^64
const hex = (v) => v.toString(16).padStart(16, '0');
const half = (v, hi) => '0x' + (hi ? hex(v).slice(0, 8) : hex(v).slice(8));

const K = primes.map((p) => frac64(p, 3));
const H = primes.slice(0, 8).map((p) => frac64(p, 2));
const fmt = (arr, hi) => arr.map((v) => half(v, hi)).reduce((rows, h, i) => {
  if (i % 4 === 0) rows.push([]);
  rows.at(-1).push(h);
  return rows;
}, []).map((r) => '  ' + r.join(', ') + ',').join('\n');
console.log('local Kh = {\n' + fmt(K, true) + '\n}');
console.log('local Kl = {\n' + fmt(K, false) + '\n}');
console.log('local H0h = { ' + H.map((v) => half(v, true)).join(', ') + ' }');
console.log('local H0l = { ' + H.map((v) => half(v, false)).join(', ') + ' }');
console.error('first K: ' + hex(K[0]) + ' (expect 428a2f98d728ae22), last K: ' + hex(K[79]) + ' (expect 6c44198c4a475817), H0[0]: ' + hex(H[0]) + ' (expect 6a09e667f3bcc908)');
