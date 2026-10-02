# tsr.pkg.db

Package: `pkg`

Installed-package database (/var/lib/tsr/pkg/db.json): what is installed, which files each package owns, and why.
  record = { version, reason = "manual"|"auto", files = {{path, sha256, size}}, requires, provides, lazy, time }

## `M.reload()`

Drop the in-memory copy (tests, or after another process changed the file).

## `M.names()`

Sorted array of installed package names.

## `M.owner(path)`

Which package owns `path`? Returns name, fileRecord.

## `M.dependents(name)`

Installed packages that list `name` in their requires (reverse dependencies).

## `M.provider(virt)`

Installed package providing the virtual name `virt`, if any.
