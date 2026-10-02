# tsr.crypto.sign

Package: `crypto`

Signing documents of any size. Ed25519 hashes the whole message twice with SHA-512, which is slow for a 100 KB registry index
on a game computer. So the signature covers a short, domain-separated statement instead:
    "tessera-signature-v1" 0x00 <context> 0x00 SHA-256(document)
(SHA-256 is fast here and just as collision-resistant for this purpose). `context` separates uses: a signature made for a
registry index is never valid as a signature of a file or of a trust update.
tools/lib/sign.mjs implements the same scheme with Node's crypto for the build tooling.

## `M.data(secret, data, context)`

64-byte signature of `data` under the 32-byte secret seed.

## `M.verify(public, data, signature, context)`

Is `signature` valid for `data` under the 32-byte public key and `context`?
