-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Reactor safety supervision (SCADA-lite) for Mekanism fission reactors. The scada service watches every reactor the HAL finds
-- and SCRAMs it (emergency stop) as soon as a reading leaves its safe range. A SCRAM is latched: the reactor stays off until a
-- person checks it and runs `scada reset <name>`.
--
-- /etc/tsr/scada.cfg (all optional):
--   { max_temperature = 1000,   -- kelvin
--     max_damage = 20,          -- percent
--     min_coolant = 20,         -- percent filled
--     max_waste = 90,           -- percent filled
--     poll = 2,                 -- seconds between checks
--     alarm = "top",            -- redstone port switched on while any reactor is latched (siren, lamp...) }
--
-- Reference points from Mekanism's source (FissionReactorMultiblockData, 1.21.x): the reactor starts taking damage above 1200 K, damage
-- grows faster up to 1800 K, and a damage of 100% is a meltdown; getDamagePercent is 0-100 and the filled readings are fractions that the
-- driver converts to percent. The defaults below stay well below those limits on purpose; tune them for your build in-game. A reading the machine
-- does not provide is ignored, EXCEPT that a reactor that cannot be read at all (chunk unloaded, error) is treated as unsafe.
local hal = require("tsr.hal")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("scada")

local M = {}

M.CFG_PATH = "/etc/tsr/scada.cfg"
M.DEFAULTS = { max_temperature = 1000, max_damage = 20, min_coolant = 20, max_waste = 90, poll = 2 }

local latched = {}     -- reactor name -> reason

function M.config()
  local cfg = vfs.readTable(M.CFG_PATH) or {}
  for k, v in pairs(M.DEFAULTS) do if cfg[k] == nil then cfg[k] = v end end
  return cfg
end

--- Why this reactor is unsafe, or nil when it is fine. dev is a HAL device with the reactor capability.
function M.assess(dev, cfg)
  if dev:get("reactor.running") == nil then
    local _, err = dev:get("reactor.running")
    return "cannot read the reactor (" .. tostring(err) .. ")"
  end
  local temp = dev:get("reactor.temperature")
  if temp and temp > cfg.max_temperature then return ("temperature %.0f K above %d K"):format(temp, cfg.max_temperature) end
  local damage = dev:get("reactor.damage")
  if damage and damage > cfg.max_damage then return ("damage %.0f%% above %d%%"):format(damage, cfg.max_damage) end
  local coolant = dev:get("reactor.coolant")
  if coolant and coolant < cfg.min_coolant then return ("coolant %.0f%% below %d%%"):format(coolant, cfg.min_coolant) end
  local waste = dev:get("reactor.waste")
  if waste and waste > cfg.max_waste then return ("waste %.0f%% above %d%%"):format(waste, cfg.max_waste) end
  return nil
end

--- Check every fission reactor once. Returns a list of { name, ok, reason, scrammed }.
function M.check(env, cfg)
  cfg = cfg or M.config()
  local report = {}
  for _, dev in ipairs(hal.find("reactor", env)) do
    if dev.actions["reactor.scram"] then
      local entry = { name = dev.name }
      if latched[dev.name] then
        entry.ok, entry.reason = false, latched[dev.name]
      else
        local reason = M.assess(dev, cfg)
        if reason then
          local scrammed = dev:act("reactor.scram")
          latched[dev.name] = reason
          log.error("SCRAM %s: %s", dev.name, reason)
          os.queueEvent("scada_scram", dev.name, reason)
          entry.ok, entry.reason, entry.scrammed = false, reason, scrammed == true
        else
          entry.ok = true
        end
      end
      report[#report + 1] = entry
    end
  end
  if cfg.alarm then
    local any = next(latched) ~= nil
    local okRs, rsio = pcall(require, "tsrapps.rsio")
    if okRs then
      local port = rsio.open(cfg.alarm, env)
      if port then port.set(any) end
    end
  end
  return report
end

function M.latched() return latched end

--- Clear the latch of a reactor (a person has checked it).
function M.reset(name)
  if not latched[name] then return nil, "not latched" end
  latched[name] = nil
  log.info("latch cleared for %s", name)
  return true
end

function M.clearAll() latched = {} end

--- The scada service.
function M.daemon()
  while true do
    local cfg = M.config()
    pcall(M.check, nil, cfg)
    sleep(cfg.poll)
  end
end

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  return io
end

--- scada status | reset <reactor> | config
function M.cli(args, io, env)
  io = io or defaultIO()
  local cmd = args[1] or "status"
  if cmd == "status" then
    local reactors = hal.find("reactor", env)
    if #reactors == 0 then io.say("No reactors found.") end
    for _, dev in ipairs(reactors) do
      local temp, damage = dev:get("reactor.temperature"), dev:get("reactor.damage")
      io.say(("%-24s %-8s temp %s  damage %s%s"):format(dev.name, dev:get("reactor.running") and "running" or "stopped",
        temp and ("%.0fK"):format(temp) or "?", damage and ("%.0f%%"):format(damage) or "?",
        latched[dev.name] and ("  LATCHED: " .. latched[dev.name]) or ""))
    end
    return true
  elseif cmd == "reset" then
    local ok, err = M.reset(args[2] or "")
    if not ok then io.err(tostring(err)) return false end
    io.say("Latch cleared. The reactor stays off until you start it.")
    return true
  elseif cmd == "config" then
    local cfg = M.config()
    for _, k in ipairs({ "max_temperature", "max_damage", "min_coolant", "max_waste", "poll", "alarm" }) do
      io.say(k .. " = " .. tostring(cfg[k]))
    end
    return true
  end
  io.err("usage: scada status | reset <reactor> | config")
  return false
end

function M.main(args) return M.cli(args) end

return M
