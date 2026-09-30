-- SPDX-License-Identifier: AGPL-3.0-or-later
-- gps tools.
--   gpshost setup | run | status      host a GPS beacon (needs a wireless/ender modem); setup stores the coordinates
--   where [--save name] | list | to <name> | remove <name>     your position, waypoints, distance and bearing
-- A GPS constellation needs 4 hosts (three at the corners of a flat triangle plus one above); coordinates come from the
-- F3 debug screen of the block the computer stands on. All hosts must stay loaded. Waypoints live in /etc/tsr/waypoints.
local cli = require("tsrapps.cli")
local vfs = require("tsr.vfs")

local M = {}

M.CONFIG = "/etc/tsr/gps.cfg"
M.WAYPOINTS = "/etc/tsr/waypoints"
M.SPEC = { save = "string" }

local function per(env) return (env and env.peripheral) or peripheral end

function M.loadHost() return vfs.readTable(M.CONFIG) end

--- Is a modem that can transmit far attached? (wireless modems only; ender modems are wireless too)
function M.wirelessModem(env)
  local p = per(env)
  for _, name in ipairs(p.getNames()) do
    if p.getType(name) == "modem" and p.call(name, "isWireless") then return name end
  end
  return nil
end

function M.hostSetup(io, env)
  local cfg = M.loadHost() or {}
  local function coord(label, old)
    local v = tonumber(io.prompt(label, old))
    return v
  end
  cfg.x, cfg.y, cfg.z = coord("X (from F3)", cfg.x), coord("Y", cfg.y), coord("Z", cfg.z)
  if not (cfg.x and cfg.y and cfg.z) then io.err("Coordinates must be numbers.") return false end
  vfs.writeTable(M.CONFIG, cfg)
  io.say(("Saved beacon position %d, %d, %d."):format(cfg.x, cfg.y, cfg.z))
  if not M.wirelessModem(env) then io.warn("No wireless modem attached yet: a GPS host needs one (ender modems reach farthest).") end
  return true
end

function M.gpshost(args, io, env)
  io = io or cli.io()
  local cmd = args[1] or "status"
  if cmd == "setup" then return M.hostSetup(io, env) end
  local cfg = M.loadHost()
  if cmd == "status" then
    if not cfg then io.say("Not configured: run `gpshost setup`.") return true end
    io.say(("Beacon at %d, %d, %d; modem: %s"):format(cfg.x, cfg.y, cfg.z, M.wirelessModem(env) or "NONE"))
    return true
  end
  if cmd == "run" then
    if not cfg then io.err("Not configured: run `gpshost setup`.") return false end
    if not M.wirelessModem(env) then io.err("No wireless modem attached.") return false end
    io.say(("Hosting GPS at %d, %d, %d."):format(cfg.x, cfg.y, cfg.z))
    if env and env.run then return env.run(cfg) end
    os.run({}, "/rom/programs/gps.lua", "host", tostring(cfg.x), tostring(cfg.y), tostring(cfg.z))
    return true
  end
  io.say("usage: gpshost setup | run | status")
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- Waypoints
---------------------------------------------------------------------------------------------------------------------

function M.loadWaypoints() return vfs.readJSON(M.WAYPOINTS .. ".json") or {} end
function M.saveWaypoints(w) return vfs.writeJSON(M.WAYPOINTS .. ".json", w) end

--- Distance and compass bearing from (x1,z1) to (x2,z2). North is -z.
function M.bearing(x1, z1, x2, z2)
  local dx, dz = x2 - x1, z2 - z1
  local names = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
  if dx == 0 and dz == 0 then return 0, "here" end
  local angle = math.deg(math.atan2(dx, -dz)) % 360
  return math.floor(math.sqrt(dx * dx + dz * dz) + 0.5), names[math.floor((angle + 22.5) / 45) % 8 + 1]
end

local function locate(env)
  local g = (env and env.gps) or gps
  if not g then return nil, "no gps API" end
  local x, y, z = g.locate(2)
  if not x then return nil, "no GPS signal (is a constellation in range?)" end
  return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
end

function M.where(args, io, env)
  io = io or cli.io()
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  local cmd = pos[1]
  local waypoints = M.loadWaypoints()
  if cmd == "list" then
    local names = {}
    for n in pairs(waypoints) do names[#names + 1] = n end
    table.sort(names)
    if #names == 0 then io.say("No waypoints yet: where --save <name>") return true end
    for _, n in ipairs(names) do io.say(("%-14s %d, %d, %d"):format(n, waypoints[n].x, waypoints[n].y, waypoints[n].z)) end
    return true
  elseif cmd == "remove" then
    if not (pos[2] and waypoints[pos[2]]) then io.err("No such waypoint.") return false end
    waypoints[pos[2]] = nil
    M.saveWaypoints(waypoints)
    io.say("Removed.")
    return true
  end
  local x, y, z = locate(env)
  if not x then io.err(y) return false end
  if cmd == "to" then
    local wp = pos[2] and waypoints[pos[2]]
    if not wp then io.err("No such waypoint (see `where list`).") return false end
    local dist, dir = M.bearing(x, z, wp.x, wp.z)
    io.say(("%s is %d blocks %s (height difference %+d)."):format(pos[2], dist, dir, wp.y - y))
    return true
  end
  io.say(("You are at %d, %d, %d."):format(x, y, z))
  if opts.save then
    waypoints[opts.save] = { x = x, y = y, z = z }
    M.saveWaypoints(waypoints)
    io.say(("Saved waypoint '%s'."):format(opts.save))
  end
  return true
end

return M
