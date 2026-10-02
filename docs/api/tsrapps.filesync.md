# tsrapps.filesync

Package: `filesync`

filesync: keep a folder identical on several computers over wireless/wired modems (the planned "wireless file sync").
  filesync serve <folder> [--writable] [--pair]      share a folder (read-only unless --writable)
  filesync pull <id> <folder> [--delete] [--dry-run]  make <folder> match the server's folder
  filesync push <id> <folder> [--delete] [--dry-run]  make the server's folder match <folder> (server must be --writable)
Files are compared by SHA-256 and transferred in small chunks; only changed files move. Requests are signed with a
shared passphrase (see tsrapps.secure), and the server never touches anything outside its folder.

## `M.safe(path)`

A safe relative path inside the shared folder: no leading slash, no "..", no empty parts, no NULs.

## `M.manifest(root)`

Files below `root`: array of { path (relative), size, sha256 } sorted by path. Returns nil + reason if too many.

## `M.diff(src, dst)`

What has to happen so that `dst` becomes identical to `src`? Returns { copy = {files}, remove = {paths} }.

## `M.dispatch(cfg, msg)`

Handle one authenticated request against `cfg` = { root, writable }. Returns ok, data.

## `M.serve(cfg, secret, net, io, opts)`

Serve until `stop` (tests) — one message per iteration.

## `M.sync(direction, secret, net, target, folder, opts, io)`

Make `folder` match the server (direction "pull") or the server match `folder` ("push").
Returns { copied = n, removed = n, plan = plan } or nil + error.
