# tsr.pgp.ring

Package: `pgp`

A keyring: the keys a person knows (public keys, their certifications) and owns (secret keys), plus owner trust for the web of
trust. Files live in one directory (default ~/.pgp):
  keys/<fingerprint>.pub    armored public key block      keys/<fingerprint>.sec   armored secret key block (own keys)
  trust.json                { ownertrust = { [fingerprint] = "ultimate" | "full" | "marginal" | "none" } }

## `M.defaultDir()`

The default keyring directory: ~/.pgp of the logged-in user, else /root/.pgp.

## `Ring:keys()`

All keys (public view), sorted by identity. Keys that have a secret file have `hasSecret = true`.

## `Ring:find(query)`

Find one key by fingerprint prefix, key id (last 16 digits) or part of the identity. Returns key or nil + reason.

## `Ring:add(text)`

Merge an armored key block into the keyring. Returns key, "new" | "updated" | "unchanged" or nil + reason.

## `Ring:addSecret(key, passphrase)`

Store an own key (with its secret part, optionally sealed by a passphrase). Marks it ultimately trusted.

## `Ring:unlock(key, passphrase)`

Load the secret part of one of your keys. Returns the unlocked key, or nil + "passphrase" / reason.

## `Ring:secretKeys()`

Keys whose secret part is in this ring.

## `Ring:validity()`

Validity of every key by the web of trust: { [fingerprint] = { valid, reason } }.

## `Ring:certify(signer, target, level)`

Certify `target` (a key of this ring) with your unlocked key `signer`, and store the certification.

## `Ring:saveRevocation(key)`

Persist a revocation made with pgp.revoke.
