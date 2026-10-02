# tsr.pgp

Package: `pgp`

PGP-style public key cryptography for ComputerCraft: key pairs with an identity, signing and verification, encryption to several
recipients or with a passphrase, key certification (web of trust) and revocation.

HONEST NOTE: this follows the ideas of OpenPGP (identity-bound keys, self-signatures, certifications, session keys, armored
text) with modern primitives (Ed25519 signatures, X25519 key agreement, ChaCha20-Poly1305, HKDF, PBKDF2), but it is its own
compact format: it cannot talk to GnuPG and it is not meant to. The primitives are the real, standard ones and are
checked against test vectors; see tsr.crypto.

A key (table):  { packet, created, expires, signPub, encPub, uid, fp (32 bytes), fp20, selfSig, certs, revoked, secret }
  fingerprint  = SHA-256 of the key packet; shown as 10 groups of 4 hex digits (the first 20 bytes). Key id = its last 16 hex digits.

## `M.parsePacket(packet)`

Decode a key packet (type 1 record data) into a key table (without secrets or signatures).

## `M.fingerprint(key)`

The fingerprint as "ABCD EF01 ..." (40 hex digits in groups of four, upper case).

## `M.keyId(key)`

Short key id (the last 16 hex digits of the fingerprint).

## `M.generate(uid, opts)`

Create a key pair for identity `uid` ("Name <note>"). opts: expires (seconds from now), created (default now).

## `M.selfSigned(key)`

Is the key's self-signature valid (the identity really belongs to the key)?

## `M.revoke(key, reason)`

Revoke a key (needs its secret): marks it and keeps a signed revocation certificate. reason: 0 unspecified, 1 compromised, 2 retired.

## `M.certify(signer, target, level)`

Certify (vouch for) another key: signer says "this identity belongs to this key". level 1 = checked casually, 2 = checked carefully.

## `M.certValid(target, cert, signer)`

Is `cert` on `target` genuinely made by `signer` (a key table)?

## `M.exportPublic(key)`

Armored public key block (identity, self-signature, certifications, revocation).

## `M.exportSecret(key, passphrase)`

Armored secret key block. A non-empty passphrase seals the secret part.

## `M.parseBlock(bin)`

Parse a key block (public or secret). Returns key (secret is nil until unlocked: see `unlock`) or nil + reason.
The key's self-signature and every revocation are checked; certifications are kept and verified by whoever has the signer's key.

## `M.importText(text)`

Parse armored text.

## `M.needsPassphrase(key)`

Does this key (from a SECRET KEY block) have a secret part, and does it need a passphrase?

## `M.unlock(key, passphrase)`

Unlock the secret part of a parsed key. Returns true or nil + "passphrase" (needed or wrong) / reason.

## `M.sign(data, key, opts)`

Sign data. opts: text (sign the canonical text form). Returns the signature as a binary blob (one SIGNATURE record).

## `M.parseSignature(bin)`

Decode a signature blob. Returns { signer (fp20), created, kind, digest, sig } or nil + reason.

## `M.verify(data, sigInfo, key)`

Check a signature against `data` and the signer's public key. Returns true, or false + reason.

## `M.armorSignature(bin)`

Armored detached signature.

## `M.clearsign(text, key)`

Clear-signed text: the readable message plus an armored signature of its canonical form.

## `M.parseClearsigned(text)`

Split a clear-signed message into its text and signature info. Returns text, sigInfo or nil + reason.

## `M.encrypt(plain, recipients, opts)`

Encrypt `plain` to `recipients` (list of key tables) and/or a passphrase. opts: signer (secret key table), passphrase.
Returns the message as a binary blob.

## `M.decrypt(bin, keys, opts)`

Decrypt a message blob. `keys` is a list of key tables with unlocked secrets; opts.passphrase is tried for passphrase-encrypted
messages. Returns plaintext, info ({ signature = sigInfo|nil, recipient = key|nil }) or nil + reason.

## `M.validity(keys, ownerTrust, opts)`

Which keys can be considered valid, given a list of keys, owner trust levels ({ [fpHex] = "ultimate"|"full"|"marginal"|"none" })
and the keys the user owns? A key is valid when it is ultimately trusted (your own), certified by one valid key of full trust,
or certified by `marginals` (default 3) valid keys of marginal trust; validity spreads up to `depth` (default 5) steps.
Returns { [fpHex] = { valid = bool, reason = string } }.
