-- SPDX-License-Identifier: AGPL-3.0-or-later
local Sim = dofile("/tests/lib/turtlesim.lua")
local T = require("tsr.turtle")
local remote = require("tsrapps.remote")

local DIR = "/tmp-remote"

local function fresh()
  if fs.exists(DIR) then fs.delete(DIR) end
  T.dir = DIR
  T.sleep = function() end
  T.unloadForTest()
  remote.STATE_FILE = DIR .. "/remote.json"
  remote.KEY_FILE = DIR .. "/remote.key"
  local sim = Sim.new({ fuel = 500 })
  sim:install()
  return sim
end

local function done(sim)
  sim:uninstall()
  if fs.exists(DIR) then fs.delete(DIR) end
end

local SECRET = "correct horse battery"

--- A pair of in-memory endpoints: the controller's send() feeds the turtle's queue and vice versa.
local function link()
  local toTurtle, toController = {}, {}
  local turtleNet = {
    receive = function() local m = table.remove(toTurtle, 1) if m then return m.from, m.msg end end,
    send = function(id, msg) toController[#toController + 1] = { from = 5, msg = msg } end,
  }
  local controllerNet = {
    receive = function()
      -- serve one queued request on the turtle side first (single-threaded test)
      return nil
    end,
    send = function(id, msg) toTurtle[#toTurtle + 1] = { from = 9, msg = msg } end,
  }
  return toTurtle, toController, turtleNet, controllerNet
end

test("requests are signed and verified", function()
  local req = remote.request(SECRET, "forward", nil, 100)
  eq(req.v, 1)
  eq(req.sig, remote.sign(SECRET, 100, "forward", nil))
  ok(req.sig ~= remote.sign("other passphrase", 100, "forward", nil))
  ok(req.sig ~= remote.sign(SECRET, 101, "forward", nil))
  ok(req.sig ~= remote.sign(SECRET, 100, "back", nil))
  ok(remote.sign(SECRET, 1, "goto", "1,2,3") ~= remote.sign(SECRET, 1, "goto", "1,2,4"))
end)

test("the turtle obeys valid commands and updates its position", function()
  local sim = fresh()
  local state = { last = {} }
  local reply = remote.handle(SECRET, state, 9, remote.request(SECRET, "forward", nil, 1))
  ok(reply and reply.ok)
  eq({ sim:where() }, { 0, 0, -1, 0 })
  reply = remote.handle(SECRET, state, 9, remote.request(SECRET, "right", nil, 2))
  eq(sim.dir, 1)
  reply = remote.handle(SECRET, state, 9, remote.request(SECRET, "status", nil, 3))
  ok(reply.ok and reply.data.x == 0 and reply.data.z == -1 and reply.data.facing == "east", textutils.serialize(reply))
  eq(reply.data.fuel, 499)
  ok(remote.verifyReply(SECRET, reply, 3))
  done(sim)
end)

test("wrong keys and replays are ignored silently", function()
  local sim = fresh()
  local state = { last = {} }
  eq(remote.handle(SECRET, state, 9, remote.request("wrong passphrase!!", "forward", nil, 10)), nil)
  eq({ sim:where() }, { 0, 0, 0, 0 })
  local good = remote.request(SECRET, "forward", nil, 20)
  ok(remote.handle(SECRET, state, 9, good))
  eq(remote.handle(SECRET, state, 9, good), nil, "the same message cannot be replayed")
  eq(remote.handle(SECRET, state, 9, remote.request(SECRET, "forward", nil, 19)), nil, "older counter refused")
  eq({ sim:where() }, { 0, 0, -1, 0 })
  ok(remote.handle(SECRET, state, 8, remote.request(SECRET, "forward", nil, 5)), "counters are per sender")
  eq(remote.handle(SECRET, state, 9, { v = 1, n = 30, cmd = "forward", sig = "x" }), nil)
  eq(remote.handle(SECRET, state, 9, "garbage"), nil)
  eq(remote.handle(SECRET, state, 9, { v = 2, n = 30, cmd = "forward" }), nil)
  done(sim)
end)

test("only whitelisted commands exist", function()
  local sim = fresh()
  local state = { last = {} }
  local reply = remote.handle(SECRET, state, 9, remote.request(SECRET, "os.shutdown", nil, 1))
  ok(reply and not reply.ok and reply.data == "unknown command")
  reply = remote.handle(SECRET, state, 9, remote.request(SECRET, "select", "99", 2))
  ok(reply and not reply.ok)
  reply = remote.handle(SECRET, state, 9, remote.request(SECRET, "goto", "not coordinates", 3))
  ok(reply and not reply.ok)
  for name in pairs(remote.COMMANDS) do ok(type(name) == "string") end
  ok(remote.COMMANDS.exec == nil and remote.COMMANDS.eval == nil and remote.COMMANDS.run == nil)
  done(sim)
end)

test("blocked moves report the reason", function()
  local sim = fresh()
  sim:set(0, 0, -1, "minecraft:stone")
  local state = { last = {} }
  local reply = remote.handle(SECRET, state, 9, remote.request(SECRET, "forward", nil, 1))
  ok(reply and reply.ok == false and reply.data:find("obstructed"))
  reply = remote.handle(SECRET, state, 9, remote.request(SECRET, "dig", nil, 2))
  ok(reply.ok)
  eq(sim:itemCount("minecraft:cobblestone"), 1)
  done(sim)
end)

test("goto walks to coordinates, digging", function()
  local sim = fresh()
  sim:fill(0, 0, -3, 0, 0, -3, "minecraft:stone")
  local state = { last = {} }
  local reply = remote.handle(SECRET, state, 9, remote.request(SECRET, "goto", "0,0,-4", 1))
  ok(reply.ok, textutils.serialize(reply))
  eq({ sim:where() }, { 0, 0, -4, 0 })
  done(sim)
end)

test("serve loop answers, remembers counters across restarts and stops on `stop`", function()
  local sim = fresh()
  local toTurtle, toController, turtleNet = link()
  toTurtle[#toTurtle + 1] = { from = 9, msg = remote.request(SECRET, "forward", nil, 100) }
  toTurtle[#toTurtle + 1] = { from = 9, msg = remote.request(SECRET, "forward", nil, 100) } -- replay
  toTurtle[#toTurtle + 1] = { from = 9, msg = remote.request(SECRET, "stop", nil, 101) }
  local said = {}
  local result = remote.serve(SECRET, turtleNet, { say = function(t) said[#said + 1] = t end })
  eq(result, "stopped")
  eq(#toController, 2, "two replies: forward and stop; the replay got none")
  eq({ sim:where() }, { 0, 0, -1, 0 })
  -- "restart": a fresh serve() reads the saved counters, so an old message is still refused
  toTurtle[#toTurtle + 1] = { from = 9, msg = remote.request(SECRET, "forward", nil, 100) }
  toTurtle[#toTurtle + 1] = { from = 9, msg = remote.request(SECRET, "forward", nil, 102) }
  remote.serve(SECRET, turtleNet, nil, { rounds = 1 })
  eq({ sim:where() }, { 0, 0, -2, 0 }, "only the fresh message moved the turtle")
  done(sim)
end)

test("call() round trip verifies the reply signature", function()
  local sim = fresh()
  local turtleState = { last = {} }
  local inbox = {}
  -- a loopback where the "turtle" answers inside send()
  local net = {
    send = function(id, msg)
      local reply = remote.handle(SECRET, turtleState, 9, msg)
      if reply then inbox[#inbox + 1] = { from = id, msg = reply } end
    end,
    receive = function() local m = table.remove(inbox, 1) if m then return m.from, m.msg end end,
  }
  local data, err = remote.call(SECRET, net, 5, "status")
  ok(data and data.fuel == 500, tostring(err))
  local nothing, err2 = remote.call(SECRET, net, 5, "select", "77")
  ok(nothing == nil and err2:find("slot must be"))
  -- a forged reply is rejected
  local forging = {
    send = function(id, msg) inbox[#inbox + 1] = { from = id, msg = { v = 1, n = msg.n, ok = true, data = "hacked", sig = "deadbeef" } } end,
    receive = function() local m = table.remove(inbox, 1) if m then return m.from, m.msg end end,
  }
  local forged, err3 = remote.call(SECRET, forging, 5, "status")
  ok(forged == nil and err3:find("bad signature"), tostring(err3))
  done(sim)
end)

test("the passphrase is saved and reused, and must be long enough", function()
  local sim = fresh()
  local io = { said = {}, say = function(t) end, secret = function() return "short" end }
  local key, err = remote.secret(io, false)
  ok(key == nil and err:find("8 characters"))
  io.secret = function() return "a long enough passphrase" end
  eq(remote.secret(io, false), "a long enough passphrase")
  io.secret = function() error("must not ask again") end
  eq(remote.secret(io, false), "a long enough passphrase")
  io.secret = function() return "another long passphrase" end
  eq(remote.secret(io, true), "another long passphrase", "--pair replaces it")
  done(sim)
end)
