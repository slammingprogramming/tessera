# tsr.pkg

Package: `pkg`

tsr.pkg: the package manager API used by the `pkg` command, the installer wizard and lazy stubs.

## `P.update()`

Refresh the cached registry indexes. Returns { [source] = true | error }.

## `P.search(query)`

Packages whose name or description contains `query` (case-insensitive). Sorted array of { name, entry, installed }.

## `P.info(name)`

Details for one package: { doc, source, latest, manifest, installed }.

## `P.list()`

Installed packages: sorted array of { name, record }.

## `P.plan(requests, opts)`

Resolve `requests` ("name" or "name@range") into an install plan. Returns plan or nil, errors.

## `P.installPackages(requests, opts)`

Install packages. opts: dry (return the plan only), upgrade, reinstall, lazy, progress, keepCache.
Returns true (or the plan when dry), or nil + message.

## `P.upgrade(names, opts)`

Upgrade everything installed (or just `names`). opts as for installPackages.

## `P.ensure(name, opts)`

Make sure a package is really installed (used by lazy stubs). Returns true or nil, err.

## `P.verify(name)`

Check installed files against the database. Returns array of { package, path, problem }.

## `P.clean(all)`

Free space: remove the staging area, offline store and (with `all`) the registry cache.

## `P.recover()`

Repair an interrupted transaction (call early at boot).

## `P.importBundle(data)`

Import an offline bundle: `data` is file content (TSRZ file or text of TSR1 lines) or an assembler from
tsr.bundle.newAssembler(). Returns { packages = n, blobs = n } or nil, err.
