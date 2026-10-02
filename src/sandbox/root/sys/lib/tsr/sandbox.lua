-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Sandbox: run a Lua program with a restricted view of the computer.
--
--   local sb = require("tsr.sandbox")
--   local ok, result = sb.run("/downloads/game.lua", { root = "/var/sandbox/game", timeout = 5, args = { "easy" } })
--
-- What the program gets
--   * a copy of the safe standard library (string, table, math, coroutine, bit32, utf8) and of textutils/colors/keys/vector
--   * a file system that shows only `root` as "/" (writes outside it are impossible) plus a read-only /rom
--   * the terminal, os.clock/time/epoch/pullEvent/sleep, but NOT os.shutdown/reboot/run, io, debug, http, peripherals, rednet,
--     redstone, shell or the global table of the real system (unless opts.allow says so)
--   * a CPU limit (`timeout` seconds of running time, the program may wait for events for as long as it likes) and a memory limit
-- What it is NOT: a hard security boundary against someone who finds a hole in CC itself. It stops mistakes and the usual
-- malicious tricks (deleting files, shutting down, stealing the network, endless loops), nothing more. Known gaps: string
-- methods such as ("x"):rep(1e9) and pathological Lua patterns run in native code that the instruction hook cannot interrupt, so
-- a program can still make the computer sluggish or run it out of memory that way; give untrusted code a window of its own and
-- watch it.
local vfs = require("tsr.vfs")

local M = {}

M.DEFAULT_TIMEOUT = 10
M.DEFAULT_MEMORY_KB = 4096
M.HOOK_EVERY = 2000

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Jailed file system
---------------------------------------------------------------------------------------------------------------------

