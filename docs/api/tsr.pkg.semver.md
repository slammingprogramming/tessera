# tsr.pkg.semver

Package: `pkg`

Minimal semantic versions: "MAJOR.MINOR.PATCH" (missing parts are 0; a "-suffix" is ignored).
Ranges: "*", exact "1.2.3", ">=1.2", ">1", "<=2", "<2", "=1.2.3", "^1.2.3", "~1.2.3", and space/comma-joined
combinations meaning AND, e.g. ">=1.2 <2".

## `M.satisfies(version, range)`

true when `version` satisfies `range`.

## `M.best(versions, range)`

Highest version in `versions` (array of strings) satisfying `range`, or nil.
