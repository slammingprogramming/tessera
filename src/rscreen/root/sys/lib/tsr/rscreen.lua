-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Remote screen (VNC-like for terminals).
--   rview <peer>            show the other computer's screen here and send it your keyboard and mouse (F12 leaves)
--   rscreen allow|deny <peer> | allowed      who may watch and control THIS computer (nobody, until you allow them)
-- Under Tessera the focused session's window is shared; elsewhere, the computer's terminal. Only the lines that changed are
-- sent. Input travels encrypted. Whoever is allowed can type as you: treat `rscreen allow` like handing over the keyboard.
local vfs = require("tsr.vfs")

local M = {}

M.ALLOW_PATH = "/etc/tsr/rscreen.allow"
M.POLL = 0.25
M.deliver = function(...) os.queueEvent(...) end     -- where remote input goes (tests replace it)
M.MAX_EVENTS = 30

local INPUT_EVENTS = {
  char = 1, key = 2, key_up = 1, paste = 1, mouse_click = 3, mouse_up = 3, mouse_drag = 3, mouse_scroll = 3,
}

---------------------------------------------------------------------------------------------------------------------
-- Server
---------------------------------------------------------------------------------------------------------------------

function M.allowed() return vfs.readTable(M.ALLOW_PATH) or {} end

local function isAllowed(peer)
  for _, n in ipairs(M.allowed()) do if n == peer.name then return true end end
  return false
end

--- The window to share: the focused Tessera session, else the current terminal. Tests can replace this function.
function M.source()
  local okK, kernel = pcall(require, "tsr.kernel")
  if okK and kernel.isRunning and kernel.isRunning() then
    local proc = kernel.get(kernel.getFocus())
    if proc and proc.win and proc.win.getLine then return proc.win end
  end
  return term.current()
end

--- What is on `win` right now.
function M.snapshot(win)
  local w, h = win.getSize()
  local lines = {}
  for y = 1, h do
    local t, fg, bg = win.getLine(y)
    lines[y] = { t, fg, bg }
  end
  local cx, cy = win.getCursorPos()
  return { w = w, h = h, cx = cx, cy = cy, blink = win.getCursorBlink and win.getCursorBlink() or false, lines = lines }
end

local last = {}    -- peer id -> the snapshot that peer already has

--- Changed lines since the last frame sent to `peerId` (all of them when `full` or the size changed).
function M.diff(peerId, snap, full)
  local prev = last[peerId]
  local out = { w = snap.w, h = snap.h, cx = snap.cx, cy = snap.cy, blink = snap.blink, lines = {} }
  local count = 0
  for y = 1, snap.h do
    local l = snap.lines[y]
    local p = prev and prev.lines[y]
    if full or not prev or prev.w ~= snap.w or prev.h ~= snap.h or not p or p[1] ~= l[1] or p[2] ~= l[2] or p[3] ~= l[3] then
      out.lines[y] = l
      count = count + 1
    end
  end
  out.changed = count
  last[peerId] = snap
  return out
end

function M.forget() last = {} end

--- Register the "screen" service on `node`.
function M.serve(node)
  node:serve("screen", function(from, method, a)
    if method == "frame" then
      return M.diff(from, M.snapshot(M.source()), type(a) == "table" and a.full)
    elseif method == "input" then
      if type(a) ~= "table" or type(a.events) ~= "table" then error("bad request", 0) end
      local n = 0
      for _, ev in ipairs(a.events) do
        if n >= M.MAX_EVENTS then break end
        local want = type(ev) == "table" and INPUT_EVENTS[ev[1]]
        if want then
          local ok = true
          for i = 2, want + 1 do
            local t = type(ev[i])
            if t ~= "string" and t ~= "number" and t ~= "boolean" then ok = false end
          end
          if ok then
            M.deliver(table.unpack(ev, 1, want + 1))
            n = n + 1
          end
        end
      end
      return n
    end
    error("unknown method " .. tostring(method), 0)
  end, { allow = isAllowed })
end

---------------------------------------------------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------------------------------------------------

