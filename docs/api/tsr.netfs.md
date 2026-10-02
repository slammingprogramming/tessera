# tsr.netfs

Package: `netfs`

Network file sharing.
  Server: export folders to paired computers      netfs.serve(node, exports)   (the netfsd service does this from /etc/tsr/netfs.exports)
  Client: mount a remote export as a directory    netfs.mount(node, "peer", "export", "/mnt/peer")

exports = { name = { path = "/srv/data", readonly = true, peers = { "alpha" } } }   (peers: nil = every paired computer)
Files travel in 8 KB chunks. A file opened for reading is fetched completely first; one opened for writing is sent
when it is closed. Paths cannot escape the exported folder.

## `M.serve(node, exports)`

Register the "fs" service on `node`. `exports` may be a table or a function returning one (re-read on each call).

## `M.provider(node, peer, exportName, opts)`

A vfs provider that forwards to `peer`'s export. opts: timeout (seconds per call), encrypt.

## `M.mount(node, peer, exportName, mountpoint, opts)`

Mount peer's export at `mountpoint` of the local file system.

## `M.run(args, io, node)`

netfs export <name> <path> [--rw] [--peers a,b] | unexport <name> | exports | mount <peer> <export> <dir> | umount <dir> | mounts

## `M.daemon()`

The netfsd service: offer the configured exports and (re)mount saved mounts, retrying while peers are unreachable.
