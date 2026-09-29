-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The wizard end to end with a scripted UI, a fake hardware probe and a directory registry.
local E = dofile("/tests/lib/testenv.lua")
local wizard = require("tsr.setup.wizard")
local pkg = require("tsr.pkg")
local db = require("tsr.pkg.db")
local source = require("tsr.pkg.source")
local config = require("tsr.config")
local vfs = require("tsr.vfs")

local ROOT = E.ROOT

local function catalog(extra)
  local c = {
    ["ui-tui"] = { version = "1.0.0", size = 4000, files = { [ROOT .. "/ui-tui.lua"] = string.rep("t", 400) } },
    net = { version = "1.0.0", size = 3000, description = "networking", files = { [ROOT .. "/net.lua"] = string.rep("n", 300) } },
    audio = { version = "1.0.0", size = 2000, description = "audio", files = { [ROOT .. "/bin/audio.lua"] = "audio" } },
    display = { version = "1.0.0", size = 2000, description = "monitors", files = { [ROOT .. "/bin/display.lua"] = "display" } },
    toy = { version = "1.0.0", size = 500, description = "not recommended by anyone", files = { [ROOT .. "/toy.lua"] = "toy" } },
  }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

local function env(ui, probe)
  return {
    ui = ui, pkg = pkg, config = config, vfs = vfs,
    hw = { probe = function() return probe end, ofType = function() return {} end, hasTypeMatching = function() return false end },
    importer = { interactive = function() return nil end },
  }
end

local function advancedWithModem()
  return E.fakeProbe({ peripherals = { { type = "modem", wireless = true }, { type = "speaker" }, { type = "monitor", color = true } } })
end

local function shown(ui, kind, title)
  for _, l in ipairs(ui.log) do if l.kind == kind and l.title == title then return true end end
  return false
end

test("happy path installs the recommended modules and writes the configuration", function()
  E.reset()
  E.publish(catalog())
  local ui = E.scriptedUi({
    ["Computer name"] = "alpha one",
    ["Setup complete"] = false, -- do not reboot
  })
  local result = wizard.run(env(ui, advancedWithModem()))
  eq(result, "done")
  ok(db.get("ui-tui") and db.get("net"), "recommended modules installed")
  ok(db.get("audio") == nil and db.get("display") == nil, "optional modules for attached hardware are offered but not ticked")
  ok(fs.exists(ROOT .. "/net.lua"))
  eq(config.get("system.profile"), "client")
  eq(config.get("net.hostname"), "alpha-one")
  ok(fs.exists("/etc/tsr/setup.done"))
  eq(vfs.readJSON("/etc/tsr/setup.done").profile, "client")
  fs.delete("/etc/tsr/setup.done")
end)

test("optional modules stay unticked unless chosen", function()
  E.reset()
  E.publish(catalog())
  local ui = E.scriptedUi({ ["Setup complete"] = false })
  wizard.run(env(ui, advancedWithModem()))
  ok(db.get("net"), "recommended (modem) is installed")
  ok(db.get("audio") == nil, "optional (speaker) is not installed by default")
  ok(db.get("toy") == nil)
  fs.delete("/etc/tsr/setup.done")
end)

test("the user can tick extra modules and untick recommended ones", function()
  E.reset()
  E.publish(catalog())
  local ui = E.scriptedUi({
    ["Choose modules"] = function(items, opts, checks)
      checks.audio, checks.toy, checks.net = true, true, false
      return checks
    end,
    ["Setup complete"] = false,
  })
  wizard.run(env(ui, advancedWithModem()))
  ok(db.get("audio") and db.get("toy"))
  ok(db.get("net") == nil, "unticked recommendation must not be installed")
  fs.delete("/etc/tsr/setup.done")
end)

