# tsr.roles

Package: `roles`

Roles: named bundles of packages, services and settings. A role file in /etc/tsr/roles.d/<name>.lua looks like
  return {
    description = "what this computer becomes",
    packages = { "net", "ops" },        -- installed when missing
    services = { "netd", "metricsd" },  -- enabled (start at boot) and started
    config = { ["net.hostname"] = "hub" },   -- optional settings written to the system layer
    notes = "what to do next",
  }
Any package can ship role files; `role apply <name>` does the work, `role remove <name>` turns the services off again
(installed packages stay).

## `M.load()`

All defined roles: name -> definition. Returns the map and a list of problems.

## `M.plan(name)`

What `apply` would do. Returns { role, missing = {packages}, services = {...}, config = {...} } or nil + error.

## `M.apply(name, opts)`

Apply a role. opts: install (default true; false = never touch packages), start (default true).
Returns a result { installed = {...}, enabled = {...}, started = {...}, problems = {...}, notes = "" } or nil + error.

## `M.remove(name)`

Stop and disable the role's services (packages stay installed).

## `M.run(args, io)`

role list | show <name> | apply <name> | remove <name>
