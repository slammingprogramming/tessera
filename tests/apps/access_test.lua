-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local access = require("tsrapps.access")
local keypad = require("tsrapps.keypad")

local SECRET = "0123456789abcdef0123456789abcdef"

local function setup()
  fs.delete("/tmp-acc")
  fs.makeDir("/tmp-acc/disk1")
  access.CONFIG, access.LOG = "/tmp-acc/access.cfg", "/tmp-acc/access.log"
  keypad.CONFIG = "/tmp-acc/keypad.cfg"
  local r = F.redstone()
  local clock = F.clock()
  local labels = {}
  local dsk
  dsk = {
    present = { right = true },
    isPresent = function(side) return dsk.present[side] == true end,
    getMountPath = function(side) return dsk.present[side] and "/tmp-acc/disk1" or nil end,
    setLabel = function(side, l) labels[side] = l end,
    eject = function(side) dsk.ejected = (dsk.ejected or 0) + 1 end,
  }
  local time = { t = 1000 }
  local env = { redstone = r, sleep = clock.sleep, disk = dsk, now = function() return time.t end,
                stamp = function() return "T" end, driveSide = "right", peripheral = F.peripheralApi({}) }
  return env, r, clock, dsk, labels, time
end

local function cfg()
  local c = { secret = SECRET, output = "top", open_secs = 3, min_level = 1, invert = false, mode = "pulse", revoked = {} }
  return c
end

local function cleanup() fs.delete("/tmp-acc") end

test("cards verify: genuine, forged, edited, revoked, low level", function()
  local c = cfg()
  local card = access.makeCard(SECRET, "Alex", 2, { now = function() return 5 end })
  ok(access.verify(c, card))
  local forged = access.makeCard("another secret", "Mallory", 9)
  local good, why = access.verify(c, forged)
  ok(not good and why:find("forged"))
  local edited = {}
  for k, v in pairs(card) do edited[k] = v end
  edited.level = 9
  good, why = access.verify(c, edited)
  ok(not good and why:find("forged"))
  c.revoked[card.id] = true
  good, why = access.verify(c, card)
  ok(not good and why:find("revoked"))
  c.revoked = {}
  c.min_level = 3
  good, why = access.verify(c, card)
  ok(not good and why:find("below"))
  good, why = access.verify(c, nil)
  ok(not good and why:find("not a Tessera card"))
  good = access.verify(c, { v = 1 })
  eq(good, false)
end)

test("a valid card opens the door for the configured time and is logged", function()
  local env, r, clock = setup()
  local c = cfg()
  access.writeCard("/tmp-acc/disk1", access.makeCard(SECRET, "Alex", 1, env))
  local opened, card = access.handleCard(c, "right", env)
  ok(opened, tostring(card))
  eq(clock.sleeps, { 3 })
  eq(r.log, { "top:analog=15", "top:analog=0" })
  local h = fs.open("/tmp-acc/access.log", "r")
  local text = h.readAll() h.close()
  ok(text:find("OPENED Alex level 1", 1, true))
  cleanup()
end)

