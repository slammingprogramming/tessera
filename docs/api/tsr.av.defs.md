# tsr.av.defs

Package: `av`

Definitions: the lists the scanner knows besides its built-in rules.
  hashes   SHA-256 of whole files that are known to be bad          { ["<sha256>"] = "Name" }
  patterns extra signatures (Lua patterns or plain text) with a score { { id, name, pattern, plain, score } }
  allow    SHA-256 of files that are known to be good (never reported) { ["<sha256>"] = "why" }
They come in two places: the file that ships with the package (/usr/share/av/defs.json), and an updated file (/var/lib/tsr/av/defs.json) that anyone can publish but
that is only accepted when its signature is valid for a key the administrator trusts (av trust add <key>). The version number must go up, so an old list cannot be
played back. Whoever publishes lists (a server operator, a community) makes a key with `av defs keygen`, signs with `av defs sign` and shares the public key.

## `M.keys()`

Trusted publisher keys: { { name, key (base64 of the 32-byte public key) } }.

## `M.keygen()`

Make a publisher key pair. Returns the secret seed (keep it private) and the public key (base64).

## `M.sign(text, secret)`

Signature (base64) of a definitions text under a 32-byte secret seed.

## `M.state()`

The version and publisher of the updated definitions that are installed (nil without any).

## `M.load()`

Everything the scanner uses: the built-in lists plus the updated ones when they are intact. Returns the merged table and a description of where it came from.

## `M.install(text, sig, opts)`

Accept new definitions. text: the JSON file, sig: base64 signature. Returns the version, or nil + reason.

## `M.fetch(source, opts)`

Fetch definitions from a place: a path, or an http(s) URL (the signature is at <source>.sig). Returns text, sig.

## `M.update(source, opts)`

Fetch and install from a source.
