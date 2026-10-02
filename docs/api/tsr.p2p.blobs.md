# tsr.p2p.blobs

Package: `p2p`

Package payloads for the swarm: any computer that has a package file can hand it to its neighbours, and the package manager's `p2p`
source (tsr.pkg.src_p2p) fetches payloads that way. Trust is not needed: a payload is named by its SHA-256, the package manifest
(which carries that hash) is covered by the registry signature, and the downloader verifies the hash. A seeder re-checks the hash
of a file before it sends it, so a modified file is never offered.
  Seeded from:  the offline store and the mirror cache (whole blobs), and every file of an installed package (by the hash in
                the package database), so a computer that installed `ui-gui` can help another one install it.

## `M.lookup(sha)`

Where is a file with this SHA-256? Returns a path or nil. (The seeder verifies the content before sending.)

## `M.refresh()`

Forget the installed-file map (after installs or removals; tests).

## `M.attach(swarm)`

Let `swarm` serve package payloads.
