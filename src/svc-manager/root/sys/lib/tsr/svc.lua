-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Service manager. A service is a background program described by a definition file in /etc/tsr/services.d/<name>.lua:
--
--   return {
--     description = "what it does",
--     path = "/usr/bin/foo.lua"   -- a program to run, or:  module = "tsrapps.foo" (its main(args) is called; entry = "name" picks
--                                 another function), or: run = function() end
--     args = { "--daemon" },
--     autostart = true,          -- started at boot (can be overridden with `svc enable|disable`)
--     restart = "on-failure",    -- "never" | "on-failure" (default) | "always"
--     requires = { "net" },      -- other services started first
--     profiles = { "server" },   -- only autostart on these profiles
--     max_restarts = 5,          -- more than this many starts inside `window` seconds marks the service failed
--     window = 60,
--   }
--
-- Packages install definitions; the supervisor (the `svc-manager` init.d daemon, M.supervise) restarts services that die.
-- Control functions (start, stop, ...) can be called from any process: they share this module's state.
local kernel = require("tsr.kernel")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("svc")

local M = {}

M.dir = "/etc/tsr/services.d"
M.statePath = "/etc/tsr/services.state"
M.BACKOFF_MAX = 30

local services = {}      -- name -> record
local timers = {}        -- timer id -> service name
local clock = function() return os.epoch and os.epoch("utc") / 1000 or os.clock() end
function M.setClock(fn) clock = fn end

---------------------------------------------------------------------------------------------------------------------
-- Definitions
---------------------------------------------------------------------------------------------------------------------

local function validName(name) return type(name) == "string" and name:match("^[%w_%-%.]+$") ~= nil end

local function check(def)
  if not validName(def.name) then return nil, "invalid service name" end
  if not (def.path or def.module or def.run) then return nil, "needs path, module or run" end
  if def.restart and def.restart ~= "never" and def.restart ~= "on-failure" and def.restart ~= "always" then
    return nil, "restart must be never, on-failure or always"
  end
  return true
end

--- Register a definition programmatically (tests, packages that build services at runtime).
function M.define(def)
  local ok, err = check(def)
  if not ok then return nil, err end
  local rec = services[def.name]
  if rec then
    rec.def = def     -- keep runtime state across a reload
  else
    services[def.name] = { def = def, state = "stopped", restarts = 0, failures = 0, starts = {} }
  end
  return true
end

