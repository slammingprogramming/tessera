# tsr.pkgmirror

Package: `pkg-mirror`

Package mirror server. Caches registry documents and blobs read from this computer's own package sources (internet,
offline bundles, ...) and serves them to paired computers through the "pkgmirror" service. Clients use a `lan` source
(tsr.pkg.src_lan). Everything is verified by the client anyway (blobs by SHA-256); pair only with mirrors you trust, because
manifests are only as trustworthy as the computer that serves them.

## `M.get(rel)`

The bytes for registry file `rel`: from the cache, else upstream (then cached). Returns data or nil + error.

## `M.serve(node)`

Register the "pkgmirror" service on `node`.

## `M.prefetch(names, log)`

Download everything needed to install `names` (and their dependencies) into the cache, so clients can install while this
computer is offline. names nil = every package in the index. Returns counts and a list of problems.

## `M.run(args, io, node)`

pkgmirror status | find | prefetch [package...] | clear | add <peer> (adds a lan source for a paired mirror)

## `M.daemon()`

The pkgmirrord service.
