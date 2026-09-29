-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Tessera kernel: cooperative process scheduler + event router.
--
-- Processes are coroutines. Each gets its own terminal window (multishell-style); the kernel redirects `term` to the
-- process' window while it runs. Input events (keyboard/mouse/paste/terminate) go only to the focused process, every
-- other event is broadcast to processes whose filter matches — exactly the contract of os.pullEvent, so unmodified
-- CraftOS programs run under it. There is no preemption in CC:T; a process that never yields is killed by CC itself.
local loader = require("tsr.loader")
local util = require("tsr.util")
local log = require("tsr.log").get("kernel")

local K = {}

local procs = {}   -- pid -> process
local order = {}   -- pids in creation order
local nextPid = 1
local current = nil
local focus = nil
local rootTerm = nil
local running = false
local stopping = false
local exitAction = "craftos"
local stopHooks = {}
local mods = { alt = false, ctrl = false, shift = false }
local hotkeys = {}

-- input events only the focused process should see
local INPUT = {
  key = true, key_up = true, char = true, paste = true,
  mouse_click = true, mouse_up = true, mouse_drag = true, mouse_scroll = true,
}

---------------------------------------------------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------------------------------------------------

--- Set the terminal the kernel draws on (default: the current terminal). Call before spawning processes.
function K.init(opts)
  opts = opts or {}
  rootTerm = opts.term or term.current()
end

local function root()
  if not rootTerm then K.init() end
  return rootTerm
end

--- Kill everything and reset all kernel state (tests, recovery).
function K.reset()
  procs, order, nextPid, current, focus = {}, {}, 1, nil, nil
  running, stopping, exitAction, stopHooks = false, false, "craftos", {}
  mods = { alt = false, ctrl = false, shift = false }
  hotkeys = {}
end

---------------------------------------------------------------------------------------------------------------------
-- Processes
---------------------------------------------------------------------------------------------------------------------

local function removeFromOrder(pid)
  for i, p in ipairs(order) do
    if p == pid then table.remove(order, i) return end
  end
end

local function pickFocus()
  -- prefer a live session, most recently created first
  for i = #order, 1, -1 do
    local p = procs[order[i]]
    if p and p.spec.session then return p.pid end
  end
  for i = #order, 1, -1 do
    local p = procs[order[i]]
    if p and p.win then return p.pid end
  end
end

function K.setFocus(pid)
  local old = procs[focus]
  if old and old.win and old.win.setVisible and pid ~= focus then old.win.setVisible(false) end
  focus = pid
  local p = procs[pid]
  if p and p.win and p.win.setVisible then
    p.win.setVisible(true)
    if p.win.redraw then p.win.redraw() end
  end
  os.queueEvent("tsr_focus", pid)
end

local function finish(proc, ok, err)
  proc.status = "dead"
  proc.ok, proc.err = ok, err
  procs[proc.pid] = nil
  removeFromOrder(proc.pid)
  if ok or err == "Terminated" then
    log.debug("process %d (%s) exited", proc.pid, proc.name)
  else
    log.warn("process %d (%s) crashed: %s", proc.pid, proc.name, tostring(err))
    if proc.win and proc.win.write then
      pcall(function()
        proc.win.setTextColor(colors.red)
        proc.win.write("\n" .. tostring(proc.name) .. ": " .. tostring(err))
        proc.win.setTextColor(colors.white)
      end)
    end
  end
  if focus == proc.pid then
    focus = nil
    local nxt = pickFocus()
    if nxt then K.setFocus(nxt) end
  end
  os.queueEvent("tsr_proc_exit", proc.pid, ok, err)
end

local function resume(proc, ...)
  local prev = current
  current = proc
  local prevTerm
  if proc.win then prevTerm = term.redirect(proc.win) end
  local res = table.pack(coroutine.resume(proc.co, ...))
  if proc.win and prevTerm then term.redirect(prevTerm) end
  current = prev
  if not res[1] then
    finish(proc, false, res[2])
  elseif coroutine.status(proc.co) == "dead" then
    finish(proc, true, res[2])
  else
    proc.filter = res[2]
  end
end

