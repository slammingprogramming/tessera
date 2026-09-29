-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Shared helpers for tests that need a package registry, an isolated package database or a scripted UI.
-- Usage:  local env = dofile("/tests/lib/testenv.lua")
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local pkg = require("tsr.pkg")
local db = require("tsr.pkg.db")
local source = require("tsr.pkg.source")
local install = require("tsr.pkg.install")
local config = require("tsr.config")

local E = {}

E.REG = "/tmp-reg"
E.ROOT = "/tmp-pkgtest"

--- Point the package manager at throw-away state directories and (optionally) a dir-type registry.
function E.reset(useRegistry)
  for _, p in ipairs({ E.REG, E.ROOT, "/tmp-state" }) do
    if fs.exists(p) then fs.delete(p) end
  end
  db.path = "/tmp-state/db.json"
  db.reload()
  install.stageDir = "/tmp-state/stage"
  install.journalPath = "/tmp-state/txn.json"
  install.backupDir = "/tmp-state/backup"
  source.cacheDir = "/tmp-state/cache"
  source.offlineDir = "/tmp-state/cache/offline"
  config.reset()
  config.paths.system = "/tmp-state/system.cfg"
  config.paths.profile = "/tmp-state/profile.cfg"
  if useRegistry ~= false then
    config.set("pkg.sources", { { name = "test", type = "dir", path = E.REG } }, "user")
  else
    config.set("pkg.sources", {}, "user")
  end
end

--- Build package docs/blobs in memory. pkgs: { name = { version, requires, provides, description, size, files = {[path]=content} } }
--- Returns { index, packages = {name = doc}, blobs = {sha = data} } (the shape tsr.bundle produces).
function E.build(pkgs)
  local out = { index = { format = 1, packages = {} }, packages = {}, blobs = {} }
  for name, s in pairs(pkgs) do
    local files = {}
    local total = 0
    for path, content in pairs(s.files or {}) do
      local sha = hash.sha256(content)
      out.blobs[sha] = content
      files[#files + 1] = { path = path, sha256 = sha, size = #content }
      total = total + #content
    end
    table.sort(files, function(a, b) return a.path < b.path end)
    local manifest = {
      format = 1, name = name, version = s.version or "1.0.0", type = s.type or "lib",
      description = s.description or (name .. " package"), requires = s.requires or {}, provides = s.provides or {},
      conflicts = {}, license = "AGPL-3.0-or-later", files = files, size = { installed = s.size or total },
    }
    out.packages[name] = { name = name, latest = manifest.version, versions = { [manifest.version] = manifest } }
    out.index.packages[name] = { version = manifest.version, type = manifest.type, description = manifest.description,
                                 size = manifest.size.installed, provides = manifest.provides }
  end
  return out
end

--- Write a built registry to disk in the site layout (E.REG).
function E.publish(pkgs)
  local b = E.build(pkgs)
  vfs.writeJSON(E.REG .. "/registry/index.json", b.index)
  for name, doc in pairs(b.packages) do vfs.writeJSON(E.REG .. "/registry/packages/" .. name .. ".json", doc) end
  for sha, data in pairs(b.blobs) do vfs.writeFile(E.REG .. "/blobs/" .. sha, data, true) end
  return b
end

--- A fake hardware probe (same shape as tsr.hw.probe). spec: kind, advanced, http, peripherals = {{type, wireless, color}}
function E.fakeProbe(spec)
  spec = spec or {}
  local ps = {}
  for i, p in ipairs(spec.peripherals or {}) do
    ps[i] = { name = p.name or (p.type .. i), types = { p.type }, isType = { [p.type] = true },
              wireless = p.wireless, color = p.color }
  end
  local function n(pred) local c = 0 for _, p in ipairs(ps) do if pred(p) then c = c + 1 end end return c end
  local counts = {
    monitors = n(function(p) return p.isType.monitor end),
    advancedMonitors = n(function(p) return p.isType.monitor and p.color end),
    speakers = n(function(p) return p.isType.speaker end),
    wirelessModems = n(function(p) return p.isType.modem and p.wireless end),
    wiredModems = n(function(p) return p.isType.modem and not p.wireless end),
    drives = n(function(p) return p.isType.drive end),
    printers = n(function(p) return p.isType.printer end),
    redstoneRelays = n(function(p) return p.isType.redstone_relay end),
    inventories = n(function(p) return p.isType.inventory end),
    energy = n(function(p) return p.isType.energy_storage end),
    fluid = n(function(p) return p.isType.fluid_storage end),
  }
  return {
    computer = { id = 7, kind = spec.kind or "computer", advanced = spec.advanced ~= false },
    screen = { width = 51, height = 19, color = spec.advanced ~= false, mouse = spec.advanced ~= false },
    http = { enabled = spec.http ~= false, reach = {} },
    storage = { free = spec.free or 900000, capacity = 1000000 },
    peripherals = ps, counts = counts,
    hasModem = counts.wirelessModems + counts.wiredModems > 0,
  }
end

--- A scripted stand-in for tsr.ui.tui. `script[title]` may be a value or fn(items|lines, opts) -> result.
--- Unscripted screens use sensible defaults. `ui.log` records every screen shown as { kind, title }.
function E.scriptedUi(script)
  local ui = { log = {}, script = script or {} }
  local function answer(kind, title, default, ...)
    ui.log[#ui.log + 1] = { kind = kind, title = title }
    local s = ui.script[title]
    if type(s) == "function" then return s(...) end
    if s ~= nil then return s end
    return default
  end
  function ui.frame() end
  function ui.status() end
  function ui.bar() end
  function ui.message(title, lines) return answer("message", title, nil, lines) end
  function ui.confirm(title, lines, opts) return answer("confirm", title, (opts or {}).default ~= false, lines, opts) end
  function ui.menu(title, items, opts) return answer("menu", title, (opts or {}).initial or 1, items, opts) end
  function ui.checklist(title, items, opts)
    local checks = {}
    for _, it in ipairs(items) do checks[it.id] = ((opts or {}).checked or {})[it.id] and true or false end
    local s = ui.script[title]
    ui.log[#ui.log + 1] = { kind = "checklist", title = title, items = items }
    if type(s) == "function" then return s(items, opts, checks) end
    return checks
  end
  function ui.input(title, prompt, default) return answer("input", title, default, prompt) end
  return ui
end

return E
