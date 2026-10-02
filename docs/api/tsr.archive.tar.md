# tsr.archive.tar

Package: `archive`

tar archives (POSIX ustar, the format every tar reads) of files and folders on this computer, with optional gzip.
  tar.create(paths, opts)    -> bytes        paths: files and folders; opts: gzip (bool), base (strip this prefix), mtime
  tar.list(bytes)            -> { { name, size, isDir, mode } }
  tar.extract(bytes, dest, opts) -> { files, dirs }      refuses absolute and ".." paths (opts.overwrite to replace existing files)
Long names use the ustar prefix field (up to 255 characters). Links, devices and extended headers of other tools are skipped.

## `M.create(paths, opts)`

Build a tar archive. Returns bytes or nil + reason.

## `M.extract(bytes, dest, opts)`

Unpack into the folder `dest`. Returns { files = n, dirs = n } or nil + reason. Unsafe names abort before anything is written.
