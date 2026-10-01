-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Window manager / compositor for the desktop.
--
-- Every window owns an invisible CraftOS window object (win.term). Programs and widgets draw into it; the manager composes all
-- windows onto the screen itself, bottom to top, together with title bars. Two kinds of windows:
--   widget windows   opts.build(root, win)   build widgets on `root` (a tsr.gui.widgets root); the manager feeds it events
--   process windows  opts.run(win)           a function run as a kernel process whose terminal is the window; keyboard and
--                                            (translated) mouse events are forwarded to it with kernel.send
-- Events go in through wm:event(name, ...); wm:tick() notices changes made by processes and recomposes.
local theme = require("tsr.gui.theme")
local W = require("tsr.gui.widgets")

local M = {}

local WM = {}
WM.__index = WM

--- opts: term (screen), top (first row available to windows, default 1), bottom (last row, default screen height - 1),
--- kernel (default tsr.kernel)
function M.new(opts)
  opts = opts or {}
  local t = opts.term or term.current()
  local w, h = t.getSize()
  local self = setmetatable({
    t = t, w = w, h = h, top = opts.top or 1, bottom = opts.bottom or (h - 1),
    windows = {}, nextId = 1, drag = nil, focused = nil, onChange = opts.onChange,
    kernel = opts.kernel or require("tsr.kernel"),
    signature = nil, cascade = 0,
  }, WM)
  return self
end

function WM:resizeScreen(w, h, bottom)
  self.w, self.h = w, h
  self.bottom = bottom or (h - 1)
  for _, win in ipairs(self.windows) do
    if win.maximized then self:place(win, 1, self.top + 1, self.w, self.bottom - self.top) end
    self:clamp(win)
  end
  self.signature = nil
end

---------------------------------------------------------------------------------------------------------------------
-- Windows
---------------------------------------------------------------------------------------------------------------------

function WM:find(id)
  for _, win in ipairs(self.windows) do if win.id == id then return win end end
end

function WM:findByPid(pid)
  for _, win in ipairs(self.windows) do if win.pid == pid then return win end end
end

function WM:list() return self.windows end

--- Keep the title bar on screen and inside the window area.
function WM:clamp(win)
  win.x = math.max(1 - win.w + 4, math.min(win.x, self.w - 3))
  win.y = math.max(self.top + 1, math.min(win.y, self.bottom - 0))
end

--- Move/resize a window (content rectangle) and tell whoever is inside.
function WM:place(win, x, y, w, h)
  local resized = w ~= win.w or h ~= win.h
  win.x, win.y, win.w, win.h = x, y, w, h
  win.term.reposition(x, y, w, h)
  if resized then
    if win.root then win.root.w, win.root.h = w, h win.root.dirty = true end
    if win.pid then self.kernel.send(win.pid, "term_resize") end
    if win.onResize then win.onResize(w, h) end
  end
  self.signature = nil
end

