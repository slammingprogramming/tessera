# tsr.pkg.sig

Package: `pkg`

Signed registries, the pure part (no files, no configuration; the bootstrap installer uses this module too).

Trust chain:   trusted public key  ->  signature file  ->  registry/index.json (raw bytes)
               index entry "docSha256"  ->  registry/packages/<name>.json (raw bytes)
               package manifest file hashes  ->  every payload
so one Ed25519 verification (plus SHA-256 checks) vouches for everything that is installed.

A signature file is JSON:  { "format": 1, "alg": "ed25519", "keyid": "<16 hex>", "sig": "<base64 of 64 bytes>" }.
The key id is the first 8 bytes of SHA-256(public key) in hex. Keys are listed as { "name": "...", "public": "<64 hex>" }.

## `M.keyId(public)`

The id of a 32-byte public key.

## `M.parseKeys(list, source)`

Keys from a JSON string or a list: returns { [keyid] = { id, name, public (32 bytes), source } }.

## `M.parseSignature(raw)`

Decode a signature file. Returns { keyid, sig } or nil + reason.

## `M.verify(raw, sigRaw, keys, context)`

Verify `raw` against signature file text `sigRaw` using `keys` (table from parseKeys). Returns the key entry that signed, or nil + reason.

## `M.makeSignature(secret, public, raw, context)`

Build the text of a signature file (used by tests and in-game tools; the build tooling does this in Node).

## `M.checkDoc(raw, entry)`

Does the package description text `raw` match the hash the signed index recorded for it?
