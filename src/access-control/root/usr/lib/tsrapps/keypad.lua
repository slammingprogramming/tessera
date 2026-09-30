-- SPDX-License-Identifier: AGPL-3.0-or-later
-- keypad: a code lock for doors (the "piston door" idea from the old plans, and any redstone door).
--   keypad setup      output, mode (pulse/toggle), open time, whether power CLOSES the door, and the code
--   keypad run        show a keypad prompt; a right code operates the door, wrong codes lock it out for a while
-- The code is stored as a salted, iterated hash. Each wrong attempt doubles the lockout (10 s, 20 s, 40 s ... max 10 min).
local hash = require("tsr.hash")
local cli = require("tsrapps.cli")
local rsio = require("tsrapps.rsio")
local vfs = require("tsr.vfs")

local M = {}

M.CONFIG = "/etc/tsr/keypad.cfg"
M.DEFAULTS = { output = "top", mode = "pulse", open_secs = 3, invert = false }

local function now(env) return (env and env.now) and env.now() or (os.epoch and os.epoch("utc") / 1000 or os.clock()) end

function M.hashCode(code, salt)
  local h = code
  for _ = 1, 200 do h = hash.sha256(salt .. h) end
  return h
end

function M.load() return vfs.readTable(M.CONFIG) end
function M.save(cfg) return vfs.writeTable(M.CONFIG, cfg) end

--- Lockout length in seconds after `failures` wrong codes in a row.
function M.lockout(failures)
  if failures < 1 then return 0 end
  return math.min(600, 10 * 2 ^ (failures - 1))
end

--- Try a code. state = { failures, locked_until } is updated. Returns "open", "wrong" or "locked" (+ seconds left).
function M.attempt(cfg, state, code, env)
  local t = now(env)
  if (state.locked_until or 0) > t then return "locked", math.ceil(state.locked_until - t) end
  if M.hashCode(code or "", cfg.salt) == cfg.hash then
    state.failures, state.locked_until = 0, 0
    return "open"
  end
  state.failures = (state.failures or 0) + 1
  state.locked_until = t + M.lockout(state.failures)
  return "wrong"
end

function M.operate(cfg, env)
  local port = assert(rsio.open(cfg.output, env))
  local openLevel = not cfg.invert
  if cfg.mode == "toggle" then
    local cur = port.getOutput()
    port.set(not ((cur == true) or (type(cur) == "number" and cur > 0)))
    return
  end
  port.set(openLevel)
  local ok, err = pcall((env and env.sleep) or sleep, cfg.open_secs)
  port.set(not openLevel)
  if not ok then error(err, 0) end
end

function M.main(args, io, env)
  io = io or cli.io()
  local cmd = args[1]
  local cfg = M.load()
  if cmd == "setup" then
    cfg = cfg or {}
    for k, v in pairs(M.DEFAULTS) do if cfg[k] == nil then cfg[k] = v end end
    cfg.output = io.prompt("Redstone output that operates the door", cfg.output)
    local p, err = rsio.parse(cfg.output, env)
    if not p then io.err(err) return false end
    cfg.mode = io.prompt("Mode (pulse or toggle)", cfg.mode)
    if cfg.mode ~= "pulse" and cfg.mode ~= "toggle" then io.err("mode must be pulse or toggle") return false end
    cfg.open_secs = tonumber(io.prompt("Seconds the door stays open", cfg.open_secs))
    if not cfg.open_secs or cfg.open_secs <= 0 then io.err("open time must be positive") return false end
    cfg.invert = io.ask and io.ask("Is the door CLOSED by power (piston door)?", cfg.invert) or cfg.invert
    local code = io.secret and io.secret("New code (at least 4 characters)")
    if not code or #code < 4 then
      if not cfg.hash then io.err("A code of at least 4 characters is required.") return false end
    else
      cfg.salt = hash.sha256(tostring(now(env)) .. tostring(math.random(1, 2 ^ 30))):sub(1, 16)
      cfg.hash = M.hashCode(code, cfg.salt)
    end
    M.save(cfg)
    io.say("Saved.")
    return true
  end
  if cmd == "run" then
    if not cfg or not cfg.hash then io.err("Not set up yet: run `keypad setup`.") return false end
    local state = { failures = 0, locked_until = 0 }
    local tries = 0
    while true do
      local left = math.ceil((state.locked_until or 0) - now(env))
      if left > 0 then io.warn(("Locked for %d more seconds."):format(left)) ((env and env.sleep) or sleep)(math.min(left, 5)) end
      local code = io.secret("Code")
      local result, secs = M.attempt(cfg, state, code, env)
      if result == "open" then io.say("Open.") M.operate(cfg, env)
      elseif result == "wrong" then io.warn("Wrong code.")
      else io.warn(("Locked (%ds)."):format(secs)) end
      tries = tries + 1
      if env and env.maxTries and tries >= env.maxTries then return true end
    end
  end
  io.say("usage: keypad setup | run")
  return false
end

return M