--- Draw a frame on terminal `t` (a term or window object). `state` remembers the last full set of lines so unchanged lines stay.
function M.render(t, frame, state)
  state = state or {}
  state.lines = state.lines or {}
  for y, l in pairs(frame.lines) do state.lines[y] = l end
  local w, h = t.getSize()
  for y = 1, math.min(frame.h, h) do
    local l = state.lines[y]
    if l then
      local text, fg, bg = l[1], l[2], l[3]
      if #text > w then text, fg, bg = text:sub(1, w), fg:sub(1, w), bg:sub(1, w) end
      t.setCursorPos(1, y)
      t.blit(text, fg, bg)
    end
  end
  t.setCursorPos(math.min(frame.cx, w), math.min(frame.cy, h))
  t.setCursorBlink(frame.blink and true or false)
  return state
end

--- Fetch one frame. Returns the frame or nil + error.
function M.fetch(node, peer, full)
  return node:call(peer, "screen", "frame", { full = full }, { timeout = 3 })
end

function M.sendInput(node, peer, events)
  return node:call(peer, "screen", "input", { events = events }, { timeout = 3, encrypt = true })
end

--- The viewer loop. opts: term (default current), exitKey (default keys.f12), maxFrames (tests).
function M.view(node, peer, opts)
  opts = opts or {}
  local t = opts.term or term.current()
  local exitKey = opts.exitKey or keys.f12
  local state = {}
  local pending, done, err = {}, false, nil
  local frames = 0

  local first, e = M.fetch(node, peer, true)
  if not first then return nil, e end
  M.render(t, first, state)

  parallel.waitForAny(
    function()      -- keep the picture up to date
      while not done do
        sleep(M.POLL)
        local frame, ferr = M.fetch(node, peer, false)
        if frame then
          M.render(t, frame, state)
          frames = frames + 1
          if opts.maxFrames and frames >= opts.maxFrames then done = true return end
        else
          err = ferr
          done = true
          return
        end
      end
    end,
    function()      -- forward input
      while not done do
        local ev = table.pack(os.pullEventRaw())
        if ev[1] == "key" and ev[2] == exitKey then done = true return end
        if INPUT_EVENTS[ev[1]] then
          pending[#pending + 1] = { table.unpack(ev, 1, INPUT_EVENTS[ev[1]] + 1) }
          if #pending >= 1 then
            local batch = pending
            pending = {}
            M.sendInput(node, peer, batch)
          end
        end
      end
    end)
  return not err, err
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

--- rscreen allow|deny <peer> | allowed ; rview <peer>
function M.run(args, io, node)
  io = io or defaultIO()
  node = node or require("tsr.net").default()
  local cmd = args[1]
  if cmd == "allow" or cmd == "deny" then
    if not args[2] then io.err("usage: rscreen " .. cmd .. " <peer name>") return false end
    local kept = {}
    for _, n in ipairs(M.allowed()) do if n ~= args[2] then kept[#kept + 1] = n end end
    if cmd == "allow" then kept[#kept + 1] = args[2] end
    vfs.writeTable(M.ALLOW_PATH, kept)
    io.say(cmd == "allow" and (args[2] .. " may now watch and control this screen.") or (args[2] .. " may no longer.") )
    return true
  elseif cmd == "allowed" then
    local list = M.allowed()
    if #list == 0 then io.say("Nobody may watch this computer.") end
    for _, n in ipairs(list) do io.say(n) end
    return true
  end
  io.err("usage: rscreen allow|deny <peer> | rscreen allowed   (to watch another computer: rview <peer>)")
  return false
end

function M.main(args) return M.run(args) end

function M.viewMain(args)
  if not args[1] then print("usage: rview <peer>   (F12 leaves)") return false end
  term.clear()
  local ok, err = M.view(require("tsr.net").default(), tonumber(args[1]) or args[1])
  term.setCursorBlink(false)
  term.setCursorPos(1, 1)
  term.clear()
  if not ok then printError(tostring(err)) end
  return ok
end

--- The rscreend service.
function M.daemon()
  M.serve(require("tsr.net").default())
  while true do os.pullEvent("rscreen_never") end
end

return M
