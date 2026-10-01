-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Rules engine: watch readings from the HAL and act when they cross a threshold. Rule files live in /etc/tsr/rules.d/*.lua and
-- return one rule or a list of rules:
--
--   return {
--     name = "generator-on-when-low",
--     every = 5,                                    -- seconds between checks (default 5)
--     when = { device = "cube_0", metric = "energy.percent", op = "<", value = 20 },
--     hold = 10,                                    -- the condition must stay true this long before the rule fires
--     clear = { device = "cube_0", metric = "energy.percent", op = ">", value = 60 },   -- optional hysteresis
--     on  = { { action = "device", device = "generator", do_ = "machine.start" },
--             { action = "log", level = "warn", text = "Power low (${value}%)" } },
--     off = { { action = "device", device = "generator", do_ = "machine.stop" } },
--   }
--
-- Conditions combine with { all = {...} }, { any = {...} } and { ["not"] = cond }. Operators: < <= > >= == ~= and
-- "between" (value = {low, high}); without an operator the reading itself must be true. Actions (`action = ...`):
--   device    { device, do_ (an action name; `do` is a Lua keyword), args = {...} }       through the HAL
--   redstone  { port = "back:red", set = true | 0-15 }
--   command   { line = "shell command line" }
--   service   { start | stop | restart = "service name" }
--   log       { level = "info" | "warn" | "error", text = "..." }          ${value}, ${rule}, ${state} are replaced
--   event     { name = "my_event" }                                         queues an os event: tsr_rule, rule, state
-- A rule fires its `on` list once when it becomes active and its `off` list once when it ends (edge-triggered), not on every check.
local hal = require("tsr.hal")
local log = require("tsr.log").get("rules")

local M = {}

M.dir = "/etc/tsr/rules.d"
M.SCAN_EVERY = 10          -- seconds between full hardware scans

---------------------------------------------------------------------------------------------------------------------
-- Conditions
---------------------------------------------------------------------------------------------------------------------

local OPS = {
  ["<"] = function(a, b) return a < b end,
  ["<="] = function(a, b) return a <= b end,
  [">"] = function(a, b) return a > b end,
  [">="] = function(a, b) return a >= b end,
  ["=="] = function(a, b) return a == b end,
  ["~="] = function(a, b) return a ~= b end,
  between = function(a, r) return type(r) == "table" and a >= r[1] and a <= r[2] end,
}

--- Evaluate a condition. `lookup(deviceName)` returns a HAL device. Returns true/false, plus the last reading seen, or
--- nil + error when a device or reading is unavailable.
function M.evaluate(cond, lookup)
  if type(cond) ~= "table" then return nil, "bad condition" end
  if cond.all then
    local reading
    for _, c in ipairs(cond.all) do
      local r, v = M.evaluate(c, lookup)
      if r == nil then return nil, v end
      if reading == nil then reading = v end
      if not r then return false, reading end
    end
    return true, reading
  elseif cond.any then
    local reading, firstErr
    for _, c in ipairs(cond.any) do
      local r, v = M.evaluate(c, lookup)
      if r == nil then firstErr = firstErr or v
      else
        if reading == nil then reading = v end
        if r then return true, v end
      end
    end
    if firstErr and reading == nil then return nil, firstErr end
    return false, reading
  elseif cond["not"] then
    local r, v = M.evaluate(cond["not"], lookup)
    if r == nil then return nil, v end
    return not r, v
  end
  local dev = lookup(cond.device)
  if not dev then return nil, "no device '" .. tostring(cond.device) .. "'" end
  local value, unit = dev:get(cond.metric, cond.arg)
  if value == nil then return nil, tostring(cond.device) .. ": " .. tostring(unit) end
  if cond.op == nil then return value == true or (type(value) == "number" and value ~= 0), value end
  local fn = OPS[cond.op]
  if not fn then return nil, "unknown operator " .. tostring(cond.op) end
  if cond.op ~= "between" and cond.op ~= "==" and cond.op ~= "~=" and type(value) ~= "number" then
    return nil, "reading is not a number"
  end
  return fn(value, cond.value) and true or false, value
end

---------------------------------------------------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------------------------------------------------

M.actions = {}

function M.actions.device(a, ctx)
  local dev = ctx.lookup(a.device)
  if not dev then return nil, "no device '" .. tostring(a.device) .. "'" end
  return dev:act(a.do_ or a["do"], table.unpack(a.args or {}))
end

function M.actions.redstone(a, ctx)
  local rsio = require("tsrapps.rsio")
  local port, err = rsio.open(a.port, ctx.env)
  if not port then return nil, err end
  port.set(a.set)
  return true
end

function M.actions.command(a, ctx)
  local okCron, cron = pcall(require, "tsr.cron")
  if ctx.run then return ctx.run(a.line) end
  if okCron then return cron.run(a.line) == 0 end
  return shell.run(a.line)
end

function M.actions.service(a)
  local svc = require("tsr.svc")
  for _, verb in ipairs({ "start", "stop", "restart" }) do
    if a[verb] then return svc[verb](a[verb]) end
  end
  return nil, "service action needs start, stop or restart"
end

function M.actions.log(a, ctx)
  local level = a.level or "info"
  local text = ctx.format(a.text or "")
  local logger = log[level] or log.info
  logger("%s", text)
  return true
end

function M.actions.event(a, ctx)
  os.queueEvent("tsr_rule", ctx.rule.name, ctx.state, a.name)
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Engine
---------------------------------------------------------------------------------------------------------------------

local Engine = {}
Engine.__index = Engine

--- opts: now (function -> seconds), env (HAL env: peripheral, redstone...), run (function(line) for command actions)
function M.engine(opts)
  opts = opts or {}
  return setmetatable({
    rules = {}, states = {}, now = opts.now or function() return (os.epoch and os.epoch("utc") or os.clock() * 1000) / 1000 end,
    env = opts.env or {}, run = opts.run, devices = nil, scannedAt = nil,
  }, Engine)
end

function Engine:setRules(list)
  local known = {}
  self.rules = list
  for _, r in ipairs(list) do known[r.name] = true end
  for name in pairs(self.states) do if not known[name] then self.states[name] = nil end end
end

--- Read rule files from M.dir. Returns the number of rules and a list of problems.
function Engine:load(dir)
  dir = dir or M.dir
  local list, problems = {}, {}
  if fs.isDir(dir) then
    local names = fs.list(dir)
    table.sort(names)
    for _, f in ipairs(names) do
      if f:match("%.lua$") then
        local chunk, err = loadfile(dir .. "/" .. f, "t", setmetatable({}, { __index = _G }))
        local ok, def = false, err
        if chunk then ok, def = pcall(chunk) end
        if ok and type(def) == "table" then
          local items = def.name and { def } or def
          for _, r in ipairs(items) do
            if type(r) == "table" and type(r.name) == "string" and type(r.when) == "table" then list[#list + 1] = r
            else problems[#problems + 1] = f .. ": a rule needs a name and a `when` condition" end
          end
        else
          problems[#problems + 1] = f .. ": " .. tostring(def)
        end
      end
    end
  end
  self:setRules(list)
  return #list, problems
end

local function ensureDevices(self, t)
  if not self.devices or not self.scannedAt or t - self.scannedAt >= M.SCAN_EVERY then
    self.devices = hal.scan(self.env)
    self.scannedAt = t
  end
end

function Engine:lookup(name)
  return hal.byName(self.devices or {}, name)
end

function Engine:state(rule)
  local st = self.states[rule.name]
  if not st then
    st = { state = "idle", since = self.now(), nextCheck = 0 }
    self.states[rule.name] = st
  end
  return st
end

local function runActions(self, rule, list, stateName)
  local ctx = {
    lookup = function(n) return self:lookup(n) end, env = self.env, run = self.run, rule = rule, state = stateName,
    format = function(text)
      local st = self.states[rule.name] or {}
      return (text:gsub("%${(%w+)}", function(k)
        if k == "value" then
          local v = st.value
          if type(v) == "number" then return (v == math.floor(v)) and ("%d"):format(v) or ("%.1f"):format(v) end
          return tostring(v)
        elseif k == "rule" then return rule.name
        elseif k == "state" then return stateName end
        return "${" .. k .. "}"
      end))
    end,
  }
  for _, a in ipairs(list or {}) do
    local fn = M.actions[a.action]
    if not fn then
      log.warn("rule %s: unknown action %s", rule.name, tostring(a.action))
    else
      local ok, res, err = pcall(fn, a, ctx)
      if not ok then log.warn("rule %s: action %s failed: %s", rule.name, a.action, tostring(res))
      elseif res == nil and err then log.warn("rule %s: action %s failed: %s", rule.name, a.action, tostring(err)) end
    end
  end
end

--- Check every rule that is due. Returns the list of { rule, event = "on"|"off" } that fired.
function Engine:tick()
  local t = self.now()
  ensureDevices(self, t)
  local fired = {}
  for _, rule in ipairs(self.rules) do
    local st = self:state(rule)
    if t >= st.nextCheck then
      st.nextCheck = t + (rule.every or 5)
      local active = st.state == "active"
      local cond = (active and rule.clear) and { ["not"] = rule.clear } or rule.when
      local result, value = M.evaluate(cond, function(n) return self:lookup(n) end)
      if result == nil then
        if st.error ~= value then log.warn("rule %s: %s", rule.name, tostring(value)) end
        st.error = value
      else
        st.error = nil
        st.value = value
        if st.state == "idle" then
          if result then
            if (rule.hold or 0) > 0 then st.state, st.since = "pending", t
            else st.state, st.since = "active", t runActions(self, rule, rule.on, "on") fired[#fired + 1] = { rule = rule.name, event = "on" } end
          end
        elseif st.state == "pending" then
          if not result then st.state, st.since = "idle", t
          elseif t - st.since >= rule.hold then
            st.state, st.since = "active", t
            runActions(self, rule, rule.on, "on")
            fired[#fired + 1] = { rule = rule.name, event = "on" }
          end
        elseif st.state == "active" then
          -- `cond` is the rule's own condition, or "clear is not (yet) true" when a clear condition is given;
          -- either way the rule ends as soon as it is false
          if not result then
            st.state, st.since = "idle", t
            runActions(self, rule, rule.off, "off")
            fired[#fired + 1] = { rule = rule.name, event = "off" }
          end
        end
      end
    end
  end
  return fired
end

function Engine:status()
  local out = {}
  for _, rule in ipairs(self.rules) do
    local st = self.states[rule.name] or { state = "idle" }
    out[#out + 1] = { name = rule.name, state = st.state, value = st.value, error = st.error }
  end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Daemon and command
---------------------------------------------------------------------------------------------------------------------

local shared

function M.shared()
  if not shared then shared = M.engine() end
  return shared
end

--- The rulesd service.
function M.daemon()
  local engine = M.shared()
  local stamp
  while true do
    local sig = ""
    if fs.isDir(M.dir) then
      for _, f in ipairs(fs.list(M.dir)) do sig = sig .. f .. ":" .. fs.getSize(M.dir .. "/" .. f) .. ";" end
    end
    if sig ~= stamp then
      stamp = sig
      local n, problems = engine:load()
      log.info("%d rules loaded", n)
      for _, p in ipairs(problems) do log.warn("%s", p) end
    end
    engine:tick()
    sleep(1)
  end
end

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  return io
end

--- rules list | check [<name>]
function M.cli(args, io, env)
  io = io or defaultIO()
  local cmd = args[1] or "list"
  local engine = M.engine({ env = env })
  local n, problems = engine:load()
  if cmd == "list" then
    if n == 0 then io.say("No rules. Put files in " .. M.dir .. " (see the header of tsr/rules.lua for the format).") end
    for _, r in ipairs(engine.rules) do io.say(("%-24s every %ss%s"):format(r.name, tostring(r.every or 5), r.hold and (", hold " .. r.hold .. "s") or "")) end
    for _, p in ipairs(problems) do io.err(p) end
    return #problems == 0
  elseif cmd == "check" then
    -- evaluate every condition once, without running any action
    engine.devices = hal.scan(engine.env)
    for _, r in ipairs(engine.rules) do
      if not args[2] or args[2] == r.name then
        local res, value = M.evaluate(r.when, function(nm) return engine:lookup(nm) end)
        if res == nil then io.say(r.name .. ": cannot evaluate (" .. tostring(value) .. ")")
        else io.say(r.name .. ": " .. (res and "TRUE" or "false") .. (value ~= nil and (" (reading " .. tostring(value) .. ")") or "")) end
      end
    end
    for _, p in ipairs(problems) do io.err(p) end
    return true
  end
  io.err("usage: rules list | check [name]")
  return false
end

function M.main(args) return M.cli(args) end

return M