test("denied cards leave the door shut and are logged", function()
  local env, r = setup()
  local c = cfg()
  access.writeCard("/tmp-acc/disk1", access.makeCard("wrong secret", "Mallory", 5, env))
  local opened, why = access.handleCard(c, "right", env)
  ok(not opened and why:find("forged"))
  eq(#r.log, 0)
  local h = fs.open("/tmp-acc/access.log", "r")
  local text = h.readAll() h.close()
  ok(text:find("DENIED Mallory", 1, true))
  fs.delete("/tmp-acc/disk1/.tsrcard")
  opened, why = access.handleCard(c, "right", env)
  ok(not opened and why:find("not a Tessera card"))
  env.disk.present.right = nil
  opened, why = access.handleCard(c, "right", env)
  ok(not opened and why == "no disk")
  cleanup()
end)

test("piston doors: inverted output closes on power; toggle mode flips", function()
  local env, r = setup()
  local c = cfg()
  c.invert = true
  r.out.top = 15 -- powered = closed
  access.operate(c, env)
  eq(r.log, { "top:analog=0", "top:analog=15" }, "power is dropped to open, then restored")
  local env2, r2 = setup()
  local t = cfg()
  t.mode = "toggle"
  access.operate(t, env2)
  eq(r2.out.top, 15)
  access.operate(t, env2)
  eq(r2.out.top, 0)
  cleanup()
end)

test("the door output is restored even when the wait is interrupted", function()
  local env, r = setup()
  env.sleep = function() error("terminated") end
  throws(function() access.operate(cfg(), env) end, "terminated")
  eq(r.out.top, 0)
  cleanup()
end)

test("run loop handles cards until stopped and ejects them", function()
  local env, r, _, dsk = setup()
  local c = cfg()
  access.writeCard("/tmp-acc/disk1", access.makeCard(SECRET, "Sam", 1, env))
  local n = 0
  env.pullEvent = function() n = n + 1 return "disk", "right" end
  env.maxCards = 3
  local io = F.io()
  eq(access.run(c, io, env), 3)
  eq(dsk.ejected, 3)
  ok(io.said[2]:find("Welcome, Sam"))
  cleanup()
end)

test("setup, issue, revoke and key commands", function()
  local env, r, _, dsk, labels = setup()
  local io = F.io({ "top", "pulse", "2", "1" }, { false })
  ok(access.main({ "setup", "--key", SECRET }, io, env))
  local c = access.load()
  eq({ c.secret, c.output, c.open_secs, c.min_level, c.invert }, { SECRET, "top", 2, 1, false })
  local io2 = F.io()
  ok(access.main({ "issue", "Riley", "3" }, io2, env))
  ok(io2.said[1]:find("Issued Riley"))
  eq(labels.right, "Card: Riley")
  local card = access.readCard("/tmp-acc/disk1")
  eq({ card.name, card.level }, { "Riley", 3 })
  ok(access.verify(c, card))
  ok(access.main({ "revoke", card.id }, io2, env))
  ok(not access.verify(access.load(), card))
  ok(access.main({ "list" }, io2, env))
  ok(io2.said[#io2.said]:find("revoked: " .. card.id, 1, true))
  ok(access.main({ "unrevoke", card.id }, io2, env))
  ok(access.verify(access.load(), card))
  ok(access.main({ "key" }, io2, env))
  eq(io2.said[#io2.said], SECRET)
  env.disk.present.right = nil
  eq(access.main({ "issue", "X" }, F.io(), env), false)
  eq(access.main({ "issue" }, F.io(), env), false)
  eq(access.main({ "bogus" }, F.io(), env), false)
  cleanup()
  eq(access.main({ "run" }, F.io(), env), false, "not set up")
end)

test("setup validates its answers", function()
  local env = setup()
  eq(access.main({ "setup" }, F.io({ "nowhere" }), env), false)
  eq(access.main({ "setup" }, F.io({ "top", "explode" }), env), false)
  eq(access.main({ "setup" }, F.io({ "top", "pulse", "-1", "1" }), env), false)
  cleanup()
end)

test("keypad: lockout grows with every wrong code", function()
  eq({ keypad.lockout(0), keypad.lockout(1), keypad.lockout(2), keypad.lockout(3) }, { 0, 10, 20, 40 })
  eq(keypad.lockout(20), 600)
end)

test("keypad attempts: right code opens, wrong locks out, lock expires", function()
  local env, _, _, _, _, time = setup()
  local c = { salt = "s1", output = "top", mode = "pulse", open_secs = 1, invert = false }
  c.hash = keypad.hashCode("4711", c.salt)
  local st = {}
  eq((keypad.attempt(c, st, "0000", env)), "wrong")
  local res, left = keypad.attempt(c, st, "4711", env)
  eq(res, "locked")
  eq(left, 10)
  time.t = time.t + 11
  eq((keypad.attempt(c, st, "4711", env)), "open")
  eq(st.failures, 0)
  eq((keypad.attempt(c, st, "1", env)), "wrong")
  eq((keypad.attempt(c, st, "1", env)), "locked")
  time.t = time.t + 11
  eq((keypad.attempt(c, st, "1", env)), "wrong")
  time.t = time.t + 21
  eq((keypad.attempt(c, st, "4711", env)), "open")
  cleanup()
end)

test("keypad commands: setup then run operates the door for the right code only", function()
  local env, r = setup()
  local io = F.io({ "top", "pulse", "1", "2468" }, { false })
  ok(keypad.main({ "setup" }, io, env))
  local c = keypad.load()
  ok(c.hash and c.salt and c.hash ~= "2468")
  local io2 = F.io({ "1111", "2468" })
  env.maxTries = 2
  env.now = nil
  local t = 5000
  env.now = function() t = t + 100 return t end
  ok(keypad.main({ "run" }, io2, env))
  eq(#r.log, 2, "one pulse (on, off) for the right code")
  ok(io2.warned[1]:find("Wrong"))
  eq(keypad.main({ "setup" }, F.io({ "top", "pulse", "1" }, { false }), env), true, "existing code is kept when none is entered")
  cleanup()
  eq(keypad.main({ "run" }, F.io(), env), false)
  eq(keypad.main({ "setup" }, F.io({ "top", "pulse", "1" }, { false }), env), false, "first setup needs a code")
  cleanup()
end)
