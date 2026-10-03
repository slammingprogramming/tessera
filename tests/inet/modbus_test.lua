-- SPDX-License-Identifier: AGPL-3.0-or-later
local modbus = require("tsr.modbus")
local serverMod = require("tsr.modbus.server")
local daemon = require("tsr.modbus.daemon")
local cli = require("tsr.modbus.cli")
local socket = require("tsr.inet.socket")
local vfs = require("tsr.vfs")
local Sim = dofile("/tests/lib/inetsim.lua")

--- A fake redstone world and fake machines.
local function plant()
  local world = { out = { back = 0, ["right"] = 0 }, inp = { left = 0, front = 15 }, tank = 0.5, machine = false, calls = {} }
  local rsio = {}
  function rsio.open(spec)
    local side = spec:match("^(%a+)")
    return {
      getOutput = function() return world.out[side] or 0 end,
      getInput = function() return world.inp[side] or 0 end,
      set = function(level)
        if level == true then level = 15 elseif level == false then level = 0 end
        world.out[side] = level
        world.calls[#world.calls + 1] = side .. "=" .. tostring(level)
      end,
    }
  end
  local smelter = { name = "smelter",
    get = function(_, what) if what == "machine.running" then return world.machine end if what == "fluid.percent" then return world.tank * 100 end end,
    act = function(_, action, ...)
      world.calls[#world.calls + 1] = action .. "(" .. table.concat({ ... }, ",") .. ")"
      if action == "machine.start" then world.machine = true return true end
      if action == "machine.stop" then world.machine = false return true end
      if action == "redstone.set" then return true end
      return nil, "no such action"
    end }
  return world, { rsio = rsio, devices = function() return { smelter } end }
end

local function config(world)
  local stored = {}
  return {
    allow = {}, units = {
      [1] = {
        coils = { [0] = { rs = "back" }, [1] = { dev = "smelter", read = "machine.running", on = "machine.start", off = "machine.stop" }, [2] = { var = "flag" } },
        inputs = { [0] = { rs = "left" }, [1] = { rs = "front" }, [2] = { dev = "smelter", read = "machine.running" } },
        registers = { [0] = { dev = "smelter", read = "fluid.percent", scale = 100 }, [1] = { rs = "left", analog = true }, [2] = { const = 4242 }, [3] = { read = function() return 70000 end } },
        holding = { [0] = { var = "setpoint", init = 50 }, [1] = { rs = "right", analog = true }, [2] = { dev = "smelter", read = "fluid.percent", act = "redstone.set", args = { "top" }, scale = 1 } },
      },
      [7] = { coils = { [0] = { read = function() error("sensor broken") end, write = function() error("stuck") end } } },
    },
  }
end

local function pdu(...) return string.char(...) end

test("frames and bit packing", function()
  local f = modbus.frame(0x1234, 5, "\3\0\0\0\2")
  eq(f, "\18\52\0\0\0\6\5\3\0\0\0\2")
  eq(modbus.bitsToBytes({ true, false, true, true, false, false, false, false, true }), "\13\1")
  eq(modbus.bytesToBits("\13\1", 9), { true, false, true, true, false, false, false, false, true })
  ok(modbus.bytesToBits("\13", 9) == nil)
end)

test("the slave: reading every kind of point", function()
  local world, env = plant()
  world.out.back, world.inp.left = 15, 9
  local srv = serverMod.new(config(world), env)
  -- coils 0..2: back is on, machine off, flag off -> 0b001
  eq(srv:request(1, pdu(1, 0, 0, 0, 3)), "\1\1\1")
  world.machine = true
  eq(srv:request(1, pdu(1, 0, 0, 0, 3)), "\1\1\3")
  -- discrete inputs: left has a level (on), front 15 (on), the machine runs
  eq(srv:request(1, pdu(2, 0, 0, 0, 3)), "\2\1\7")
  -- input registers: tank 50% * scale 100 = 5000; analog redstone 9; a constant; values are clamped to 16 bits
  eq(srv:request(1, pdu(4, 0, 0, 0, 4)), "\4\8" .. "\19\136" .. "\0\9" .. "\16\146" .. "\255\255")
  -- holding: a stored value, an analog output, a device value
  eq(srv:request(1, pdu(3, 0, 0, 0, 3)), "\3\6\0\50\0\0\0\50")
  -- a different unit, and a unit that is not there
  eq(srv:request(7, pdu(1, 0, 0, 0, 1)), pdu(129, 4), "a point that throws is a device failure")
  eq(srv:request(9, pdu(1, 0, 0, 0, 1)), pdu(129, 11))
  -- errors: address, quantity, function
  eq(srv:request(1, pdu(1, 0, 3, 0, 1)), pdu(129, 2))
  eq(srv:request(1, pdu(1, 0, 2, 0, 2)), pdu(129, 2), "one address of the range is missing")
  eq(srv:request(1, pdu(1, 0, 0, 0, 0)), pdu(129, 3))
  eq(srv:request(1, pdu(1, 0, 0, 7, 209)), pdu(129, 3), "more than 2000 coils")
  eq(srv:request(1, pdu(3, 0, 0, 0, 126)), pdu(131, 3), "more than 125 registers")
  eq(srv:request(1, pdu(1, 0, 0)), pdu(129, 3), "a short request")
  eq(srv:request(1, pdu(43, 14, 1, 0)), pdu(171, 1), "an unsupported function")
  eq(srv.stats.requests >= 10 and srv.stats.errors >= 7, true)
end)

test("the slave: writing coils and registers, with limits and read-only mode", function()
  local world, env = plant()
  local writes = {}
  local cfg = config(world)
  cfg.onWrite = function(unit, kind, addr, value) writes[#writes + 1] = ("%s:%s:%s=%s"):format(unit, kind, addr, tostring(value)) end
  local srv = serverMod.new(cfg, env)
  -- function 5 echoes the request
  eq(srv:request(1, pdu(5, 0, 0, 255, 0)), pdu(5, 0, 0, 255, 0))
  eq(world.out.back, 15)
  eq(srv:request(1, pdu(5, 0, 0, 0, 0)), pdu(5, 0, 0, 0, 0))
  eq(world.out.back, 0)
  eq(srv:request(1, pdu(5, 0, 1, 255, 0)), pdu(5, 0, 1, 255, 0))
  eq(world.machine, true)
  srv:request(1, pdu(5, 0, 1, 0, 0))
  eq(world.machine, false)
  eq(srv:request(1, pdu(5, 0, 0, 1, 1)), pdu(133, 3), "only FF00 and 0000 mean on and off")
  eq(srv:request(1, pdu(5, 0, 9, 255, 0)), pdu(133, 2))
  -- an input cannot be written
  eq(srv:request(1, pdu(5, 0, 5, 255, 0)), pdu(133, 2))
  -- several coils: 3 coils, values 1,0,1 -> flag and back on, machine off
  eq(srv:request(1, pdu(15, 0, 0, 0, 3, 1, 5)), pdu(15, 0, 0, 0, 3))
  eq({ world.out.back, world.machine }, { 15, false })
  eq(srv:request(1, pdu(15, 0, 0, 0, 3, 2, 5)), pdu(143, 3), "byte count must fit")
  eq(srv:request(1, pdu(15, 0, 2, 0, 3, 1, 7)), pdu(143, 2), "the range runs past the last coil: nothing is written")
  -- registers
  eq(srv:request(1, pdu(6, 0, 0, 0, 75)), pdu(6, 0, 0, 0, 75))
  eq(srv:request(1, pdu(3, 0, 0, 0, 1)), pdu(3, 2, 0, 75))
  eq(srv:request(1, pdu(6, 0, 1, 0, 9)), pdu(6, 0, 1, 0, 9))
  eq(world.out.right, 9)
  srv:request(1, pdu(6, 0, 1, 0, 200))
  eq(world.out.right, 15, "analog outputs are limited to 0..15")
  eq(srv:request(1, pdu(6, 0, 2, 0, 4)), pdu(6, 0, 2, 0, 4))
  eq(world.calls[#world.calls], "redstone.set(top,4)")
  eq(srv:request(1, pdu(6, 0, 7, 0, 4)), pdu(134, 2))
  eq(srv:request(1, pdu(16, 0, 0, 0, 2, 4, 0, 10, 0, 11)), pdu(16, 0, 0, 0, 2))
  eq(srv:request(1, pdu(3, 0, 0, 0, 2)), pdu(3, 4, 0, 10, 0, 11))
  eq(srv:request(1, pdu(16, 0, 0, 0, 2, 3, 0, 10, 0)), pdu(144, 3))
  -- a write that throws
  eq(srv:request(7, pdu(5, 0, 0, 255, 0)), pdu(133, 4))
  ok(#writes >= 8 and writes[1] == "1:coil:0=true", table.concat(writes, ","))
  -- read-only mode
  local ro = serverMod.new({ units = cfg.units, readonly = true }, env)
  eq(ro:request(1, pdu(5, 0, 0, 255, 0)), pdu(133, 1))
  eq(ro:request(1, pdu(6, 0, 0, 0, 1)), pdu(134, 1))
  eq(ro:request(1, pdu(16, 0, 0, 0, 1, 2, 0, 1)), pdu(144, 1))
  ok(ro:request(1, pdu(1, 0, 0, 0, 1)):byte(1) == 1, "reading still works")
  eq(ro.stats.refused, 3)
  -- a bad map is reported when the server starts
  local okNew, err = pcall(serverMod.new, { units = { [1] = { coils = { [0] = { wrong = true } } } } }, env)
  ok(not okNew and tostring(err):find("unit 1 coils[0]", 1, true), tostring(err))
end)

local function net(cfg)
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local plc = sim:host("plc")
  sim:plug(plc, "eth0", seg, "10.0.0.7/24")
  local scada, intruder = sim:host("scada"), sim:host("intruder")
  sim:plug(scada, "eth0", seg, "10.0.0.20/24")
  sim:plug(intruder, "eth0", seg, "10.0.0.200/24")
  local world, env = plant()
  local srv = serverMod.new(cfg(world), env)
  local l = socket.tcp(plc)
  l:bind(nil, 502)
  l:listen(4)
  local t = sim:spawn(function()
    while true do
      local c = l:accept(300)
      if not c then return end
      local w = sim:spawn(function() srv:serve(c) end)
      w.daemon = true
    end
  end)
  t.daemon = true
  sim:run(0.2)
  return sim, world, srv, scada, intruder
end

test("over the network: the client reads and writes, exceptions come back as errors, the allow list keeps strangers out", function()
  local sim, world, srv, scada, intruder = net(function(w) local c = config(w) c.allow = { "10.0.0.0/25" } return c end)
  local c = assert(modbus.connect(scada, "10.0.0.7", { unit = 1 }))
  world.out.back = 15
  eq(c:readCoils(0, 3), { true, false, false })
  eq(c:readDiscrete(0, 2), { false, true })
  eq(c:readInput(0, 3), { 5000, 0, 4242 })
  eq(c:readHolding(0, 1), { 50 })
  ok(c:writeCoil(1, true)) eq(world.machine, true)
  ok(c:writeRegister(0, 1500)) eq(c:readHolding(0, 1), { 1500 })
  ok(c:writeRegisters(0, { 7, 8 })) eq(c:readHolding(0, 2), { 7, 8 })
  ok(c:writeCoils(0, { false, false, true }))
  eq(c:readCoils(0, 3), { false, false, true })
  -- errors
  local v, why, code = c:readCoils(10, 1)
  ok(v == nil and why == "illegal data address" and code == 2, tostring(why))
  ok(c:readCoils(0, 0) == nil and select(2, c:readCoils(0, 3000)) == "bad count")
  ok(select(2, c:writeRegister(0, 70000)):find("0..65535", 1, true))
  c.unit = 9
  eq(select(2, c:readCoils(0, 1)), "exception 11")
  c:close()
  -- the intruder is let in at the TCP level but gets nothing
  local bad = assert(modbus.connect(intruder, "10.0.0.7", { unit = 1, timeout = 3 }))
  local r, e = bad:readCoils(0, 1)
  ok(r == nil, "no answer for a network that is not allowed: " .. tostring(e))
  ok(srv.stats.refused >= 1)
end)

test("the modbus commands", function()
  local sim, world, srv, scada = net(function(w) return config(w) end)
  local function ctx()
    local out = { lines = {}, errors = {} }
    out.ctx = { stack = scada, say = function(t) out.lines[#out.lines + 1] = t end, err = function(t) out.errors[#out.errors + 1] = t end, sleep = function() end }
    return out
  end
  local o = ctx()
  ok(cli.run({ "read", "10.0.0.7", "coils", "0", "3" }, o.ctx))
  eq(o.lines, { "coils         0  off", "coils         1  off", "coils         2  off" })
  o = ctx()
  ok(cli.run({ "write", "10.0.0.7", "coil", "0", "on" }, o.ctx))
  eq(o.lines, { "ok" }) eq(world.out.back, 15)
  ok(cli.run({ "write", "10.0.0.7", "register", "0", "11", "12" }, ctx().ctx))
  o = ctx()
  ok(cli.run({ "poll", "10.0.0.7", "holding", "0", "2", "-n", "2", "-i", "1" }, o.ctx))
  eq(o.lines, { "holding       0  11", "holding       1  12", "holding       0  11", "holding       1  12" })
  o = ctx()
  ok(not cli.run({ "read", "10.0.0.7", "coils", "99" }, o.ctx))
  eq(o.errors, { "illegal data address" })
  o = ctx()
  ok(not cli.run({ "write", "10.0.0.7", "coil", "0", "maybe" }, o.ctx) and o.errors[1] == "a coil is set to on or off")
  ok(not cli.run({ "read" }, ctx().ctx))
  -- the settings file
  local saved = daemon.CONFIG
  daemon.CONFIG = "/tmp/modbus-test.lua"
  if vfs.fs.exists(daemon.CONFIG) then vfs.fs.delete(daemon.CONFIG) end
  local c = ctx()
  ok(cli.ctl({ "init" }, c.ctx) and not cli.ctl({ "init" }, ctx().ctx))
  local cfg = assert(daemon.loadConfig())
  eq(cfg.port, 502) eq(cfg.allow, { "10.0.0.0/24" })
  ok(serverMod.new(cfg, { rsio = {}, devices = function() return {} end }), "the example file builds a server")
  local st = ctx()
  ok(cli.ctl({ "status" }, st.ctx))
  ok(st.lines[1]:find("port 502, 1 unit(s), 4 point(s), writable, networks: 10.0.0.0/24", 1, true), st.lines[1])
  vfs.fs.delete(daemon.CONFIG)
  daemon.CONFIG = saved
end)
