# tsr.pgp.keyserver

Package: `pgp`

An in-game key server: computers of a base publish their public keys to one computer (service "keyserver") and others look keys up
there. Only paired computers can talk to it (see tsr.net), and only PUBLIC key material is ever stored: whatever is uploaded
is re-exported as a public block. Certifications travel with the keys, so signing parties work: certify, then send-keys again.

## `M.serve(node)`

Register the "keyserver" service on a net node.

## `M.send(node, peer, key)`

Publish `key` to the computer `peer`. Returns the server's answer or nil + error.

## `M.receive(node, peer, query, keyring)`

Fetch a key by fingerprint or identity from `peer` and add it to `keyring`. Returns key, status or nil + error.
