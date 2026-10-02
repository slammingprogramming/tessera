# tsr.pkg.trust

Package: `pkg`

Who may sign packages, and what to do about unsigned or wrongly signed registries.

  Trusted keys:  the keys built into this release (set by the project's build), plus keys in /etc/tsr/trust.json that the
                 administrator added (`pkg trust add`) or that a trusted key introduced through a signed trust update.
                 Revoked key ids are listed in the same file and win over everything.
  Policy:        config "pkg.signatures" = "require" (refuse anything not signed by a trusted key), "warn" (use it, say so),
                 "off". Default: "require" when any trusted key exists, otherwise "off" (development trees).
  Rollback:      the highest index "serial" seen per source is remembered; an older index is refused (an attacker replaying an
                 old registry to keep you on a version with a known hole). Expired indexes only produce a warning.

## `M.keys()`

All trusted keys: { [keyid] = { id, name, public, source } }.

## `M.list()`

Sorted list of the trusted keys.

## `M.policy()`

"require", "warn" or "off".

## `M.verifyIndex(srcName, raw, sigRaw)`

Check a source's index. Returns true plus a status word ("verified", "unchecked", "unsigned", "expired"),
or nil plus the reason it must not be used.

## `M.verifyDoc(entry, raw)`

Check a package description against the (already verified) index entry. Returns true or nil + reason.

## `M.sourceInfo(srcName)`

What was learnt about a source: { keyid, key, serial, time } or nil.

## `M.add(name, public)`

Add a key to the local trust list. `public` is 64 hex characters.

## `M.revoke(id)`

Stop trusting a key id (also blocks a built-in key).

## `M.applyUpdate(raw, sigRaw)`

Apply a signed trust update (registry/trust.json + signature): new keys are added, revoked ones removed. The update must be
signed by a key that is trusted already and carry a higher serial than the last one applied. Returns { added, revoked } or nil, err.
