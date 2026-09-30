-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local gpstools = require("tsrapps.gpstools")

local function setup()
  fs.delete("/tmp-gps")
  gpstools.CONFIG = "/tmp-gps/gps.cfg"
  gpstools.WAYPOINTS = "/tmp-gps/waypoints"
  local pos = { 100.2, 64.4, -200.6 }
  local fakeGps = { locate = function() if pos then return pos[1], pos[2], pos[3] end end }
  local modem = { _type = "modem", isWireless = function() return true end }
  local env = { gps = fakeGps, peripheral = F.peripheralApi({ modem_0 = modem }) }
  return env, pos
end

test("bearing: distance and compass direction (north is -z)", function()
  eq({ gpstools.bearing(0, 0, 0, -10) }, { 10, "N" })
  eq({ gpstools.bearing(0, 0, 10, 0) }, { 10, "E" })
  eq({ gpstools.bearing(0, 0, 0, 10) }, { 10, "S" })
  eq({ gpstools.bearing(0, 0, -10, 0) }, { 10, "W" })
  eq({ gpstools.bearing(0, 0, 10, -10) }, { 14, "NE" })
  eq({ gpstools.bearing(0, 0, -10, 10) }, { 14, "SW" })
  eq({ gpstools.bearing(5, 5, 5, 5) }, { 0, "here" })
end)

test("where shows the rounded position and saves waypoints", function()
  local env = setup()
  local io = F.io()
  ok(gpstools.where({ "--save", "home" }, io, env))
  ok(io.said[1]:find("100, 64, %-201"), io.said[1])
  local wp = gpstools.loadWaypoints()
  eq(wp.home, { x = 100, y = 64, z = -201 })
  ok(gpstools.where({ "list" }, io, env))
  ok(io.said[#io.said]:find("home"))
  fs.delete("/tmp-gps")
end)

test("where to reports distance, direction and height", function()
  local env, pos = setup()
  gpstools.saveWaypoints({ mine = { x = 100, y = 40, z = -251 } })
  local io = F.io()
  ok(gpstools.where({ "to", "mine" }, io, env))
  ok(io.said[1]:find("50 blocks N") and io.said[1]:find("%-24"), io.said[1])
  eq(gpstools.where({ "to", "nowhere" }, F.io(), env), false)
  fs.delete("/tmp-gps")
end)

test("where remove, and no signal errors", function()
  local env, pos = setup()
  gpstools.saveWaypoints({ a = { x = 1, y = 2, z = 3 } })
  ok(gpstools.where({ "remove", "a" }, F.io(), env))
  eq(gpstools.where({ "remove", "a" }, F.io(), env), false)
  env.gps = { locate = function() return nil end }
  local io = F.io()
  eq(gpstools.where({}, io, env), false)
  ok(io.errs[1]:find("no GPS signal"))
  fs.delete("/tmp-gps")
end)

test("gpshost setup stores coordinates and warns without a modem", function()
  local env = setup()
  local io = F.io({ "10", "70", "-5" })
  ok(gpstools.gpshost({ "setup" }, io, env))
  eq(gpstools.loadHost(), { x = 10, y = 70, z = -5 })
  eq(#io.warned, 0)
  local bare = { peripheral = F.peripheralApi({}) }
  local io2 = F.io({ "1", "2", "3" })
  ok(gpstools.gpshost({ "setup" }, io2, bare))
  ok(io2.warned[1]:find("wireless modem"))
  eq(gpstools.gpshost({ "setup" }, F.io({ "x", "1", "2" }), env), false)
  fs.delete("/tmp-gps")
end)

test("gpshost run needs config and a wireless modem, then starts the beacon", function()
  local env = setup()
  eq(gpstools.gpshost({ "run" }, F.io(), env), false)
  gpstools.gpshost({ "setup" }, F.io({ "10", "70", "-5" }), env)
  local started
  env.run = function(cfg) started = cfg return true end
  ok(gpstools.gpshost({ "run" }, F.io(), env))
  eq(started, { x = 10, y = 70, z = -5 })
  local ioNoModem = F.io()
  eq(gpstools.gpshost({ "run" }, ioNoModem, { peripheral = F.peripheralApi({}) }), false)
  ok(ioNoModem.errs[1]:find("No wireless modem"))
  local st = F.io()
  ok(gpstools.gpshost({ "status" }, st, env))
  ok(st.said[1]:find("Beacon at 10, 70, %-5") and st.said[1]:find("modem_0"))
  fs.delete("/tmp-gps")
end)
