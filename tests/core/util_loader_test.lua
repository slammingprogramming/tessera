-- SPDX-License-Identifier: AGPL-3.0-or-later
local util = require("tsr.util")

test("util.split / trim / startswith / endswith", function()
  eq(util.split("a,b,,c", ","), { "a", "b", "", "c" })
  eq(util.split("abc", ","), { "abc" })
  eq(util.split("a.b.c", ".", 2), { "a", "b.c" })
  eq(util.trim("  hi there \n"), "hi there")
  ok(util.startswith("tessera", "tess"))
  ok(not util.startswith("tessera", "era"))
  ok(util.endswith("tessera", "era"))
  ok(util.endswith("x", ""))
end)

test("util.merge deep-merges and copies", function()
  local a = { x = { y = 1, z = 2 }, k = 1 }
  local b = { x = { y = 9 }, n = { m = 1 } }
  util.merge(a, b)
  eq(a, { x = { y = 9, z = 2 }, k = 1, n = { m = 1 } })
  b.n.m = 5
  eq(a.n.m, 1, "merge must copy, not alias")
end)

test("util.deepcopy handles cycles", function()
  local t = { a = 1 }
  t.self = t
  local c = util.deepcopy(t)
  ok(c ~= t and c.self == c and c.a == 1)
end)

test("util.fmtBytes", function()
  eq(util.fmtBytes(512), "512 B")
  eq(util.fmtBytes(2048), "2.0 KB")
end)

test("loader shares one module instance", function()
  local a = require("tsr.log")
  local b = loader.require("tsr.log")
  ok(a == b)
end)

test("loader reports missing modules with the paths it tried", function()
  local err = throws(function() require("tsr.does_not_exist") end, "not found")
  ok(tostring(err):find("/sys/lib/tsr/does_not_exist.lua", 1, true))
end)

test("loader can load CC standard modules from /rom", function()
  local expect = require("cc.expect")
  ok(type(expect.expect) == "function")
end)

test("loader keeps module global writes out of _G", function()
  local dir = "/tmp-loader"
  fs.makeDir(dir)
  local h = fs.open(dir .. "/leaky.lua", "w")
  h.write("leaked_global = 1\nreturn { ok = true }")
  h.close()
  loader.path[#loader.path + 1] = dir .. "/?.lua"
  local m = require("leaky")
  ok(m.ok)
  ok(rawget(_G, "leaked_global") == nil, "module leaked a global")
  loader.path[#loader.path] = nil
  loader.unload("leaky")
  fs.delete(dir)
end)

test("loader detects require loops", function()
  local dir = "/tmp-loader2"
  fs.makeDir(dir)
  local h = fs.open(dir .. "/loop_a.lua", "w")
  h.write("return require('loop_a')")
  h.close()
  loader.path[#loader.path + 1] = dir .. "/?.lua"
  throws(function() require("loop_a") end, "loop")
  loader.path[#loader.path] = nil
  loader.loading.loop_a = nil
  fs.delete(dir)
end)
