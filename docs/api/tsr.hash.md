# tsr.hash

Package: `core`

Hashing and encoding primitives: SHA-256, CRC-32, Base64, hex. Pure Lua on top of bit32 (present in CC:T).
Long inputs yield to the scheduler periodically so CC's "too long without yielding" watchdog never fires.

## `M.sha256(msg)`

SHA-256 of `msg`, returned as a 64-character lowercase hex string.

## `M.hmacSha256(key, msg)`

HMAC-SHA256 (RFC 2104) of `msg` under `key`, as 64 hex characters.

## `M.crc32(s, crc)`

CRC-32 of `s` as an unsigned number. `crc` continues a previous result.

## `M.base64Decode(s)`

Decode Base64; whitespace is ignored. Returns nil, err on invalid input.
