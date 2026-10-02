# tsr.config

Package: `core`

Layered configuration store with dotted keys.
  config.get("net.hostname", "unnamed")     config.set("log.level", "debug")     config.watch("net.", fn)
Layers, lowest to highest priority: defaults (code) < profile < system < user (runtime). Only the `system` and
`profile` layers are persisted (under /etc/tsr/), via crash-safe writes.

## `M.get(key, default)`

Effective value: highest layer that defines the key. Tables from several layers are merged.

## `M.set(key, value, layer)`

Set `key` in `layer` (default "system"). Use value=nil to unset. Persist with M.save().

## `M.watch(prefix, fn)`

Call fn(key, newValue) whenever a key starting with `prefix` is set. Returns an unwatch function.

## `M.reset()`

For tests / recovery: forget everything in memory.

## `M.dump()`

Whole effective config as one table (defaults merged with all layers).
