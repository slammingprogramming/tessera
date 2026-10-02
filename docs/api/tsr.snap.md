# tsr.snap

Package: `safety`

Snapshots: remember what a folder looked like, compare later, restore. File contents are stored once by SHA-256 in
/var/snapshots/blobs, so many snapshots of mostly unchanged files cost little. A snapshot is a manifest
/var/snapshots/<name>.json listing every file with its checksum.
  snap create <name> [folder]       snap list       snap diff <name> [other]       snap restore <name> [folder] [--prune]
  snap delete <name>                snap export <name> <dir>   snap import <dir> <name>

## `M.create(name, root, opts)`

Take a snapshot of `root` (default /etc/tsr). opts.progress(path) is called per file, opts.sleep yields between files.
Returns { files = n, bytes = n, new = n (blobs that were not stored yet) } or nil + reason.

## `M.list()`

All snapshots, oldest first: { name, root, created, files }.

## `M.diff(name, other)`

Differences from snapshot `name` to `other` (another snapshot's name) or to the live folder (default).
Returns { added = {...}, removed = {...}, changed = {...} } (relative paths, sorted) or nil + reason.

## `M.restore(name, root, opts)`

Put snapshot `name` back into `root` (default: where it was taken). Missing blobs are reported. opts.prune deletes files
that were not in the snapshot; opts.only restricts to relative paths in that list. Returns { restored = n, pruned = n } or nil + reason.

## `M.gc()`

Remove blobs that no snapshot refers to. Returns how many were deleted.

## `M.export(name, dir)`

Copy a snapshot (manifest and its blobs) to `dir`, for example a floppy disk. Returns the number of files written.

## `M.import(dir, name, as)`

Bring a snapshot in from `dir` under `name`. Returns the number of blobs copied.