--- Clean a sandbox path: "/a/../../b" becomes "b"; ".." can never climb above the top.
local function clean(path)
  local parts = {}
  for part in tostring(path):gsub("\\", "/"):gmatch("[^/]+") do
    if part == ".." then parts[#parts] = nil elseif part ~= "." then parts[#parts + 1] = part end
  end
  return table.concat(parts, "/")
end

local function dirSize(path)
  if not fs.exists(path) then return 0 end
  if not fs.isDir(path) then return fs.getSize(path) end
  local total = 0
  for _, name in ipairs(fs.list(path)) do total = total + dirSize(path .. "/" .. name) end
  return total
end

--- A file system API whose "/" is the real folder `root` (created if needed). opts.quota: bytes the jail may hold (default
--- 200000). "/rom" is the real, read-only rom.
function M.jail(root, opts)
  opts = opts or {}
  root = vfs.normalize(root)
  if not fs.exists(root) then fs.makeDir(root) end
  local quota = opts.quota or 200000
  local J = {}

  local function real(path, forWrite)
    local rel = clean(path)
    if rel == "rom" or rel:sub(1, 4) == "rom/" then
      if forWrite then error("Access denied", 3) end
      return "/" .. rel
    end
    return rel == "" and root or (root .. "/" .. rel)
  end

  local function readOnly(path) local rel = clean(path) return rel == "rom" or rel:sub(1, 4) == "rom/" end

  function J.exists(p) return fs.exists(real(p)) end
  function J.isDir(p) return fs.isDir(real(p)) end
  function J.isReadOnly(p) return readOnly(p) end
  function J.getName(p) return fs.getName(p) end
  function J.getDir(p) return fs.getDir(p) end
  function J.combine(...) return fs.combine(...) end
  function J.getSize(p) return fs.getSize(real(p)) end
  function J.list(p)
    local names = fs.list(real(p))
    if clean(p) == "" then
      local seen = false
      for _, n in ipairs(names) do if n == "rom" then seen = true end end
      if not seen then names[#names + 1] = "rom" end
      table.sort(names)
    end
    return names
  end
  function J.getDrive() return nil end
  function J.getCapacity() return quota end
  function J.getFreeSpace() return math.max(0, quota - dirSize(root)) end
  function J.find(pattern)
    local out = {}
    for _, f in ipairs(fs.find(real(pattern))) do
      local rel = f:sub(#root + 2)
      if f:sub(1, 4) == "/rom" then rel = f:sub(2) end
      out[#out + 1] = rel
    end
    return out
  end
  function J.complete(...) return {} end
  function J.attributes(p)
    local a = fs.attributes(real(p))
    return a
  end

  function J.makeDir(p) fs.makeDir(real(p, true)) end
  function J.delete(p)
    if clean(p) == "" then error("Access denied", 2) end
    fs.delete(real(p, true))
  end
  function J.move(a, b) fs.move(real(a, true), real(b, true)) end
  function J.copy(a, b)
    if dirSize(real(a)) + dirSize(root) > quota then error("Out of space", 2) end
    fs.copy(real(a), real(b, true))
  end

  function J.open(p, mode)
    mode = mode or "r"
    local writing = mode:sub(1, 1) ~= "r"
    local h, err = fs.open(real(p, writing), mode)
    if not h or not writing then return h, err end
    -- count what is written so the jail cannot outgrow its quota
    local used = dirSize(root)
    local function charge(n)
      used = used + n
      if used > quota then h.close() error("Out of space", 3) end
    end
    local wrapper = copy(h)
    if h.write then wrapper.write = function(s) charge(#tostring(s)) return h.write(s) end end
    if h.writeLine then wrapper.writeLine = function(s) charge(#tostring(s) + 1) return h.writeLine(s) end end
    return wrapper
  end

  return J
end

---------------------------------------------------------------------------------------------------------------------
-- The restricted global environment
---------------------------------------------------------------------------------------------------------------------

local SAFE_GLOBALS = { "assert", "error", "ipairs", "next", "pairs", "pcall", "xpcall", "select", "tonumber", "tostring", "type",
                       "rawequal", "rawget", "rawset", "rawlen", "setmetatable", "_VERSION", "print", "write", "printError", "read",
                       "sleep", "unpack" }

local SAFE_LIBS = { "string", "table", "math", "coroutine", "bit32", "utf8", "textutils", "colors", "colours", "keys", "vector",
                    "window" }

--- Build the environment. opts: guard ({ hook = function, violation = function -> text|nil }, set by run), fs (jail API), allow = { peripheral = bool, http = bool, rednet = bool, redstone = bool, os = bool,
--- shell = table }, env (extra globals).
function M.environment(opts)
  opts = opts or {}
  local allow = opts.allow or {}
  local env = {}
  for _, name in ipairs(SAFE_GLOBALS) do env[name] = _G[name] end
  if not env.unpack then env.unpack = table.unpack end
  for _, name in ipairs(SAFE_LIBS) do
    if type(_G[name]) == "table" then env[name] = copy(_G[name]) end
  end
  env.string.dump = nil
  env._G = env
  env._ENV = nil

  -- a string-building bomb cannot be interrupted by the instruction hook, so cap it
  local realRep = string.rep
  env.string.rep = function(str, n, sep)
    if #tostring(str) * (tonumber(n) or 0) > 1000000 then error("string too large for the sandbox", 2) end
    return realRep(str, n, sep)
  end

  local guard = opts.guard
  if guard then
    -- an error caused by a limit must not be catchable: pcall passes it on
    env.pcall = function(f, ...)
      local res = table.pack(pcall(f, ...))
      local v = guard.violation()
      if v then error(v, 0) end
      return table.unpack(res, 1, res.n)
    end
    env.xpcall = function(f, handler, ...)
      local res = table.pack(xpcall(f, handler, ...))
      local v = guard.violation()
      if v then error(v, 0) end
      return table.unpack(res, 1, res.n)
    end
    -- coroutines made by the program are watched too (hooks belong to a single coroutine)
    local create = coroutine.create
    env.coroutine.create = function(fn)
      local co = create(fn)
      if debug and debug.sethook then debug.sethook(co, guard.hook, "", M.HOOK_EVERY) end
      return co
    end
    local realResume = coroutine.resume
    env.coroutine.resume = function(co, ...)
      local res = table.pack(realResume(co, ...))
      local v = guard.violation()
      if v then error(v, 0) end       -- the limit was hit inside the other coroutine: end the whole program
      return table.unpack(res, 1, res.n)
    end
    env.coroutine.wrap = function(fn)
      local co = env.coroutine.create(fn)
      return function(...)
        local res = table.pack(env.coroutine.resume(co, ...))
        if not res[1] then error(res[2], 0) end
        return table.unpack(res, 2, res.n)
      end
    end
  end

  -- strings share one metatable with the real system: do not let the program reach it
  env.getmetatable = function(v)
    if type(v) == "string" then return {} end
    return getmetatable(v)
  end

  -- a small, harmless part of debug (cc.pretty and the stock shell use it); nothing that reaches into other functions
  env.debug = {
    getinfo = function(f, what) return debug.getinfo(f, what) end,
    traceback = function(...) return debug.traceback(...) end,
    getregistry = function() return {} end,
  }

  -- a limited os
  local sos = { clock = os.clock, time = os.time, day = os.day, epoch = os.epoch, date = os.date, getComputerID = os.getComputerID,
                getComputerLabel = os.getComputerLabel, pullEvent = os.pullEvent, pullEventRaw = os.pullEventRaw,
                startTimer = os.startTimer, cancelTimer = os.cancelTimer, setAlarm = os.setAlarm, cancelAlarm = os.cancelAlarm,
                version = os.version }
  sos.queueEvent = function(name, ...)
    -- only custom events: faking key or mouse input would reach other programs
    if type(name) ~= "string" or name:sub(1, 3) ~= "sb_" then error("sandboxed programs may only queue events starting with sb_", 2) end
    return os.queueEvent(name, ...)
  end
  if allow.os then
    sos.shutdown, sos.reboot = os.shutdown, os.reboot
  end
  env.os = sos

  -- the terminal (whatever the sandbox is run on) and the jailed file system
  -- the terminal: redirecting is allowed only to windows the program made itself (or the terminal it was started on),
  -- and there is no native terminal to draw outside the window
  env.term = copy(term)
  env.term.native = nil
  local allowedTerms = setmetatable({}, { __mode = "k" })
  allowedTerms[term.current()] = true
  env.window.create = function(...)
    local w = window.create(...)
    allowedTerms[w] = true
    return w
  end
  env.term.redirect = function(target)
    if not allowedTerms[target] then error("Access denied", 2) end
    return term.redirect(target)
  end
  env.fs = opts.fs or M.jail("/var/sandbox/default")

  -- loading code: always text, always in the sandbox environment
  env.load = function(chunk, name, mode, e)
    return load(chunk, name, "t", e or env)
  end
  env.loadfile = function(path, mode, e)
    local h = env.fs.open(path, "r")
    if not h then return nil, "cannot open " .. tostring(path) end
    local text = h.readAll()
    h.close()
    return load(text, "@" .. path, "t", e or env)
  end
  env.dofile = function(path)
    local fn, err = env.loadfile(path)
    if not fn then error(err, 2) end
    return fn()
  end

  -- a minimal require
  local loaded = {}
  env.require = function(name)
    if loaded[name] ~= nil then return loaded[name] end
    local rel = name:gsub("%.", "/")
    for _, pattern in ipairs({ "%s.lua", "%s/init.lua", "rom/modules/main/%s.lua", "rom/modules/main/%s/init.lua" }) do
      local path = pattern:format(rel)
      if env.fs.exists(path) and not env.fs.isDir(path) then
        local fn, err = env.loadfile(path)
        if not fn then error(err, 2) end
        local result = fn(name)
        if result == nil then result = true end
        loaded[name] = result
        return result
      end
    end
    error("module '" .. name .. "' not found", 2)
  end

  -- settings in memory only
  local store = {}
  env.settings = { get = function(k, d) if store[k] ~= nil then return store[k] end return d end, set = function(k, v) store[k] = v end,
                   unset = function(k) store[k] = nil end, define = function() end, getNames = function() local n = {} for k in pairs(store) do n[#n + 1] = k end return n end,
                   save = function() return true end, load = function() return false end }

  -- opt-in access to real hardware and network
  if allow.peripheral then env.peripheral = copy(peripheral) end
  if allow.redstone then env.redstone = copy(redstone) env.rs = env.redstone end
  if allow.rednet then env.rednet = copy(rednet) end
  if allow.http and rawget(_G, "http") then env.http = copy(http) end
  if allow.shell then env.shell = allow.shell end

  for k, v in pairs(opts.env or {}) do env[k] = v end
  return env
end

---------------------------------------------------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------------------------------------------------

--- Run `target` (a function, a file name in the REAL file system, or a chunk of source text prefixed with "=") inside the sandbox.
--- opts: root (jail folder), quota, timeout (seconds of CPU time), memory (KB), allow, env, args, fs (a prepared jail),
--- source (run this source text instead of reading a file). Returns true + results, or false + error.
local function runInner(target, opts)
  opts = opts or {}
  local jail = opts.fs or M.jail(opts.root or "/var/sandbox/default", { quota = opts.quota })
  local timeout = opts.timeout or M.DEFAULT_TIMEOUT
  local memLimit = opts.memory or M.DEFAULT_MEMORY_KB
  local used = 0
  local sliceStart = os.clock()
  local baseMem = collectgarbage("count")
  local violation

  local function hook()
    local now = os.clock()
    local elapsed = used + (now - sliceStart)
    if elapsed > timeout then violation = "time limit exceeded (" .. timeout .. "s of running time)" end
    if collectgarbage("count") - baseMem > memLimit then violation = "memory limit exceeded (" .. memLimit .. " KB)" end
    if violation then error(violation, 0) end
  end
  local guard = { hook = hook, violation = function() return violation end }
  local env = M.environment({ fs = jail, allow = opts.allow, env = opts.env, guard = guard })

  local fn, err
  if type(target) == "function" then
    fn = target       -- a plain function keeps the globals it was written with: only text programs get the restricted environment
  elseif opts.source then
    fn, err = load(opts.source, "=sandbox", "t", env)
  else
    local h = fs.open(target, "r")
    if not h then return false, "cannot open " .. tostring(target) end
    local text = h.readAll()
    h.close()
    fn, err = load(text, "@" .. fs.getName(target), "t", env)
  end
  if not fn then return false, tostring(err) end

  local co = coroutine.create(fn)

  local args = opts.args or {}
  local filter
  local results = table.pack(nil)
  local first = true
  while true do
    sliceStart = os.clock()
    if debug and debug.sethook then debug.sethook(co, hook, "", M.HOOK_EVERY) end
    local res
    if first then
      res = table.pack(coroutine.resume(co, table.unpack(args)))
      first = false
    else
      res = table.pack(coroutine.resume(co, table.unpack(results, 1, results.n)))
    end
    used = used + (os.clock() - sliceStart)
    if not res[1] then
      return false, tostring(res[2])
    end
    if coroutine.status(co) == "dead" then
      return true, table.unpack(res, 2, res.n)
    end
    -- the program is waiting for an event: pass real events through until one matches its filter
    filter = res[2]
    local ev
    repeat
      ev = table.pack(os.pullEventRaw())
      if ev[1] == "terminate" then return false, "terminated" end
    until filter == nil or ev[1] == filter
    results = ev
  end
end

function M.run(target, opts)
  local startTerm = term.current()
  local res = table.pack(pcall(runInner, target, opts))
  if term.current() ~= startTerm then term.redirect(startTerm) end     -- whatever the program redirected, put it back
  if not res[1] then return false, tostring(res[2]) end
  return table.unpack(res, 2, res.n)
end

return M
