# tsr.crypto

Package: `crypto`

Tessera cryptography: real, standard algorithms in pure Lua, checked against the RFC test vectors.
  crypto.sha512 / crypto.hash.sha256   hashes             crypto.kdf     HKDF, PBKDF2, HMAC
  crypto.ed25519                       signatures         crypto.x25519  Diffie-Hellman key agreement
  crypto.chacha                        ChaCha20-Poly1305  crypto.rand    random bytes (see its notes on entropy)
plus small conveniences: key pair creation, constant-time comparison, a sealed-box ("encrypt to a public key") and
a "sign a digest" scheme for large documents (tsr.crypto.sign).

## `M.equal(a, b)`

Constant-time comparison of two strings.

## `M.signingKey(seed)`

A new signing key pair { secret = seed32, public = public32 }.

## `M.agreementKey(secret)`

A new key agreement pair { secret, public }.

## `M.signData(secret, data, context)`

Sign arbitrary-length data (see tsr.crypto.sign): `context` separates uses ("registry-index", "file"...).

## `M.fingerprint(public)`

Short human-checkable fingerprint of a public key: SHA256:<base64 without padding> (like OpenSSH).

## `M.seal(recipientPublic, plain, info)`

"Sealed box": encrypt `plain` so that only the owner of `recipientPublic` (x25519) can read it. A fresh ephemeral key is
used for every message, so a leaked sender key reveals nothing. Output: ephemeralPublic(32) .. ciphertext .. tag.
