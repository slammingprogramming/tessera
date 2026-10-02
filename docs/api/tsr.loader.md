# tsr.loader

Package: `core`

Shared module loader. All Tessera code (kernel, services, apps) shares ONE module cache so singletons such as the
kernel, config and log really are singletons across processes. CraftOS' own `require` gives every program a private
cache, which is why processes started by the kernel get this loader's `require` instead.

## `M.search(name)`

Find the file that provides module `name`. Returns path or nil, tried-paths.

## `M.unload(name)`

Forget a module so the next require() reloads it (used by tests and package upgrades).

## `M.preload(name, value)`

Register an already-built module under `name` (e.g. the loader itself).