--- Read every definition file. Returns the number loaded, plus a list of problems.
function M.load()
  local problems = {}
  local count = 0
  if fs.isDir(M.dir) then
    local names = fs.list(M.dir)
    table.sort(names)
    for _, f in ipairs(names) do
      if f:match("%.lua$") then
        local name = f:gsub("%.lua$", "")
        local path = M.dir .. "/" .. f
        local chunk, err = loadfile(path, "t", setmetatable({}, { __index = _G }))
        local ok, def = false, nil
        if chunk then ok, def = pcall(chunk) else def = err end
        if ok and type(def) == "table" then
          def.name = def.name or name
          local good, why = M.define(def)
          if good then count = count + 1 else problems[#problems + 1] = f .. ": " .. why end
        else
          problems[#problems + 1] = f .. ": " .. tostring(def)
        end
      end
    end
  end
  for _, p in ipairs(problems) do log.warn("service definition %s", p) end
  return count, problems
end

function M.names()
  local out = {}
  for name in pairs(services) do out[#out + 1] = name end
  table.sort(out)
  return out
end

function M.get(name) return services[name] end

function M.reset()
  services, timers = {}, {}
end

---------------------------------------------------------------------------------------------------------------------
-- Enabled flags
---------------------------------------------------------------------------------------------------------------------

local function readState()
  return vfs.readTable(M.statePath) or {}
end

--- Is the service started at boot? An explicit enable/disable wins over the definition's `autostart`.
function M.enabled(name)
  local rec = services[name]
  if not rec then return false end
  local override = (readState().enabled or {})[name]
  if override ~= nil then return override end
  return rec.def.autostart == true
end

local function setEnabled(name, value)
  if not services[name] then return nil, "no such service: " .. tostring(name) end
  local st = readState()
  st.enabled = st.enabled or {}
  st.enabled[name] = value
  vfs.writeTable(M.statePath, st)
  return true
end

function M.enable(name) return setEnabled(name, true) end
function M.disable(name) return setEnabled(name, false) end

---------------------------------------------------------------------------------------------------------------------
-- Control
---------------------------------------------------------------------------------------------------------------------

local function alive(rec) return rec.pid ~= nil and kernel.get(rec.pid) ~= nil end

local function spawn(rec)
  local def = rec.def
  local spec = { name = "svc:" .. def.name, window = false, daemon = true, args = def.args }
  if def.run then
    spec.fn = def.run
  elseif def.module then
    spec.fn = function(...)
      local mod = require(def.module)
      local fnName = def.entry or "main"
      if type(mod) == "table" and type(mod[fnName]) == "function" then return mod[fnName]({ ... }) end
      error("module " .. def.module .. " has no " .. fnName .. "()")
    end
  else
    spec.path = def.path
  end
  local pid, err = kernel.spawn(spec)
  if not pid then return nil, err end
  rec.pid = pid
  rec.state = "running"
  rec.lastStart = clock()
  rec.starts[#rec.starts + 1] = rec.lastStart
  rec.manualStop = false
  log.info("started %s (pid %d)", def.name, pid)
  return true
end

local function startRec(name, visiting)
  local rec = services[name]
  if not rec then return nil, "no such service: " .. tostring(name) end
  if alive(rec) then return true end
  visiting = visiting or {}
  if visiting[name] then return nil, "dependency loop at " .. name end
  visiting[name] = true
  for _, dep in ipairs(rec.def.requires or {}) do
    local ok, err = startRec(dep, visiting)
    if not ok then return nil, name .. " needs " .. dep .. ": " .. tostring(err) end
  end
  visiting[name] = nil
  rec.failedPermanently = false
  rec.backoffTimer = nil
  local ok, err = spawn(rec)
  if not ok then
    rec.state, rec.lastError = "failed", tostring(err)
    log.warn("cannot start %s: %s", name, tostring(err))
    return nil, err
  end
  return true
end

function M.start(name) return startRec(name) end

--- Services that list `name` in their requirements (directly), currently running.
local function dependents(name)
  local out = {}
  for other, rec in pairs(services) do
    for _, dep in ipairs(rec.def.requires or {}) do
      if dep == name and alive(rec) then out[#out + 1] = other end
    end
  end
  table.sort(out)
  return out
end

function M.stop(name)
  local rec = services[name]
  if not rec then return nil, "no such service: " .. tostring(name) end
  for _, d in ipairs(dependents(name)) do M.stop(d) end
  rec.manualStop = true
  rec.backoffTimer = nil
  if alive(rec) then
    local pid = rec.pid
    kernel.terminate(pid)
    if kernel.get(pid) then kernel.kill(pid) end
  end
  rec.pid = nil
  rec.state = "stopped"
  log.info("stopped %s", name)
  return true
end

function M.restart(name)
  local ok, err = M.stop(name)
  if not ok then return nil, err end
  return M.start(name)
end

--- Start everything that is enabled (and allowed on this profile). Returns the names started.
function M.autostart()
  local profile = require("tsr.profile").get()
  local started = {}
  for _, name in ipairs(M.names()) do
    local def = services[name].def
    local allowed = true
    if def.profiles then
      allowed = false
      for _, p in ipairs(def.profiles) do if p == profile then allowed = true end end
    end
    if allowed and M.enabled(name) then
      local ok, err = M.start(name)
      if ok then started[#started + 1] = name else log.warn("autostart %s failed: %s", name, tostring(err)) end
    end
  end
  return started
end

---------------------------------------------------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------------------------------------------------

function M.status(name)
  local rec = services[name]
  if not rec then return nil end
  if rec.state == "running" and not alive(rec) then rec.state = "stopped" end
  return {
    name = name, state = rec.state, pid = alive(rec) and rec.pid or nil, restarts = rec.restarts,
    description = rec.def.description or "", enabled = M.enabled(name), restart = rec.def.restart or "on-failure",
    lastError = rec.lastError, lastStart = rec.lastStart, requires = rec.def.requires or {},
  }
end

function M.list()
  local out = {}
  for _, name in ipairs(M.names()) do out[#out + 1] = M.status(name) end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Supervision
---------------------------------------------------------------------------------------------------------------------

local function trimStarts(rec, window)
  local now = clock()
  local keep = {}
  for _, t in ipairs(rec.starts) do if now - t <= window then keep[#keep + 1] = t end end
  rec.starts = keep
end

--- Handle the exit of process `pid`. Returns the service name when it was one of ours.
function M.onExit(pid, ok, err)
  for name, rec in pairs(services) do
    if rec.pid == pid then
      rec.pid = nil
      if rec.manualStop then
        rec.state = "stopped"
        return name
      end
      local clean = ok or err == "Terminated"
      rec.lastError = (not clean) and tostring(err) or nil
      local policy = rec.def.restart or "on-failure"
      local again = policy == "always" or (policy == "on-failure" and not clean)
      if not again then
        rec.state = clean and "stopped" or "failed"
        log.info("%s exited%s", name, clean and "" or (": " .. tostring(err)))
        return name
      end
      local window = rec.def.window or 60
      trimStarts(rec, window)
      if #rec.starts >= (rec.def.max_restarts or 5) then
        rec.state, rec.failedPermanently = "failed", true
        log.error("%s keeps dying (%d starts in %ds); giving up", name, #rec.starts, window)
        return name
      end
      rec.failures = clean and 0 or rec.failures + 1
      local delay = math.min(M.BACKOFF_MAX, 2 ^ math.max(0, rec.failures - 1))
      rec.state = "backoff"
      rec.restarts = rec.restarts + 1
      local t = os.startTimer(delay)
      timers[t] = name
      rec.backoffTimer = t
      log.warn("%s exited (%s); restarting in %ds", name, tostring(err), delay)
      return name
    end
  end
end

--- A timer fired: restart the service it was waiting for.
function M.onTimer(id)
  local name = timers[id]
  if not name then return end
  timers[id] = nil
  local rec = services[name]
  if rec and rec.state == "backoff" and rec.backoffTimer == id then
    startRec(name)
  end
end

--- Stop every running service (used at shutdown).
function M.stopAll()
  for _, name in ipairs(M.names()) do
    if alive(services[name]) then M.stop(name) end
  end
end

--- The supervisor loop (runs as the svc-manager daemon).
function M.supervise()
  M.load()
  M.autostart()
  while true do
    local ev = table.pack(os.pullEventRaw())
    if ev[1] == "tsr_proc_exit" then
      M.onExit(ev[2], ev[3], ev[4])
    elseif ev[1] == "timer" then
      M.onTimer(ev[2])
    elseif ev[1] == "svc_reload" then
      M.load()
    end
  end
end

return M
