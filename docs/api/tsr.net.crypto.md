# tsr.net.crypto

Package: `net`

Small cryptographic helpers built on SHA-256/HMAC (tsr.hash).
  * random bytes from a pool that mixes whatever entropy a ComputerCraft computer has (clock, timers, key timings): there
    is no real random source in the game, so treat keys as "good enough to keep other players out", not as military grade;
  * an HMAC-SHA256 stream cipher (CTR mode) for optional message encryption;
  * constant-time comparison.

## `M.addEntropy(...)`

Mix more entropy into the pool (event timings, user input...).

## `M.random(n)`

n random bytes as a string.

## `M.equal(a, b)`

Constant-time string comparison.

## `M.stream(key, nonce, len)`

Keystream of `len` bytes for (key, nonce).

## `M.encrypt(key, nonce, plain)`

Encrypt to text (base64). Never reuse a nonce with the same key.

## `M.cleanCode(code)`

Normalise what a person typed: upper case, no dashes or spaces.
