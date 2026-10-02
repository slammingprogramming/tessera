# tsr.crypto.fe

Package: `crypto`

Arithmetic in the field GF(2^255 - 19), the base of X25519 and Ed25519.
An element is a table of 16 limbs of 16 bits (little endian, 1-based), the representation used by TweetNaCl: every
product of two limbs fits in a double (53 bits) so plain Lua numbers are exact. Limbs may be a little unnormalised
between operations; `pack` produces the canonical 32 bytes.
The hot function `mul` is generated as unrolled straight-line code at load time: no table indexing in the inner loops
makes it several times faster than the obvious double loop on the CC:T VM.

## `M.car(o)`

Propagate carries so every limb is in [0, 65535] (limb 16 wraps around with the factor 38 = 2^256 mod p).

## `M.sqr(o, a)`

o = a * a.

## `M.inv(o, a)`

o = a^-1 (Fermat: a^(p-2)).

## `M.pow2523(o, a)`

o = a^((p-5)/8) = a^(2^252 - 3), used for square roots.

## `M.pack(n)`

Canonical 32-byte little-endian string of the (fully reduced) element.

## `M.unpack(s)`

32-byte string (top bit ignored) to an element.

## `M.parity(a)`

Parity (lowest bit) of the canonical value.

## `M.neq(a, b)`

Are a and b different field elements?
