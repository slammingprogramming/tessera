-- SPDX-License-Identifier: AGPL-3.0-or-later
-- chunkctl: drive a redstone-powered chunk loader (or any always-on machine) by rules.
--   chunkctl setup | status | on | off | run
--   modes:  always      on all the time
--           schedule    on between two times of day (in-game hours, e.g. 6 and 22)
--           players     on only while a player is within range of an Advanced Peripherals "playerDetector"
--           manual      whatever `chunkctl on|off` last set
-- `chunkctl run` keeps the output in line with the mode every few seconds; put it in startup or /etc/tsr/init.d.
local cli = require("tsrapps.cli")
local rsio = require("tsrapps.rsio")
local vfs = require("tsr.vfs")

local M = {}

M.CONFIG = "/etc/tsr/chunkctl.cfg"
M.MODES = { always = true, schedule = true, players = true, manual = true }
M.DEFAULTS = { output = "back", mode = "always", from = 6, to = 22, range = 64, manual = true }

function M.load() return vfs.readTable(M.CONFIG) or {} end
function M.save(cfg) return vfs.writeTable(M.CONFIG, cfg) end

--- Should the loader be on? ctx: hour (0-24 in-game time), playersNear (bool or nil when unknown).
function M.desired(cfg, ctx)
  if cfg.mode == "always" then return true end
  if cfg.mode == "manual" then return cfg.manual ~= false end
  if cfg.mode == "schedule" then
    local from, to, h = cfg.from, cfg.to, ctx.hour
    if from == to then return true end
    if from < to then return h >= from and h < to end
    return h >= from or h < to           -- a window that wraps past midnight
  end
  if cfg.mode == "players" then
    if ctx.playersNear == nil then return true end   -- no detector: stay safe, keep the chunks loaded
    return ctx.playersNear
  end
  return true
end

--- Is any player within `range` blocks of the detector? Returns true/false, or nil without a detector.
function M.playersNear(range, per)
  per = per or peripheral
  local det = per.find("playerDetector")
  if not det then return nil end
  local ok, res = pcall(function()
    if det.isPlayersInRange then return det.isPlayersInRange(range) end
    return #det.getPlayersInRange(range) > 0
  end)
  if not ok then return nil end
  return res and true or false
end

--- Apply the mode once. Returns the state that was set.
function M.tick(cfg, env)
  env = env or {}
  local ctx = { hour = env.hour or os.time("ingame") }
  if cfg.mode == "players" then ctx.playersNear = M.playersNear(cfg.range, env.peripheral) end
  local want = M.desired(cfg, ctx)
  local port = assert(rsio.open(cfg.output, env))
  port.set(want)
  return want
end

function M.main(args, io, env)
  io = io or cli.io()
  local cmd = args[1]
  local cfg = M.load()
  for k, v in pairs(M.DEFAULTS) do if cfg[k] == nil then cfg[k] = v end end
  if cmd == "setup" then
    cfg.output = io.prompt("Redstone output that powers the chunk loader", cfg.output)
    local p, err = rsio.parse(cfg.output, env)
    if not p then io.err(err) return false end
    cfg.mode = io.prompt("Mode (always, schedule, players, manual)", cfg.mode)
    if not M.MODES[cfg.mode] then io.err("unknown mode " .. tostring(cfg.mode)) return false end
    if cfg.mode == "schedule" then
      cfg.from = tonumber(io.prompt("Switch on at hour (0-23)", cfg.from))
      cfg.to = tonumber(io.prompt("Switch off at hour (0-23)", cfg.to))
      if not (cfg.from and cfg.to and cfg.from >= 0 and cfg.from < 24 and cfg.to >= 0 and cfg.to < 24) then
        io.err("hours must be numbers from 0 to 23") return false
      end
    elseif cfg.mode == "players" then
      cfg.range = tonumber(io.prompt("Range in blocks", cfg.range))
      if not cfg.range or cfg.range < 1 then io.err("range must be a positive number") return false end
    end
    M.save(cfg)
    io.say("Saved.")
    return true
  elseif cmd == "on" or cmd == "off" then
    cfg.mode, cfg.manual = "manual", cmd == "on"
    M.save(cfg)
    local port, err = rsio.open(cfg.output, env)
    if not port then io.err(err) return false end
    port.set(cfg.manual)
    io.say("Chunk loader " .. cmd)
    return true
  elseif cmd == "status" then
    io.say(("mode %s, output %s"):format(cfg.mode, cfg.output))
    local port = rsio.open(cfg.output, env)
    if port then io.say("output is " .. tostring(port.getOutput())) end
    return true
  elseif cmd == "run" then
    io.say("Running chunk loader control (mode " .. cfg.mode .. "). Ctrl+T to stop.")
    local rounds = 0
    while true do
      M.tick(cfg, env)
      rounds = rounds + 1
      if env and env.maxRounds and rounds >= env.maxRounds then break end
      sleep(5)
    end
    return true
  end
  io.say("usage: chunkctl setup | status | on | off | run")
  return false
end

return M
