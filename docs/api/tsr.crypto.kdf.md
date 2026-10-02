# tsr.crypto.kdf

Package: `crypto`

Key derivation: HKDF-SHA256 (RFC 5869) and PBKDF2-HMAC-SHA256 (RFC 8018), on tsr.hash.

## `M.sha256(msg)`

SHA-256 as a 32-byte binary string.

## `M.extract(salt, ikm)`

HKDF-Extract: a pseudo-random key from input keying material (salt may be nil).

## `M.expand(prk, info, len)`

HKDF-Expand: `len` bytes (at most 255 * 32) from a pseudo-random key and context `info`.

## `M.hkdf(ikm, salt, info, len)`

HKDF in one call.

## `M.pbkdf2(password, salt, iterations, len)`

PBKDF2-HMAC-SHA256: `len` bytes from a password and salt after `iterations` rounds (yields now and then).
