-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The Tessera desktop: window area, taskbar (start button, one button per window, clock) and the start menu.
-- Applications are described by files in /usr/share/applications/*.lua, each returning
--   { name = "Files", category = "Accessories", order = 10, w = 44, h = 15,
--     build = function(root, win, desktop) ... end }          -- a widget app
--   { name = "Terminal", run = function(win, desktop) ... end }  -- a process app (window terminal = win.term)
--   { name = "Editor", program = "edit" }                        -- run a command line in a shell inside a window
local theme = require("tsr.gui.theme")
local W = require("tsr.gui.widgets")
local WM = require("tsr.gui.wm")

local M = {}

M.APP_DIR = "/usr/share/applications"

local Desktop = {}
Desktop.__index = Desktop

--- opts: term, kernel, apps (replaces the files in APP_DIR), now (function -> "HH:MM"), onExit
function M.new(opts)
  opts = opts or {}
  local t = opts.term or term.current()
  local w, h = t.getSize()
  local self = setmetatable({
    t = t, w = w, h = h,
    wm = WM.new({ term = t, top = 1, bottom = h - 1, kernel = opts.kernel }),
    apps = opts.apps, menuOpen = false, exitAction = nil,
    now = opts.now or function() return textutils.formatTime(os.time("local"), true) end,
    taskButtons = {},
  }, Desktop)
  self.kernel = self.wm.kernel
  self.wm.onChange = function() self:drawOverlay() end
  if not self.apps then self:loadApps() end
  return self
end

---------------------------------------------------------------------------------------------------------------------
-- Applications
---------------------------------------------------------------------------------------------------------------------

function Desktop:loadApps(dir)
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
        if ok and type(app) == "table" and app.name and (app.build or app.run or app.program) then
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

--- Open an application (a table as described above). Returns the window.
function Desktop:launch(app)
  local spec = { title = app.name, w = app.w or 40, h = app.h or 12 }
  if app.build then
    spec.build = function(root, win) app.build(root, win, self) end
  elseif app.run then
    spec.run = function(win) app.run(win, self) end
  elseif app.program then
    spec.run = function()
      local okExec, exec = pcall(require, "tsr.shell.exec")
      if okExec then
        local sh = exec.new({ parentShell = rawget(_G, "shell") })
        sh:runLine(app.program)
      else
        shell.run(app.program)
      end
    end
  end
  return self.wm:open(spec)
end

--- Launch an application by id or name.
function Desktop:launchByName(name)
  for _, app in ipairs(self.apps) do
    if app.id == name or app.name == name then return self:launch(app) end
  end
  return nil, "no such application: " .. tostring(name)
end

---------------------------------------------------------------------------------------------------------------------
-- Start menu
---------------------------------------------------------------------------------------------------------------------

function Desktop:menuItems()
  local items = {}
  for _, app in ipairs(self.apps) do items[#items + 1] = { text = app.name, app = app } end
  items[#items + 1] = { text = "-" }
  items[#items + 1] = { text = "Exit to shell", action = "shell" }
  items[#items + 1] = { text = "Log out", action = "logout" }
  items[#items + 1] = { text = "Restart", action = "reboot" }
  items[#items + 1] = { text = "Shut down", action = "shutdown" }
  return items
end

function Desktop:menuRect()
  local items = self:menuItems()
  local w = 12
  for _, it in ipairs(items) do w = math.max(w, #it.text + 4) end
  local h = #items + 2
  return { x = 1, y = math.max(1, self.h - h), w = math.min(w, self.w), h = h, items = items }
end

function Desktop:setMenu(open)
  self.menuOpen = open and true or false
  self.wm:tick(true)
end

local function drawMenu(self)
  local th = theme.get()
  local r = self:menuRect()
  W.fill(self.t, r.x, r.y, r.w, r.h, th.menu)
  for i, it in ipairs(r.items) do
    if it.text == "-" then
      W.put(self.t, r.x, r.y + i, string.rep("-", r.w), th.border, th.menu)
    else
      W.put(self.t, r.x, r.y + i, " " .. it.text, th.menuText, th.menu, r.w)
    end
  end
  W.put(self.t, r.x, r.y, string.rep(" ", r.w), th.menuText, th.menu, r.w)
end

---------------------------------------------------------------------------------------------------------------------
-- Taskbar
---------------------------------------------------------------------------------------------------------------------

local START = " Tessera "

function Desktop:drawTaskbar()
  local th, t = theme.get(), self.t
  local y = self.h
  W.fill(t, 1, y, self.w, 1, th.taskbar)
  W.put(t, 1, y, START, th.buttonActiveText, self.menuOpen and th.accent or th.titleActive, #START)
  local clock = self.now()
  local clockX = self.w - #clock
  W.put(t, clockX, y, " " .. clock, th.taskbarText, th.taskbar)
  self.taskButtons = {}
  local x = #START + 2
  local room = clockX - x - 1
  local wins = self.wm:list()
  if #wins > 0 and room > 0 then
    local each = math.max(5, math.min(16, math.floor(room / #wins)))
    for _, win in ipairs(wins) do
      if x + each > clockX then break end
      local active = win == self.wm.focused and not win.minimized
      local label = " " .. win.title
      W.put(t, x, y, label, active and th.buttonActiveText or th.taskbarText, active and th.accent or th.taskbar, each - 1)
      self.taskButtons[#self.taskButtons + 1] = { x1 = x, x2 = x + each - 2, win = win }
      x = x + each
    end
  end
end

function Desktop:drawOverlay()
  self:drawTaskbar()
  if self.menuOpen then drawMenu(self) end
end

---------------------------------------------------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------------------------------------------------

function Desktop:chooseMenu(item)
  self.menuOpen = false
  if item.app then self:launch(item.app)
  elseif item.action then self.exitAction = item.action end
  self.wm:tick(true)
end

--- Handle one event. Returns true when the screen needs attention (the loop recomposes on its own anyway).
function Desktop:event(name, a, b, c)
  if name == "mouse_click" then
    local x, y = b, c
    if self.menuOpen then
      local r = self:menuRect()
      if x >= r.x and x < r.x + r.w and y > r.y and y < r.y + r.h - 1 then
        local item = r.items[y - r.y]
        if item and item.text ~= "-" then self:chooseMenu(item) return true end
      end
      self.menuOpen = false
      self.wm:tick(true)
      if y == self.h and x <= #START then return true end     -- the click that closed it was on the start button
    end
    if y == self.h then
      if x <= #START then self:setMenu(true) return true end
      for _, tb in ipairs(self.taskButtons) do
        if x >= tb.x1 and x <= tb.x2 then
          if tb.win == self.wm.focused and not tb.win.minimized then self.wm:minimize(tb.win) else self.wm:focus(tb.win) end
          self.wm:tick(true)
          return true
        end
      end
      return true
    end
  elseif name == "key" and require("tsr.util").isEscape(a) and self.menuOpen then
    self:setMenu(false)
    return true
  end
  local used = self.wm:event(name, a, b, c)
  return used
end

--- Run until the user leaves. Returns "shell" | "logout" | "reboot" | "shutdown".
function Desktop:run()
  local clockStamp = self.now()
  self.wm:tick(true)
  local timer = os.startTimer(0.2)
  local beats = 0
  while not self.exitAction do
    local ev = table.pack(os.pullEventRaw())
    if ev[1] == "timer" and ev[2] == timer then
      timer = os.startTimer(0.2)
      beats = beats + 1
      if beats % 5 == 0 then self.wm:slowTick() end
    elseif ev[1] == "term_resize" then
      local w, h = self.t.getSize()
      self.w, self.h = w, h
      self.wm:resizeScreen(w, h, h - 1)
    else
      self:event(table.unpack(ev, 1, ev.n))
    end
    if self.now() ~= clockStamp then
      clockStamp = self.now()
      self.wm.signature = nil
    end
    self.wm:tick()
  end
  self.wm:closeAll()
  return self.exitAction
end

--- Start the desktop on the current terminal with the configured theme. Returns the exit action.
function M.start(opts)
  opts = opts or {}
  local config = require("tsr.config")
  local t = opts.term or term.current()
  theme.set(config.get("ui.theme", "dark"), t.isColor())
  t.setBackgroundColor(theme.get().desktop)
  t.clear()
  local desktop = M.new(opts)
  local action = desktop:run()
  t.setBackgroundColor(colors.black)
  t.setTextColor(colors.white)
  t.clear()
  t.setCursorPos(1, 1)
  return action
end

return M