test("the profile menu disables impossible choices and follows the selection", function()
  E.reset()
  E.publish(catalog())
  local seenItems
  local ui = E.scriptedUi({
    ["What is this computer for?"] = function(items, opts)
      seenItems = items
      for i, it in ipairs(items) do if it.label:find("Server") then return i end end
    end,
    ["Setup complete"] = false,
  })
  wizard.run(env(ui, advancedWithModem()))
  eq(config.get("system.profile"), "server")
  local disabled = 0
  for _, it in ipairs(seenItems) do if it.disabled then disabled = disabled + 1 end end
  ok(disabled >= 3, "turtle/pocket/command should be disabled on a normal computer")
  fs.delete("/etc/tsr/setup.done")
end)

test("not enough space offers lazy installs for optional modules", function()
  E.reset()
  E.publish(catalog())
  -- pretend the disk is tiny: the declared sizes (9000 B + margin) do not fit in 9000 B free, but the recommended
  -- modules alone (700 B of files + 8192 B margin) do
  local util = require("tsr.util")
  local realFree = util.freeSpace
  util.freeSpace = function() return 9000 end
  local menuShown = false
  local ui = E.scriptedUi({
    ["Choose modules"] = function(items, opts, checks) checks.audio = true checks.net = true return checks end,
    ["Not enough disk space"] = function() menuShown = true return 2 end,
    ["Install failed"] = 2, -- give up rather than retry forever
    ["Setup complete"] = false,
  })
  local ok2, err = pcall(wizard.run, env(ui, advancedWithModem()))
  util.freeSpace = realFree
  ok(ok2, tostring(err))
  ok(menuShown, "space warning menu should appear")
  ok(db.get("net") and not db.get("net").lazy, "recommended modules are installed for real")
  ok(db.get("audio") and db.get("audio").lazy, "optional module should be lazy")
  ok(not shown(ui, "menu", "Install failed"), "the install itself must not fail")
  fs.delete("/etc/tsr/setup.done")
end)

test("cancelling at the welcome screen changes nothing", function()
  E.reset()
  E.publish(catalog())
  local ui = E.scriptedUi({ ["Tessera setup"] = false })
  eq(wizard.run(env(ui, advancedWithModem())), "quit")
  eq(db.names(), {})
  ok(not shown(ui, "menu", "What is this computer for?"))
end)

test("offline: with no registry the wizard walks through an import and then installs from it", function()
  E.reset(false)
  local bundle = E.build(catalog())
  local imported = 0
  local ui = E.scriptedUi({ ["Setup complete"] = false })
  local e = env(ui, advancedWithModem())
  e.importer = { interactive = function() imported = imported + 1 return bundle end }
  eq(wizard.run(e), "done")
  eq(imported, 1)
  ok(db.get("net") and db.get("ui-tui"), "installed from the imported bundle")
  ok(not fs.exists(source.offlineDir), "offline store is cleaned up after setup")
  ok(shown(ui, "confirm", "No package registry"))
  fs.delete("/etc/tsr/setup.done")
end)

test("offline: declining to import ends the wizard", function()
  E.reset(false)
  local ui = E.scriptedUi({ ["No package registry"] = false })
  eq(wizard.run(env(ui, advancedWithModem())), "quit")
end)

test("re-running shows installed modules ticked and unticking removes them", function()
  E.reset()
  E.publish(catalog())
  ok(pkg.installPackages({ "net", "audio" }))
  local ticked
  local ui = E.scriptedUi({
    ["Choose modules"] = function(items, opts, checks)
      ticked = { net = checks.net, audio = checks.audio }
      checks.audio = false
      return checks
    end,
    ["Setup complete"] = false,
  })
  wizard.run(env(ui, advancedWithModem()))
  eq(ticked, { net = true, audio = true })
  ok(db.get("net") ~= nil)
  ok(db.get("audio") == nil, "unticked installed module is removed")
  fs.delete("/etc/tsr/setup.done")
end)

test("summary lines describe the hardware", function()
  local lines = wizard.summary(advancedWithModem())
  local text = table.concat(lines, "\n")
  ok(text:find("advanced computer") and text:find("colour") and text:find("wireless modem")
     and text:find("monitor") and text:find("speaker"), text)
  local basic = table.concat(wizard.summary(E.fakeProbe({ advanced = false, http = false })), "\n")
  ok(basic:find("basic computer") and basic:find("HTTP is disabled"), basic)
end)
