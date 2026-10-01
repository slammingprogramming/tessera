-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Phone-style shell for pocket computers (about 26 x 20 characters).
--   row 1        status bar: clock, network, notification count
--   rows 2..h-1  the current screen (a widget tree)
--   row h        navigation: [<] back   [o] home   [=] notifications
-- Apps are files in /usr/share/mobile/*.lua returning { name, icon (one character), build = function(root, phone) ... end }.
-- A screen pushed with phone:push(title, build) gets the content area; `phone:pop()` goes back, `phone:home()` clears the stack.
local theme = require("tsr.gui.theme")
local W = require("tsr.gui.widgets")

local M = {}

M.APP_DIR = "/usr/share/mobile"

---------------------------------------------------------------------------------------------------------------------
-- Tile: a big touch target
---------------------------------------------------------------------------------------------------------------------

local Tile = W.class(W.Widget)
Tile.focusable = true

function M.tile(props)
  local t = setmetatable({}, Tile)
  for k, v in pairs(props) do t[k] = v end
  t.x, t.y, t.w, t.h = t.x or 1, t.y or 1, t.w or 12, t.h or 3
  t.visible, t.enabled, t.children = true, true, {}
  return t
end

function Tile:paint(t)
  local th = theme.get()
  local ax, ay = self:abs()
  local active = self.pressed or self:hasFocus()
  local bg = active and th.accent or th.button
  local fg = active and th.buttonActiveText or th.buttonText
  W.fill(t, ax, ay, self.w, self.h, bg)
  local icon = self.icon or "*"
  local label = tostring(self.text):sub(1, self.w - 2)
  W.put(t, ax + math.floor((self.w - 1) / 2), ay, icon, fg, bg)
  W.put(t, ax + math.floor((self.w - #label) / 2), ay + 1, label, fg, bg)
  if self.badge and self.badge > 0 then
    local b = tostring(math.min(self.badge, 99))
    W.put(t, ax + self.w - #b - 1, ay, b, th.danger, bg)
  end
end

function Tile:onMouse(kind, x, y)
  if kind == "down" then self.pressed = true self:invalidate() return true
  elseif kind == "up" then
    local was = self.pressed
    self.pressed = false
    self:invalidate()
    if was and x >= 1 and x <= self.w and y >= 1 and y <= self.h and self.onClick then self.onClick(self) end
    return true
  end
  return false
end

function Tile:onKey(key)
  if (key == keys.enter or key == keys.space) and self.onClick then self.onClick(self) return true end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- Phone
---------------------------------------------------------------------------------------------------------------------

local Phone = {}
Phone.__index = Phone

--- opts: term, apps (replaces APP_DIR), notify (module, default tsr.notify), now (function -> "HH:MM"), signal (function -> bool)
function M.new(opts)
  opts = opts or {}
  local t = opts.term or term.current()
  local w, h = t.getSize()
  local self = setmetatable({
    t = t, w = w, h = h, stack = {}, apps = opts.apps, exitAction = nil,
    notify = opts.notify,
    now = opts.now or function() return textutils.formatTime(os.time("local"), true) end,
    signal = opts.signal or function() return peripheral.find("modem") ~= nil end,
    page = 1,
  }, Phone)
  if not self.notify then
    local ok, mod = pcall(require, "tsr.notify")
    self.notify = ok and mod or { unread = function() return 0 end, list = function() return {} end, markRead = function() end, clear = function() end }
  end
  self.content = window.create(t, 1, 2, w, h - 2, false)
  self.root = W.root(self.content)
  self.navRoot = W.root(window.create(t, 1, h, w, 1, false))
  if not self.apps then self:loadApps() end
  self:buildNav()
  return self
end

function Phone:loadApps(dir)
  dir = dir or M.APP_DIR
  local apps = {}
  if fs.isDir(dir) then
    local names = fs.list(dir)
    table.sort(names)
    for _, f in ipairs(names) do
      if f:match("%.lua$") then
        local chunk = loadfile(dir .. "/" .. f, "t", setmetatable({ require = require }, { __index = _G }))
        local ok, app = false, nil
        if chunk then ok, app = pcall(chunk) end
        if ok and type(app) == "table" and app.name and app.build then
          app.id = f:gsub("%.lua$", "")
          apps[#apps + 1] = app
        end
      end
    end
  end
  table.sort(apps, function(a, b)
    if (a.order or 50) ~= (b.order or 50) then return (a.order or 50) < (b.order or 50) end
    return a.name < b.name
  end)
  self.apps = apps
  return #apps
end

function Phone:buildNav()
  local nav = self.navRoot
  local third = math.floor(self.w / 3)
  local function btn(x, w, text, fn)
    nav:add(W.button({ x = x, y = 1, w = w, text = text, onClick = fn }))
  end
  btn(1, third, "<", function() self:pop() end)
  btn(third + 1, third, "o", function() self:home() end)
  btn(2 * third + 1, self.w - 2 * third, "=", function() self:openNotifications() end)
end

function Phone:current() return self.stack[#self.stack] end

local function clearRoot(root)
  root:clear()
  root.focused = nil
  root.capture = nil
end

function Phone:show(screen)
  clearRoot(self.root)
  self.root.dirty = true
  screen.build(self.root, self)
end

--- Open a screen on top of the current one. build(root, phone) fills the content area.
function Phone:push(title, build)
  local screen = { title = title, build = build }
  self.stack[#self.stack + 1] = screen
  self:show(screen)
end

function Phone:pop()
  if #self.stack > 1 then
    self.stack[#self.stack] = nil
    self:show(self.stack[#self.stack])
    return true
  end
  return false
end

function Phone:home()
  self.stack = {}
  self:push("Home", function(root) self:buildHome(root) end)
end

function Phone:openApp(app)
  self:push(app.name, function(root, phone) app.build(root, phone) end)
end

function Phone:openNotifications()
  local app = self:builtin("notifications")
  if app then self:openApp(app) end
end

function Phone:builtin(id)
  for _, a in ipairs(self.apps) do if a.id == id then return a end end
end

local TILE_W = 12
local TILE_H = 3

--- App tiles, two per row, paged when there are more than fit.
function Phone:buildHome(root)
  local colW = math.floor(self.w / 2)
  local rows = math.max(1, math.floor((self.h - 3) / (TILE_H + 0)))
  local perPage = rows * 2
  local pages = math.max(1, math.ceil(#self.apps / perPage))
  self.page = math.min(self.page, pages)
  local first = (self.page - 1) * perPage
  for i = 1, perPage do
    local app = self.apps[first + i]
    if not app then break end
    local col = (i - 1) % 2
    local row = math.floor((i - 1) / 2)
    root:add(M.tile({
      x = col * colW + 1, y = row * TILE_H + 1, w = colW - 1, h = TILE_H, text = app.name, icon = app.icon,
      badge = (app.id == "notifications") and self.notify.unread() or nil,
      onClick = function() self:openApp(app) end,
    }))
  end
  if pages > 1 then
    root:add(W.label({ x = 1, y = self.h - 2, w = self.w, text = ("page %d/%d (scroll)"):format(self.page, pages), align = "center", role = "textDim" }))
  end
  self.pages = pages
end

function Phone:runProgram(line)
  -- hand the whole terminal to a program, then come back
  local t = self.t
  t.setBackgroundColor(colors.black)
  t.setTextColor(colors.white)
  t.clear()
  t.setCursorPos(1, 1)
  local okExec, exec = pcall(require, "tsr.shell.exec")
  if okExec then
    exec.new({ parentShell = rawget(_G, "shell") }):runLine(line)
  elseif rawget(_G, "shell") then
    shell.run(line)
  end
  print()
  t.setTextColor(colors.lightGray)
  print("Press any key to return")
  os.pullEvent("key")
  self:redrawAll()
end

---------------------------------------------------------------------------------------------------------------------
-- Drawing and events
---------------------------------------------------------------------------------------------------------------------

function Phone:drawStatus()
  local th, t = theme.get(), self.t
  W.fill(t, 1, 1, self.w, 1, th.taskbar)
  local clock = self.now()
  W.put(t, 1, 1, " " .. clock, th.taskbarText, th.taskbar)
  local net = self.signal() and "net" or "---"
  local unread = self.notify.unread()
  local right = net .. (unread > 0 and (" !" .. unread) or "") .. " "
  W.put(t, self.w - #right + 1, 1, right, unread > 0 and th.danger or th.taskbarText, th.taskbar)
  local screen = self:current()
  if screen and screen.title and screen.title ~= "Home" then
    local title = screen.title:sub(1, self.w - #clock - #right - 4)
    W.put(t, math.floor((self.w - #title) / 2) + 1, 1, title, th.taskbarText, th.taskbar)
  end
end

function Phone:redrawAll()
  self.root.dirty = true
  self.content.setBackgroundColor(theme.get().window)
  self.content.clear()
  self.root:render()
  self.navRoot:render()
  for y = 1, self.h - 2 do
    local text, fg, bg = self.content.getLine(y)
    self.t.setCursorPos(1, y + 1)
    self.t.blit(text, fg, bg)
  end
  local ntext, nfg, nbg = self.navRoot.t.getLine(1)
  self.t.setCursorPos(1, self.h)
  self.t.blit(ntext, nfg, nbg)
  self:drawStatus()
  -- text cursor of a focused input
  local f = self.root.focused
  if f and f.cursorPos then
    local cx, cy = f:cursorPos()
    self.t.setCursorPos(cx, cy + 1)
    self.t.setTextColor(theme.get().inputText)
    self.t.setCursorBlink(true)
  else
    self.t.setCursorBlink(false)
  end
end

--- Handle one event. Mouse coordinates on the content area are shifted up by the status bar.
function Phone:event(name, a, b, c)
  if name == "mouse_click" or name == "mouse_up" or name == "mouse_drag" or name == "mouse_scroll" then
    if c == self.h then
      self.navRoot:dispatch(name, a, b, 1)
    elseif c >= 2 and c <= self.h - 1 then
      if name == "mouse_scroll" and self:current() and self:current().title == "Home" and self.pages and self.pages > 1 then
        self.page = math.max(1, math.min(self.pages, self.page + a))
        self:show(self:current())
      else
        self.root:dispatch(name, a, b, c - 1)
      end
    end
  elseif name == "key" or name == "key_up" or name == "char" or name == "paste" then
    if name == "key" and a == keys.backspace and not (self.root.focused and self.root.focused.cursorPos) then
      self:pop()
    elseif name == "key" and a == keys.home then
      self:home()
    else
      self.root:dispatch(name, a, b)
    end
  end
end

function Phone:run()
  self:home()
  local clock = self.now()
  self:redrawAll()
  local timer = os.startTimer(1)
  while not self.exitAction do
    local ev = table.pack(os.pullEventRaw())
    if ev[1] == "timer" and ev[2] == timer then
      timer = os.startTimer(1)
      if self.now() ~= clock then clock = self.now() end
      local screen = self:current()
      if screen and screen.title == "Home" then self:show(screen) end
    elseif ev[1] == "tsr_notify" then
      local screen = self:current()
      if screen and screen.title == "Home" then self:show(screen) end
    elseif ev[1] == "terminate" then
      -- a pocket computer should not be killable by accident: ignore Ctrl+T at the phone level
    else
      self:event(table.unpack(ev, 1, ev.n))
    end
    self:redrawAll()
  end
  return self.exitAction
end

--- Start the phone interface on the current terminal. Returns "shell" | "reboot" | "shutdown".
function M.start(opts)
  opts = opts or {}
  local config = require("tsr.config")
  local t = opts.term or term.current()
  theme.set(config.get("ui.theme", "dark"), t.isColor())
  local phone = M.new(opts)
  local action = phone:run()
  t.setBackgroundColor(colors.black)
  t.setTextColor(colors.white)
  t.clear()
  t.setCursorPos(1, 1)
  return action
end

return M
