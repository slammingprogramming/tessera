# tsr.vfs

Package: `core`

Virtual file system layer:
  * path helpers
  * crash-safe ("atomic") file writes + recovery of interrupted writes (computers can be chunk-unloaded mid-write)
  * a mount table, so parts of the tree can be served by providers (RAM disks, remote FS, /dev ...). Calling
    vfs.install() patches the global `fs` API in place so EVERY program, including stock CraftOS ones, sees mounts.

## `M.normalize(path)`

Normalise to an absolute path without "." / ".." / duplicate slashes ("/" for the root).

## `M.mount(prefix, provider)`

Mount `provider` at `prefix`. Provider interface (paths are absolute inside the provider, "/" = its root):
  exists(p) isDir(p) list(p)->names size(p) open(p, mode)->handle|nil,err makeDir(p) delete(p)
  optional: move(a,b) isReadOnly(p) getFreeSpace() getCapacity()

## `M.install()`

Patch the global fs table so all code sees mounts. Idempotent. Only function names in R are replaced.

## `M.writeFile(path, data, binary)`

Crash-safe write. Sequence: write path.tsr-tmp -> rename to path.tsr-new (marks "complete") -> move the old file
to path.tsr-old -> rename new to path -> delete old. M.recover() finishes or rolls back an interrupted sequence.

## `M.recover(dir, depth)`

Repair interrupted atomic writes under `dir` (default "/"). Returns the number of repairs made.

## `M.ramfs(capacity)`

A volatile in-memory provider, e.g. vfs.mount("/tmp", vfs.ramfs(64 * 1024)).
