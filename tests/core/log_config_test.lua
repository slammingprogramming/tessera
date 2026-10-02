-- SPDX-License-Identifier: AGPL-3.0-or-later
local log = require("tsr.log")
local config = require("tsr.config")

test("log levels filter and ring buffer records", function()
  log.clear()
  log.setLevel("warn")
  local l = log.get("t")
  l.info("hidden")
  l.warn("shown %d", 7)
  local lines = log.tail()
  eq(#lines, 1)
  ok(lines[1]:find("shown 7", 1, true))
  ok(lines[1]:find("[WARN]", 1, true))
  log.setLevel("info")
end)

test("log writes and rotates the file sink", function()
  log.setFile("/tmp-log/tsr.log", 300)
  log.setLevel("info")
  local l = log.get("rot")
  for i = 1, 30 do l.info("line number %d with some padding text", i) end
  ok(fs.exists("/tmp-log/tsr.log"))
  ok(fs.exists("/tmp-log/tsr.log.1"), "expected rotation")
  ok(fs.getSize("/tmp-log/tsr.log") <= 600)
  log.setFile(nil)
  fs.delete("/tmp-log")
end)

test("log survives a format error", function()
  log.clear()
  log.get("f").info("%d", "not a number")
  eq(#log.tail(), 1)
end)

test("config get/set with dotted keys and layers", function()
  config.reset()
  config.setDefaults({ net = { hostname = "unnamed", port = 1 } })
  eq(config.get("net.hostname"), "unnamed")
  config.set("net.hostname", "alpha", "system")
  eq(config.get("net.hostname"), "alpha")
  config.set("net.hostname", "beta", "user")
  eq(config.get("net.hostname"), "beta")
  eq(config.get("net.port"), 1)
  eq(config.get("missing.key", "dflt"), "dflt")
  config.set("net.hostname", nil, "user")
  eq(config.get("net.hostname"), "alpha")
end)

test("config merges tables across layers", function()
  config.reset()
  config.setDefaults({ ui = { theme = { fg = 1, bg = 2 } } })
  config.set("ui.theme.fg", 9, "system")
  eq(config.get("ui.theme"), { fg = 9, bg = 2 })
end)

test("config persists system layer and reloads it", function()
  config.reset()
  local old = config.paths.system
  config.paths.system = "/tmp-cfg/system.cfg"
  config.set("a.b", 42, "system")
  ok(config.save("system"))
  config.reset()
  eq(config.get("a.b"), nil)
  ok(config.load("system"))
  eq(config.get("a.b"), 42)
  config.paths.system = old
  fs.delete("/tmp-cfg")
end)

test("config watchers fire by prefix and can be removed", function()
  config.reset()
  local seen = {}
  local off = config.watch("net.", function(k, v) seen[#seen + 1] = k .. "=" .. tostring(v) end)
  config.set("net.x", 1)
  config.set("other.y", 2)
  off()
  config.set("net.z", 3)
  eq(seen, { "net.x=1" })
end)

test("config.get returns copies", function()
  config.reset()
  config.set("t", { a = 1 })
  local t = config.get("t")
  t.a = 99
  eq(config.get("t.a"), 1)
end)

test("a damaged configuration file is ignored, reported and copied aside before anything can overwrite it", function()
  local config = require("tsr.config")
  local dir = "/tmp-cfg-damaged"
  if fs.exists(dir) then fs.delete(dir) end
  fs.makeDir(dir)
  config.reset()
  config.problems = {}
  local h = fs.open(dir .. "/system.cfg", "w") h.write("this is { not lua (((") h.close()
  local original = config.paths.system
  config.paths.system = dir .. "/system.cfg"
  ok(not config.load("system"))
  config.paths.system = original
  eq(#config.problems, 1)
  eq(config.problems[1].copy, dir .. "/system.cfg.damaged")
  local c = fs.open(dir .. "/system.cfg.damaged", "r")
  eq(c.readAll(), "this is { not lua (((")
  c.close()
  config.problems = {}
  fs.delete(dir)
end)
