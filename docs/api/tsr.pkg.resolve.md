# tsr.pkg.resolve

Package: `pkg`

Dependency resolution. Greedy with accumulated version constraints (no backtracking): each package is pinned to the
highest version satisfying every constraint seen so far, and a later constraint that contradicts that choice is
reported as a conflict rather than silently re-planned.

## `M.parseRequest(s)`

Parse "name", "name@range" into name, range.

## `M.plan(requests, ctx, opts)`

requests: array of "name" / "name@range" strings.
ctx: installed(name) -> record|nil, installedProvider(virt) -> name|nil, lookup(name) -> doc|nil,
     providers(virt) -> array of package names that can provide `virt`.
opts: upgrade (bool: move installed packages to the newest version), reinstall (bool)
Returns plan (array of { name, version, manifest, action = "install"|"upgrade"|"reinstall", reason }) or nil, errors.
