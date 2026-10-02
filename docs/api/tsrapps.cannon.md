# tsrapps.cannon

Package: `cannon`

cannon: control a redstone-fired TNT cannon (a technical Minecraft build): a dispenser/loader is pulsed to charge
the barrel, then an igniter fires it. The controller only sequences redstone outputs; you build the cannon.
  cannon setup                     ports, volley size, timings and the arming code
  cannon status | arm | disarm
  cannon fire [volleys] [--dry-run]     needs the cannon to be armed; auto-disarms afterwards
Safety: firing needs the arming code (checked as a salted hash, never stored in clear), armed status expires after
60 s, and volleys are capped and spaced by a cooldown. --dry-run prints the sequence without touching redstone.

## `M.hashCode(code, salt)`

Salted, iterated SHA-256 of the arming code.

## `M.sequence(cfg, volleys)`

The redseq step list for `volleys` volleys with the given config.

## `M.validate(cfg, env)`

Validate a config table. Returns true or false + reason.

## `M.fire(cfg, volleys, env, opts)`

Fire. Returns true or false + reason. opts.dryRun returns the steps without running them.