--- Start a process. spec fields:
---   name (string), fn (function) | path (string, a Lua file), args (array),
---   window (default true; false = share the root terminal), term (use this terminal object instead of a window),
---   focus (bool: take input focus), session (bool: reachable with Alt+<n>), env (extra globals for `path` programs)
--- Returns pid, process   (or nil, error when `path` cannot be loaded).
function K.spawn(spec)
  local fn = spec.fn
  if not fn then
    if not spec.path then error("spawn: need fn or path", 2) end
    local env = setmetatable({}, { __index = loader.env })
    if spec.env then for k, v in pairs(spec.env) do env[k] = v end end
    local chunk, err = loadfile(spec.path, "t", env)
    if not chunk then return nil, err end
    fn = chunk
  end
  local pid = nextPid
  nextPid = nextPid + 1
  local win = spec.term
  if not win and spec.window ~= false then
    local w, h = root().getSize()
    win = window.create(root(), 1, 1, w, h, false)
  end
  local proc = {
    pid = pid, name = spec.name or ("proc" .. pid), co = coroutine.create(fn), win = win, spec = spec,
    parent = current and current.pid or nil, status = "ready", started = os.epoch and os.epoch("utc") or 0,
  }
  procs[pid] = proc
  order[#order + 1] = pid
  log.debug("spawn %d (%s)", pid, proc.name)
  if spec.focus then K.setFocus(pid) end
  resume(proc, table.unpack(spec.args or {}))
  return pid, proc
end

function K.get(pid) return procs[pid] end
function K.getFocus() return focus end
function K.current() return current and current.pid or nil end

--- Snapshot of the process table.
function K.list()
  local out = {}
  for _, pid in ipairs(order) do
    local p = procs[pid]
    if p then
      out[#out + 1] = { pid = pid, name = p.name, parent = p.parent, focused = pid == focus, filter = p.filter,
                        session = p.spec.session or false }
    end
  end
  return out
end

--- Deliver a terminate event (polite; the process may ignore it).
function K.terminate(pid)
  local p = procs[pid]
  if p then resume(p, "terminate") end
end

--- Kill a process immediately (no cleanup runs).
function K.kill(pid)
  local p = procs[pid]
  if p then finish(p, false, "killed") end
end

--- Block (from inside a process) until `pid` exits. Returns ok, err of the process.
function K.wait(pid)
  while procs[pid] do
    local _, p, ok, err = os.pullEvent("tsr_proc_exit")
    if p == pid then return ok, err end
  end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Hotkeys
---------------------------------------------------------------------------------------------------------------------

--- Bind a global hotkey, e.g. K.hotkey("alt+q", fn). The key event is consumed when a hotkey fires.
function K.hotkey(combo, fn) hotkeys[combo:lower()] = fn end

local function comboFor(code)
  local name = keys.getName(code)
  if not name then return nil end
  local parts = {}
  if mods.ctrl then parts[#parts + 1] = "ctrl" end
  if mods.alt then parts[#parts + 1] = "alt" end
  if mods.shift then parts[#parts + 1] = "shift" end
  parts[#parts + 1] = name
  return table.concat(parts, "+")
end

local NUMS = { one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9 }

local function trackMods(ev)
  local name, code = ev[1], ev[2]
  local down = name == "key"
  local kname = keys.getName(code)
  if kname == "leftAlt" or kname == "rightAlt" then mods.alt = down
  elseif kname == "leftCtrl" or kname == "rightCtrl" then mods.ctrl = down
  elseif kname == "leftShift" or kname == "rightShift" then mods.shift = down end
end

local function sessions()
  local out = {}
  for _, pid in ipairs(order) do
    local p = procs[pid]
    if p and p.spec.session then out[#out + 1] = pid end
  end
  return out
end

--- Returns true when the event was consumed by a hotkey.
local function handleHotkey(ev)
  if ev[1] ~= "key" or ev[3] then return false end -- ev[3] = key repeat
  local combo = comboFor(ev[2])
  if not combo then return false end
  local fn = hotkeys[combo]
  if fn then
    local ok, err = pcall(fn)
    if not ok then log.warn("hotkey %s failed: %s", combo, tostring(err)) end
    return true
  end
  local n = combo:match("^alt%+(%a+)$")
  if n and NUMS[n] then
    local list = sessions()
    if list[NUMS[n]] then K.setFocus(list[NUMS[n]]) return true end
  end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- Event dispatch and main loop
---------------------------------------------------------------------------------------------------------------------

local function deliver(proc, ev)
  local f = proc.filter
  if f == nil or f == ev[1] or ev[1] == "terminate" then
    resume(proc, table.unpack(ev, 1, ev.n))
  end
end

local function dispatch(ev)
  local name = ev[1]
  if name == "key" or name == "key_up" then
    trackMods(ev)
    if handleHotkey(ev) then return end
  end
  if INPUT[name] or name == "terminate" then
    local p = procs[focus]
    if p then deliver(p, ev) end
    return
  end
  if name == "term_resize" then
    local w, h = root().getSize()
    for _, pid in ipairs(order) do
      local p = procs[pid]
      if p and p.win and p.win.reposition and not p.spec.term then pcall(p.win.reposition, 1, 1, w, h) end
    end
  end
  local snapshot = util.copy(order)
  for _, pid in ipairs(snapshot) do
    local p = procs[pid]
    if p then deliver(p, ev) end
  end
end

--- Register a function to run when the kernel stops (before processes are killed).
function K.onStop(fn) stopHooks[#stopHooks + 1] = fn end

--- Ask the main loop to end. action: "craftos" (return to plain CraftOS), "shutdown" or "reboot".
function K.stop(action)
  exitAction = action or "craftos"
  stopping = true
  os.queueEvent("tsr_stop") -- wakes the loop if it is blocked waiting for an event
end

function K.isRunning() return running end

--- Run the scheduler until every process has exited or K.stop() is called. Returns the exit action.
function K.run()
  running = true
  while not stopping and next(procs) do
    local ev = table.pack(os.pullEventRaw())
    dispatch(ev)
  end
  running, stopping = false, false
  for _, fn in ipairs(stopHooks) do pcall(fn) end
  for _, pid in ipairs(util.copy(order)) do K.kill(pid) end
  return exitAction
end

return K
