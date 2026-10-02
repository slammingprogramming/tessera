# tsr.hw

Package: `core`

Hardware detection. Uses only public CC:T APIs and never assumes a peripheral exists: every call is guarded, so the
probe works on basic computers, turtles, pocket computers and command computers alike.
  local hw = require("tsr.hw").probe({ net = true })

## `M.peripherals()`

Every attached peripheral, including ones reachable through wired modems. Returns array of descriptors.

## `M.httpReach(urls)`

Test whether the given URLs can be requested (the server's HTTP rules may block hosts). Returns { url = bool }.

## `M.probe(opts)`

Full probe. opts.net = true also tests HTTP reachability of opts.urls (default: GitHub Pages, Pastebin, jsDelivr).

## `M.ofType(hw, typeName)`

All peripherals of a given type name.

## `M.hasTypeMatching(hw, pat)`

Does any peripheral report a type whose name matches the Lua pattern `pat`?
