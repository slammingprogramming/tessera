# tsr.pkg.source

Package: `pkg`

Package sources ("channels"). Every source exposes the same static layout:
  registry/index.json                     { format, packages = { name = {version, type, description, size, provides} } }
  registry/packages/<name>.json           { name, latest, versions = { ["1.0.0"] = manifest } }
  blobs/<sha256>                          file payloads, content-addressed (verified after download)
Source types:
  http      one or more mirror base URLs (GitHub Pages, ...)        { type="http", bases={...} }
  dir       a directory with the layout above (disk, mount, offline import store)   { type="dir", path="..." }
  pastebin  a "snapshot" paste mapping registry files to pastes     { type="pastebin", snapshot="<id>" }
  lan       a paired computer running the pkg-mirror service         { type="lan", peer="<name>" }  (package pkg-mirror)
The built-in `offline` source is a `dir` at /var/cache/tsr/offline, filled by importing a bundle. It is always
consulted first, so pasting a bundle makes an HTTP-less install possible.

## `M.list()`

Configured sources in priority order, with the offline store first when it has content.

## `M.findPackage(name, force)`

First source that knows `name`. Returns package doc, source.

## `M.update()`

Refresh the cached index of every source. Returns { [sourceName] = true | errorString }.

## `M.allPackages()`

Merged view of all indexes: name -> entry (with .source). Earlier sources win.

## `M.getBlob(sha, preferred)`

Fetch a payload by its SHA-256 from the first source that has it (offline store first). Verified.

## `M.importBundle(b)`

Store a parsed bundle (tsr.bundle) in the offline source. Returns { packages = n, blobs = n }.

## `M.clean(all)`

Delete the offline store and the metadata cache (frees space).
