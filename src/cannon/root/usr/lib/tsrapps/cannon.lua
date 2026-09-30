-- SPDX-License-Identifier: AGPL-3.0-or-later
-- cannon: control a redstone-fired TNT cannon (a technical Minecraft build): a dispenser/loader is pulsed to charge
-- the barrel, then an igniter fires it. The controller only sequences redstone outputs; you build the cannon.
--   cannon setup                     ports, volley size, timings and the arming code
--   cannon status | arm | disarm
--   cannon fire [volleys] [--dry-run]     needs the cannon to be armed; auto-disarms afterwards
-- Safety: firing needs the arming code (checked as a salted hash, never stored in clear), armed status expires after
-- 60 s, and volleys are capped and spaced by a cooldown. --dry-run prints the sequence without touching redstone.
local hash = require("tsr.hash")
local cli = require("tsrapps.cli")
local rsio = require("tsrapps.rsio")
local redseq = require("tsrapps.redseq")
local vfs = require("tsr.vfs")

local M = {}

M.CONFIG = "/etc/tsr/cannon.cfg"
M.STATE = "/var/lib/tsr/cannon.state"
M.ARM_SECONDS = 60
M.MAX_VOLLEYS = 10
M.SPEC = { ["dry-run"] = "bool" }

M.DEFAULTS = { charge = "back", fire = "top", volley = 3, charge_pulse = 0.4, gap = 0.6, fire_delay = 1.0, cooldown = 10 }

local function now(env) return (env and env.now) and env.now() or (os.epoch and os.epoch("utc") / 1000 or os.clock()) end

--- Salted, iterated SHA-256 of the arming code.
function M.hashCode(code, salt)
  local h = code
  for _ = 1, 200 do h = hash.sha256(salt .. h) end
  return h
end

function M.loadConfig() return vfs.readTable(M.CONFIG) end

function M.saveConfig(cfg) return vfs.writeTable(M.CONFIG, cfg) end

--- The redseq step list for `volleys` volleys with the given config.
function M.sequence(cfg, volleys)
  local steps = {}
  for v = 1, volleys do
    for _ = 1, cfg.volley do
      steps[#steps + 1] = { op = "pulse", port = cfg.charge, secs = cfg.charge_pulse }
      steps[#steps + 1] = { op = "wait", secs = cfg.gap }
    end
    steps[#steps + 1] = { op = "wait", secs = cfg.fire_delay }
    steps[#steps + 1] = { op = "pulse", port = cfg.fire, secs = 0.3 }
    if v < volleys then steps[#steps + 1] = { op = "wait", secs = cfg.cooldown } end
  end
  return steps
end

--- Validate a config table. Returns true or false + reason.
function M.validate(cfg, env)
  for _, key in ipairs({ "charge", "fire" }) do
    local p, err = rsio.parse(tostring(cfg[key]), env)
    if not p then return false, key .. " port: " .. err end
  end
  if cfg.charge == cfg.fire then return false, "the charge and fire outputs must be different" end
  for _, key in ipairs({ "volley", "charge_pulse", "gap", "fire_delay", "cooldown" }) do
    if type(cfg[key]) ~= "number" or cfg[key] <= 0 then return false, key .. " must be a positive number" end
  end
  if cfg.volley ~= math.floor(cfg.volley) or cfg.volley > 64 then return false, "volley must be a whole number up to 64" end
  return true
end

function M.armed(env)
  local st = vfs.readTable(M.STATE)
  return st and st.armed_until and st.armed_until > now(env) or false
end

function M.arm(cfg, code, env)
  if not cfg.hash then return false, "not set up yet: run `cannon setup`" end
  if M.hashCode(code or "", cfg.salt) ~= cfg.hash then return false, "wrong arming code" end
  vfs.writeTable(M.STATE, { armed_until = now(env) + M.ARM_SECONDS })
  return true
end

function M.disarm() vfs.writeTable(M.STATE, { armed_until = 0 }) end

--- Fire. Returns true or false + reason. opts.dryRun returns the steps without running them.
function M.fire(cfg, volleys, env, opts)
  opts = opts or {}
  if volleys < 1 or volleys > M.MAX_VOLLEYS or volleys ~= math.floor(volleys) then
    return false, ("volleys must be a whole number from 1 to %d"):format(M.MAX_VOLLEYS)
  end
  local good, why = M.validate(cfg, env)
  if not good then return false, why end
  local steps = M.sequence(cfg, volleys)
  if opts.dryRun then return true, steps end
  if not M.armed(env) then return false, "not armed: run `cannon arm` first" end
  local ok, err = redseq.run(steps, env)
  M.disarm()
  if not ok then return false, "sequence stopped: " .. tostring(err) end
  return true, steps
end

function M.main(args, io, env)
  io = io or cli.io()
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  local cmd = pos[1]
  local cfg = M.loadConfig()
  if cmd == "setup" then
    cfg = cfg or {}
    for k, v in pairs(M.DEFAULTS) do if cfg[k] == nil then cfg[k] = v end end
    cfg.charge = io.prompt("Output that charges the barrel (e.g. back, or back:red)", cfg.charge)
    cfg.fire = io.prompt("Output that fires (igniter)", cfg.fire)
    cfg.volley = tonumber(io.prompt("Charges per volley", cfg.volley))
    cfg.charge_pulse = tonumber(io.prompt("Charge pulse length (s)", cfg.charge_pulse))
    cfg.gap = tonumber(io.prompt("Pause after each charge (s)", cfg.gap))
    cfg.fire_delay = tonumber(io.prompt("Pause before firing (s)", cfg.fire_delay))
    cfg.cooldown = tonumber(io.prompt("Cooldown between volleys (s)", cfg.cooldown))
    local good, why = M.validate(cfg, env)
    if not good then io.err(why) return false end
    local code = io.secret and io.secret("Arming code (at least 6 characters)")
    if code and #code >= 6 then
      cfg.salt = tostring(math.random(1, 2 ^ 30)) .. tostring(now(env))
      cfg.hash = M.hashCode(code, cfg.salt)
    elseif not cfg.hash then
      io.err("An arming code of at least 6 characters is required.")
      return false
    end
    M.saveConfig(cfg)
    io.say("Cannon configured.")
    return true
  end
  if not cfg then io.err("Not set up yet: run `cannon setup`.") return false end
  if cmd == "status" then
    io.say(("charge %s, fire %s, %d charges per volley, cooldown %ss"):format(cfg.charge, cfg.fire, cfg.volley, cfg.cooldown))
    io.say(M.armed(env) and "ARMED" or "safe")
    return true
  elseif cmd == "arm" then
    local code = (io.secret and io.secret("Arming code")) or ""
    local ok, err = M.arm(cfg, code, env)
    if not ok then io.err(err) return false end
    io.say(("Armed for %d seconds."):format(M.ARM_SECONDS))
    return true
  elseif cmd == "disarm" then
    M.disarm()
    io.say("Safe.")
    return true
  elseif cmd == "fire" then
    local volleys = tonumber(pos[2] or "1")
    if not volleys then io.err("volleys must be a number") return false end
    local ok, res = M.fire(cfg, volleys, env, { dryRun = opts["dry-run"] })
    if not ok then io.err(res) return false end
    if opts["dry-run"] then
      io.say(("%d steps, %.1f seconds; nothing was switched."):format(redseq.count(res), redseq.duration(res)))
    else
      io.say("Fired " .. volleys .. " volley(s). Cannon is safe again.")
    end
    return true
  end
  io.say("usage: cannon setup | status | arm | disarm | fire [volleys] [--dry-run]")
  return false
end

return M
