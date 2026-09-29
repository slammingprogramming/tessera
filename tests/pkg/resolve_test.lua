-- SPDX-License-Identifier: AGPL-3.0-or-later
local resolve = require("tsr.pkg.resolve")

local function doc(name, versions)
  local d = { name = name, latest = nil, versions = {} }
  for v, spec in pairs(versions) do
    d.versions[v] = { name = name, version = v, requires = spec.requires or {}, conflicts = spec.conflicts,
                      provides = spec.provides }
  end
  return d
end

local function ctx(available, installed)
  installed = installed or {}
  return {
    installed = function(n) return installed[n] end,
    installedProvider = function(virt)
      for n, rec in pairs(installed) do
        for _, p in ipairs(rec.provides or {}) do if p == virt then return n end end
      end
    end,
    lookup = function(n) return available[n] end,
    providers = function(virt)
      local out = {}
      for n, d in pairs(available) do
        for _, m in pairs(d.versions) do
          for _, p in ipairs(m.provides or {}) do if p == virt then out[#out + 1] = n end end
        end
      end
      table.sort(out)
      return out
    end,
  }
end

local function names(plan)
  local out = {}
  for _, e in ipairs(plan) do out[#out + 1] = e.name .. "@" .. e.version .. ":" .. e.action end
  return out
end

test("parseRequest", function()
  local n, r = resolve.parseRequest("foo")
  eq({ n, r }, { "foo", "*" })
  n, r = resolve.parseRequest("foo@>=1.2")
  eq({ n, r }, { "foo", ">=1.2" })
end)

test("dependencies come first and the best version is chosen", function()
  local avail = {
    app = doc("app", { ["1.0.0"] = { requires = { lib = "^1.0" } } }),
    lib = doc("lib", { ["1.0.0"] = {}, ["1.5.0"] = { requires = { base = "*" } }, ["2.0.0"] = {} }),
    base = doc("base", { ["0.1.0"] = {} }),
  }
  local plan = assert(resolve.plan({ "app" }, ctx(avail)))
  eq(names(plan), { "base@0.1.0:install", "lib@1.5.0:install", "app@1.0.0:install" })
  eq(plan[1].reason, "auto")
  eq(plan[3].reason, "manual")
end)

test("already satisfied packages are kept, unsatisfied ones upgraded", function()
  local avail = {
    app = doc("app", { ["1.0.0"] = { requires = { lib = ">=1.2" } } }),
    lib = doc("lib", { ["1.0.0"] = {}, ["1.5.0"] = {} }),
  }
  local plan = assert(resolve.plan({ "app" }, ctx(avail, { lib = { version = "1.0.0", reason = "manual" } })))
  eq(names(plan), { "lib@1.5.0:upgrade", "app@1.0.0:install" })
  eq(plan[1].reason, "manual", "an explicitly installed package stays manual when upgraded as a dependency")
  plan = assert(resolve.plan({ "app" }, ctx(avail, { lib = { version = "1.2.0" } })))
  eq(names(plan), { "app@1.0.0:install" })
end)

test("upgrade and reinstall options", function()
  local avail = { lib = doc("lib", { ["1.0.0"] = {}, ["1.5.0"] = {} }) }
  local inst = { lib = { version = "1.0.0" } }
  eq(names(assert(resolve.plan({ "lib" }, ctx(avail, inst)))), {})
  eq(names(assert(resolve.plan({ "lib" }, ctx(avail, inst), { upgrade = true }))), { "lib@1.5.0:upgrade" })
  eq(names(assert(resolve.plan({ "lib" }, ctx(avail, { lib = { version = "1.5.0" } }), { reinstall = true }))),
    { "lib@1.5.0:reinstall" })
end)

test("missing packages and unsatisfiable ranges are reported", function()
  local avail = { app = doc("app", { ["1.0.0"] = { requires = { ghost = "*" } } }), lib = doc("lib", { ["1.0.0"] = {} }) }
  local plan, errs = resolve.plan({ "app" }, ctx(avail))
  ok(plan == nil)
  ok(errs[1]:find("ghost") and errs[1]:find("required by app"))
  plan, errs = resolve.plan({ "lib@>=2" }, ctx(avail))
  ok(plan == nil and errs[1]:find("no available version"))
end)

test("conflicting constraints are reported", function()
  local avail = {
    a = doc("a", { ["1.0.0"] = { requires = { lib = "^1.0" } } }),
    b = doc("b", { ["1.0.0"] = { requires = { lib = "^2.0" } } }),
    lib = doc("lib", { ["1.0.0"] = {}, ["2.0.0"] = {} }),
  }
  local plan, errs = resolve.plan({ "a", "b" }, ctx(avail))
  ok(plan == nil and errs[1]:find("conflicts"))
end)

test("virtual names resolve to a provider", function()
  local avail = {
    app = doc("app", { ["1.0.0"] = { requires = { ["tsr:storage"] = "*" } } }),
    disk = doc("disk", { ["1.0.0"] = { provides = { "tsr:storage" } } }),
  }
  eq(names(assert(resolve.plan({ "app" }, ctx(avail)))), { "disk@1.0.0:install", "app@1.0.0:install" })
  eq(names(assert(resolve.plan({ "app" }, ctx(avail, { other = { version = "1", provides = { "tsr:storage" } } })))),
    { "app@1.0.0:install" })
end)

test("package conflicts and dependency cycles are detected", function()
  local avail = {
    a = doc("a", { ["1.0.0"] = { conflicts = { "b" } } }),
    b = doc("b", { ["1.0.0"] = {} }),
    x = doc("x", { ["1.0.0"] = { requires = { y = "*" } } }),
    y = doc("y", { ["1.0.0"] = { requires = { x = "*" } } }),
  }
  local plan, errs = resolve.plan({ "a" }, ctx(avail, { b = { version = "1.0.0" } }))
  ok(plan == nil and errs[1]:find("conflicts with b"))
  plan, errs = resolve.plan({ "x" }, ctx(avail))
  ok(plan == nil and errs[1]:find("cycle"))
end)
