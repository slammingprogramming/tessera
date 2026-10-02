# tsr.crypto.chacha

Package: `crypto`

ChaCha20 (RFC 8439), Poly1305 and the combined AEAD, pure Lua on bit32.
  chacha.xor(key32, nonce12, counter, data)          -> data XOR keystream
  chacha.poly1305(key32, message)                    -> tag16
  chacha.seal(key32, nonce12, plaintext, aad)        -> ciphertext .. tag16
  chacha.open(key32, nonce12, sealed, aad)           -> plaintext, or nil when the tag does not match
A (key, nonce) pair must never be used twice. The ChaCha20 core is generated as straight-line code at load time.

## `M.xor(key, nonce, counter, data)`

XOR `data` with the ChaCha20 keystream for (key, nonce) starting at block `counter`.

## `M.poly1305(key, msg)`

16-byte Poly1305 authenticator of `msg` under the 32-byte one-time key.
