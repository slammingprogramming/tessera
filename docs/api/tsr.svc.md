# tsr.svc

Package: `svc-manager`

Service manager. A service is a background program described by a definition file in /etc/tsr/services.d/<name>.lua:

  return {
    description = "what it does",
    path = "/usr/bin/foo.lua"   -- a program to run, or:  module = "tsrapps.foo" (its main(args) is called; entry = "name" picks
                                another function), or: run = function() end
    args = { "--daemon" },
    autostart = true,          -- started at boot (can be overridden with `svc enable|disable`)
    restart = "on-failure",    -- "never" | "on-failure" (default) | "always"
    requires = { "net" },      -- other services started first
    profiles = { "server" },   -- only autostart on these profiles
    max_restarts = 5,          -- more than this many starts inside `window` seconds marks the service failed
    window = 60,
  }

Packages install definitions; the supervisor (the `svc-manager` init.d daemon, M.supervise) restarts services that die.
Control functions (start, stop, ...) can be called from any process: they share this module's state.

## `M.define(def)`

Register a definition programmatically (tests, packages that build services at runtime).

## `M.load()`

Read every definition file. Returns the number loaded, plus a list of problems.

## `M.enabled(name)`

Is the service started at boot? An explicit enable/disable wins over the definition's `autostart`.

## `M.autostart()`

Start everything that is enabled (and allowed on this profile). Returns the names started.

## `M.onExit(pid, ok, err)`

Handle the exit of process `pid`. Returns the service name when it was one of ours.

## `M.onTimer(id)`

A timer fired: restart the service it was waiting for.

## `M.stopAll()`

Stop every running service (used at shutdown).

## `M.supervise()`

The supervisor loop (runs as the svc-manager daemon).
