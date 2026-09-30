-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local disks = require("tsrapps.disks")

local function setup()
  fs.delete("/tmp-dsk")
  fs.makeDir("/tmp-dsk/one")
  local labels = { right = "Backups" }
  local d
  d = {
    present = { right = true, left = false },
    isPresent = function(s) return d.present[s] == true end,
    getMountPath = function(s) return d.present[s] and "/tmp-dsk/one" or nil end,
    getLabel = function(s) return labels[s] end,
    setLabel = function(s, t) labels[s] = t end,
    getID = function() return 42 end,
    hasAudio = function() return false end,
    eject = function(s) d.present[s] = false d.ejected = s end,
  }
  local env = { disk = d, peripheral = F.peripheralApi({ right = { _type = "drive" }, left = { _type = "drive" }, top = { _type = "monitor" } }) }
  return env, d, labels
end

local function put(path, text)
  local h = fs.open(path, "w") h.write(text) h.close()
end

test("drives are listed and described", function()
  local env, d = setup()
  eq(disks.drives(env), { "left", "right" })
  ok(disks.describe("left", env):find("empty"))
  local text = disks.describe("right", env)
  ok(text:find('"Backups"') and text:find("id 42"), text)
  d.hasAudio = function() return true end
  d.getAudioTitle = function() return "Song" end
  ok(disks.describe("right", env):find("music disc"))
  fs.delete("/tmp-dsk")
end)

test("main lists drives and reports none", function()
  local env = setup()
  local io = F.io()
  ok(disks.main({}, io, env))
  eq(#io.said, 2)
  local none = F.io()
  ok(disks.main({}, none, { disk = env.disk, peripheral = F.peripheralApi({}) }))
  ok(none.said[1]:find("No disk drives"))
  fs.delete("/tmp-dsk")
end)

test("info shows files and sizes", function()
  local env = setup()
  put("/tmp-dsk/one/a.txt", "hello")
  fs.makeDir("/tmp-dsk/one/sub")
  put("/tmp-dsk/one/sub/b.txt", "1234567")
  local io = F.io()
  ok(disks.main({ "info", "right" }, io, env))
  local text = table.concat(io.said, "\n")
  ok(text:find("a.txt") and text:find("(5 B)", 1, true) and text:find("sub/", 1, true) and text:find("b.txt") and text:find("12 bytes used"), text)
  eq(disks.main({ "info", "left" }, F.io(), env), false)
  fs.delete("/tmp-dsk")
end)

test("label sets and clears", function()
  local env, _, labels = setup()
  ok(disks.main({ "label", "right", "My", "Disk" }, F.io(), env))
  eq(labels.right, "My Disk")
  ok(disks.main({ "label", "right" }, F.io(), env))
  eq(labels.right, nil)
  eq(disks.main({ "label", "left", "x" }, F.io(), env), false)
  fs.delete("/tmp-dsk")
end)

test("copy works between a path and a disk side, and refuses to overwrite", function()
  local env = setup()
  put("/tmp-dsk/src.txt", "data")
  ok(disks.main({ "copy", "/tmp-dsk/src.txt", "right" }, F.io(), env))
  ok(fs.exists("/tmp-dsk/one/src.txt"))
  local io = F.io()
  eq(disks.main({ "copy", "/tmp-dsk/src.txt", "right" }, io, env), false)
  ok(io.errs[1]:find("already exists"))
  ok(disks.main({ "copy", "right", "/tmp-dsk/backup" }, F.io(), env))
  ok(fs.exists("/tmp-dsk/backup/src.txt"))
  eq(disks.main({ "copy", "/tmp-dsk/missing", "right" }, F.io(), env), false)
  eq(disks.main({ "copy", "only-one" }, F.io(), env), false)
  fs.delete("/tmp-dsk")
end)

test("wipe asks first and empties the disk", function()
  local env = setup()
  put("/tmp-dsk/one/a.txt", "x")
  fs.makeDir("/tmp-dsk/one/d")
  eq(disks.main({ "wipe", "right" }, F.io(nil, { false }), env), false)
  ok(fs.exists("/tmp-dsk/one/a.txt"), "declined: nothing deleted")
  ok(disks.main({ "wipe", "right", "-y" }, F.io(), env))
  eq(#fs.list("/tmp-dsk/one"), 0)
  ok(fs.exists("/tmp-dsk/one"), "the mount itself stays")
  fs.delete("/tmp-dsk")
end)

test("startup makes the disk autorun a program", function()
  local env = setup()
  put("/tmp-dsk/one/tool.lua", "print('hi')")
  ok(disks.main({ "startup", "right", "tool.lua" }, F.io(), env))
  local h = fs.open("/tmp-dsk/one/startup.lua", "r")
  local text = h.readAll() h.close()
  ok(text:find("tool.lua", 1, true) and text:find("shell.run", 1, true))
  eq(disks.main({ "startup", "right", "missing.lua" }, F.io(), env), false)
  fs.delete("/tmp-dsk")
end)

test("eject and unknown commands", function()
  local env, d = setup()
  ok(disks.main({ "eject", "right" }, F.io(), env))
  eq(d.ejected, "right")
  eq(disks.main({ "eject", "right" }, F.io(), env), false)
  eq(disks.main({ "frobnicate" }, F.io(), env), false)
  fs.delete("/tmp-dsk")
end)