--- Open a window. opts: title, w, h (content size), x, y, build | run, resizable (default true), onClose, icon.
--- Returns the window table (id, title, x, y, w, h, term, root | pid).
function WM:open(opts)
  local w = math.max(12, math.min(opts.w or 30, self.w))
  local h = math.min(opts.h or 10, self.bottom - self.top - 1)
  self.cascade = (self.cascade + 2) % 12
  local x = opts.x or math.max(1, math.floor((self.w - w) / 2) + 1 - 6 + self.cascade)
  local y = opts.y or math.max(self.top + 1, math.floor((self.top + self.bottom - h) / 2) + 1 - 2 + self.cascade / 2)
  x, y = math.floor(x), math.floor(y)
  local screenTerm = self.t
  local win = {
    id = self.nextId, title = opts.title or "Window", x = x, y = y, w = w, h = h, resizable = opts.resizable ~= false,
    onClose = opts.onClose, minimized = false, maximized = false,
  }
  self.nextId = self.nextId + 1
  win.term = window.create(screenTerm, x, y, w, h, false)
  win.term.setBackgroundColor(theme.get().window)
  win.term.setTextColor(theme.get().windowText)
  win.term.clear()
  win.term.setCursorPos(1, 1)
  self:clamp(win)
  self.windows[#self.windows + 1] = win

  if opts.build then
    win.root = W.root(win.term)
    opts.build(win.root, win)
    win.root:render()
  elseif opts.run then
    local pid, err = self.kernel.spawn({
      name = win.title, term = win.term, daemon = true,
      fn = function() opts.run(win) end,
    })
    if not pid then
      self:remove(win)
      return nil, err
    end
    win.pid = pid
  end
  self:focus(win)
  self.signature = nil
  return win
end

function WM:remove(win)
  for i, other in ipairs(self.windows) do
    if other == win then table.remove(self.windows, i) break end
  end
  if self.focused == win then
    self.focused = nil
    for i = #self.windows, 1, -1 do
      if not self.windows[i].minimized then self.focused = self.windows[i] break end
    end
  end
  self.signature = nil
end

function WM:close(id)
  local win = type(id) == "table" and id or self:find(id)
  if not win then return false end
  if win.onClose and win.onClose(win) == false then return false end
  if win.pid then
    local pid = win.pid
    win.pid = nil
    self.kernel.terminate(pid)
    if self.kernel.get(pid) then self.kernel.kill(pid) end
  end
  self:remove(win)
  return true
end

function WM:raise(win)
  for i, other in ipairs(self.windows) do
    if other == win then table.remove(self.windows, i) break end
  end
  self.windows[#self.windows + 1] = win
  self.signature = nil
end

function WM:focus(win)
  if win and win.minimized then win.minimized = false end
  self.focused = win
  if win then self:raise(win) end
  self.signature = nil
end

function WM:minimize(win)
  win.minimized = true
  if self.focused == win then
    self.focused = nil
    for i = #self.windows, 1, -1 do
      if not self.windows[i].minimized then self.focused = self.windows[i] break end
    end
  end
  self.signature = nil
end

function WM:toggleMaximize(win)
  if win.maximized then
    local r = win.restore
    win.maximized = false
    self:place(win, r.x, r.y, r.w, r.h)
  else
    win.restore = { x = win.x, y = win.y, w = win.w, h = win.h }
    win.maximized = true
    self:place(win, 1, self.top + 1, self.w, self.bottom - self.top)
  end
end

function WM:closeAll()
  for i = #self.windows, 1, -1 do self:close(self.windows[i]) end
end

---------------------------------------------------------------------------------------------------------------------
-- Composition
---------------------------------------------------------------------------------------------------------------------

local function titleBar(win, focused)
  local th = theme.get()
  local fg = focused and th.titleActiveText or th.titleInactiveText
  local bg = focused and th.titleActive or th.titleInactive
  local text = " " .. win.title
  local buttons = " _ + x "
  if #text > win.w - #buttons then text = text:sub(1, math.max(0, win.w - #buttons)) end
  local line = text .. string.rep(" ", math.max(0, win.w - #text - #buttons)) .. buttons
  return line:sub(1, win.w), fg, bg
end

--- Button cell ranges in the title bar (relative to window x): minimize, maximize, close.
local function buttonAt(win, relX)
  local start = win.w - 7 + 1            -- first cell of " _ + x "
  if relX < start then return nil end
  local i = relX - start + 1             -- 1..7
  if i == 2 then return "minimize" elseif i == 4 then return "maximize" elseif i == 6 then return "close" end
  return nil
end

--- Draw the desktop background and every visible window.
function WM:compose()
  local t, th = self.t, theme.get()
  local screenTerm = t
  -- background (only the window area)
  screenTerm.setBackgroundColor(th.desktop)
  for y = self.top, self.bottom do
    screenTerm.setCursorPos(1, y)
    screenTerm.write(string.rep(" ", self.w))
  end
  for _, win in ipairs(self.windows) do
    if not win.minimized then
      local focused = win == self.focused
      local text, fg, bg = titleBar(win, focused)
      local ty = win.y - 1
      if ty >= self.top then
        screenTerm.setCursorPos(win.x, ty)
        screenTerm.setTextColor(fg)
        screenTerm.setBackgroundColor(bg)
        screenTerm.write(text)
      end
      for row = 1, win.h do
        local y = win.y + row - 1
        if y <= self.bottom then
          local line, lfg, lbg = win.term.getLine(row)
          if line then
            local x0, from, to = win.x, 1, win.w
            if x0 < 1 then from = 2 - x0 x0 = 1 end
            if x0 + (to - from) > self.w then to = from + self.w - x0 end
            screenTerm.setCursorPos(x0, y)
            screenTerm.blit(line:sub(from, to), lfg:sub(from, to), lbg:sub(from, to))
          end
        end
      end
    end
  end
  -- text cursor of the focused window
  local f = self.focused
  if f and not f.minimized and f.term.getCursorBlink and f.term.getCursorBlink() then
    local cx, cy = f.term.getCursorPos()
    if cx >= 1 and cx <= f.w and cy >= 1 and cy <= f.h then
      screenTerm.setCursorPos(f.x + cx - 1, f.y + cy - 1)
      screenTerm.setTextColor(f.term.getTextColor and f.term.getTextColor() or th.windowText)
      screenTerm.setCursorBlink(true)
      return
    end
  end
  screenTerm.setCursorBlink(false)
end

--- A cheap fingerprint of everything that is on screen from the window manager.
function WM:fingerprint()
  local parts = { tostring(self.focused and self.focused.id) }
  for _, win in ipairs(self.windows) do
    parts[#parts + 1] = ("%d:%d,%d,%d,%d,%s,%s"):format(win.id, win.x, win.y, win.w, win.h, tostring(win.minimized), win.title)
    if not win.minimized then
      for row = 1, win.h do
        local line, fg, bg = win.term.getLine(row)
        parts[#parts + 1] = (line or "") .. (fg or "") .. (bg or "")
      end
      parts[#parts + 1] = tostring(win.term.getCursorBlink and win.term.getCursorBlink())
      local cx, cy = win.term.getCursorPos()
      parts[#parts + 1] = cx .. "," .. cy
    end
  end
  return table.concat(parts, "|")
end

--- Give windows that want periodic updates (win.onTick) a chance to refresh. Called about once a second.
function WM:slowTick()
  for _, win in ipairs(self.windows) do
    if win.onTick then
      local ok = pcall(win.onTick)
      if ok and win.root then win.root:render() end
    end
  end
end

--- Recompose when something changed. Returns true when it redrew.
function WM:tick(force)
  local sig = self:fingerprint()
  if force or sig ~= self.signature then
    self.signature = sig
    self:compose()
    if self.onChange then self.onChange() end
    return true
  end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------------------------------------------------

--- The topmost visible window whose content or title bar contains the screen point. Returns win, "title" | "content".
function WM:windowAt(px, py)
  for i = #self.windows, 1, -1 do
    local win = self.windows[i]
    if not win.minimized then
      if px >= win.x and px < win.x + win.w then
        if py >= win.y and py < win.y + win.h then return win, "content" end
        if py == win.y - 1 and py >= self.top then return win, "title" end
      end
    end
  end
end

local function forward(self, win, name, ...)
  if win.root then
    win.root:dispatch(name, ...)
    win.root:render()
  elseif win.pid then
    self.kernel.send(win.pid, name, ...)
  end
end

--- Handle one event. Returns true if the window manager used it.
function WM:event(name, a, b, c)
  if name == "mouse_click" then
    local win, part = self:windowAt(b, c)
    if not win then return false end
    if win ~= self.focused or self.windows[#self.windows] ~= win then self:focus(win) end
    if part == "title" then
      local button = buttonAt(win, b - win.x + 1)
      if button == "close" then self:close(win)
      elseif button == "minimize" then self:minimize(win)
      elseif button == "maximize" then self:toggleMaximize(win)
      else
        local now = os.clock()
        if win.lastTitleClick and now - win.lastTitleClick < 0.5 then
          self:toggleMaximize(win)
          win.lastTitleClick = nil
        else
          win.lastTitleClick = now
          if not win.maximized then self.drag = { win = win, dx = b - win.x, dy = c - win.y } end
        end
      end
      self.signature = nil
      return true
    end
    self.pressed = { win = win, button = a }
    forward(self, win, "mouse_click", a, b - win.x + 1, c - win.y + 1)
    return true
  elseif name == "mouse_drag" then
    if self.drag then
      local d = self.drag
      self:place(d.win, b - d.dx, c - d.dy, d.win.w, d.win.h)
      self:clamp(d.win)
      d.win.term.reposition(d.win.x, d.win.y)
      return true
    elseif self.pressed then
      local win = self.pressed.win
      forward(self, win, "mouse_drag", a, b - win.x + 1, c - win.y + 1)
      return true
    end
  elseif name == "mouse_up" then
    if self.drag then self.drag = nil return true end
    if self.pressed then
      local win = self.pressed.win
      self.pressed = nil
      forward(self, win, "mouse_up", a, b - win.x + 1, c - win.y + 1)
      return true
    end
  elseif name == "mouse_scroll" then
    local win, part = self:windowAt(b, c)
    if win and part == "content" then forward(self, win, "mouse_scroll", a, b - win.x + 1, c - win.y + 1) return true end
  elseif name == "key" or name == "key_up" or name == "char" or name == "paste" then
    local win = self.focused
    if win then forward(self, win, name, a, b) return true end
  elseif name == "terminate" then
    local win = self.focused
    if win and win.pid then self.kernel.send(win.pid, "terminate") return true end
  elseif name == "tsr_proc_exit" then
    local win = self:findByPid(a)
    if win then
      win.pid = nil
      self:remove(win)
      return true
    end
  end
  return false
end

return M
