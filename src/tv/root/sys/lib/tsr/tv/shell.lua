-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The TV interface: a home screen of big tiles on a monitor, driven by a remote (arrow keys, OK, Back) or by touching the monitor.
-- Remote keys arrive as the event  tv_key(name)  with names up, down, left, right, ok, back, home (see tsr.tv.remote), or as
-- ordinary key events. Apps: Media (play files from /media), Signage (the configured slideshow), Dashboard (power and tanks), Settings.
local theme = require("tsr.gui.theme")
local W = require("tsr.gui.widgets")
local media = require("tsr.media")

local M = {}

M.MEDIA_DIR = "/media"

local NAME_TO_KEY = { up = keys.up, down = keys.down, left = keys.left, right = keys.right, ok = keys.enter, back = keys.backspace, home = keys.home }

local TV = {}
TV.__index = TV

--- opts: monitor (peripheral name; default the computer's own screen), term (tests), scale (text scale, default 1),
--- peripheral (tests), mediaDir
function M.new(opts)
  opts = opts or {}
  local per = opts.peripheral or peripheral
  local t = opts.term or (opts.monitor and per.wrap(opts.monitor)) or term.current()
  if t.setTextScale then pcall(t.setTextScale, opts.scale or 1) end
  local w, h = t.getSize()
  local self = setmetatable({
    t = t, w = w, h = h, per = per, mediaDir = opts.mediaDir or M.MEDIA_DIR, monitorName = opts.monitor,
    stack = {}, exit = false, pull = opts.pull,
  }, TV)
  self.root = W.root(t)
  self.root.background = theme.get().desktop
  return self
end

function TV:push(title, build)
  self.stack[#self.stack + 1] = { title = title, build = build }
  self:show()
end

function TV:back()
  if #self.stack > 1 then
    self.stack[#self.stack] = nil
    self:show()
  end
end

function TV:home()
  self.stack = {}
  self:push("Home", function(root) self:buildHome(root) end)
end

function TV:show()
  local root = self.root
  root:clear()
  root.focused = nil
  root.dirty = true
  self.stack[#self.stack].build(root, self)
end

---------------------------------------------------------------------------------------------------------------------
-- Screens
---------------------------------------------------------------------------------------------------------------------

--- A big focusable button.
local function tile(self, x, y, w, h, text, onClick)
  local b = W.button({ x = x, y = y, w = w, text = text, onClick = onClick })
  b.h = h
  -- paint a tall button: fill all rows, label in the middle
  b.paint = function(btn, t)
    local th = theme.get()
    local ax, ay = btn:abs()
    local focused = btn:hasFocus() or btn.pressed
    local bg = focused and th.accent or th.button
    local fg = focused and th.buttonActiveText or th.buttonText
    W.fill(t, ax, ay, btn.w, btn.h, bg)
    local label = btn.text:sub(1, btn.w - 2)
    W.put(t, ax + math.floor((btn.w - #label) / 2), ay + math.floor(btn.h / 2), label, fg, bg)
  end
  return b
end

local APPS = {
  { name = "Media", open = function(tv) tv:openMedia() end },
  { name = "Signage", open = function(tv) tv:openSignage() end },
  { name = "Dashboard", open = function(tv) tv:openDashboard() end },
  { name = "Settings", open = function(tv) tv:openSettings() end },
}
M.APPS = APPS

function TV:buildHome(root)
  local cols = self.w >= 40 and 2 or 1
  local tw = math.floor((self.w - 2) / cols)
  local th = math.max(3, math.floor((self.h - 4) / math.ceil(#APPS / cols)))
  self.tiles = {}
  for i, app in ipairs(APPS) do
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    local b = root:add(tile(self, 2 + col * tw, 3 + row * th, tw - 1, th - 1, app.name, function() app.open(self) end))
    self.tiles[#self.tiles + 1] = b
  end
  root:add(W.label({ x = 2, y = 1, w = self.w - 2, text = "Tessera TV", role = "text", bg = "desktop" }))
  self.tiles[1]:focus()
end

function TV:openMedia()
  self:push("Media", function(root)
    local files = media.library(self.mediaDir)
    local items = {}
    for i, f in ipairs(files) do items[i] = { text = ("%-6s %s"):format(f.kind, f.name), file = f } end
    root:add(W.label({ x = 2, y = 1, w = self.w - 2, text = "Media - OK plays, Back returns", role = "text", bg = "desktop" }))
    if #items == 0 then
      root:add(W.label({ x = 2, y = 3, w = self.w - 2, h = 3, wrap = true, text = "No media in " .. self.mediaDir .. ". Copy .bimg, .nfp or .dfpwm files there.", role = "text", bg = "desktop" }))
      return
    end
    local list = root:add(W.list({ x = 2, y = 3, w = self.w - 2, h = self.h - 4, items = items,
      onActivate = function(_, item) self:play(item.file) end }))
    list:focus()
  end)
end

--- Play a library entry full-screen on the TV; any key, touch or remote button stops it.
function TV:play(file)
  local speakers = {}
  for _, name in ipairs(self.per.getNames()) do
    if self.per.getType(name) == "speaker" then speakers[#speakers + 1] = self.per.wrap(name) end
  end
  media.play(file.path, { term = self.t, speakers = speakers, pull = self.pull })
  self:show()
end

function TV:openSignage()
  self:push("Signage", function(root)
    local cfg = require("tsr.tv.signage").loadConfig()
    root:add(W.label({ x = 2, y = 1, w = self.w - 2, text = "Signage - " .. #(cfg.slides or {}) .. " slides", role = "text", bg = "desktop" }))
    root:add(W.label({ x = 2, y = 3, w = self.w - 2, h = 4, wrap = true, text = "Press OK to start the slideshow; any key stops it.", role = "text", bg = "desktop" }))
    local b = root:add(tile(self, 2, 6, math.min(20, self.w - 2), 3, "Start", function()
      local sg = require("tsr.tv.signage")
      local stop = false
      parallel.waitForAny(
        function() sg.run(sg.loadConfig(), { term = self.t, peripheral = self.per }) end,
        function() repeat local ev = (self.pull or os.pullEvent)() until ev == "key" or ev == "tv_key" or ev == "monitor_touch" end)
      self:show()
    end))
    b:focus()
  end)
end

function TV:openDashboard()
  self:push("Dashboard", function(root)
    local okHal = pcall(require, "tsr.hal")
    root:add(W.label({ x = 2, y = 1, w = self.w - 2, text = "Dashboard", role = "text", bg = "desktop" }))
    local lines = {}
    if okHal then
      local hal = require("tsr.hal")
      for _, dev in ipairs(hal.scan({ peripheral = self.per })) do
        local line
        if dev:has("energy") then
          local p = dev:get("energy.percent")
          if p then line = ("%-16s power %3d%%"):format(dev.name:sub(1, 16), math.floor(p + 0.5)) end
        elseif dev:has("fluid") then
          local a = dev:get("fluid.amount")
          if a then line = ("%-16s fluid %d mB"):format(dev.name:sub(1, 16), a) end
        end
        if line then lines[#lines + 1] = line end
      end
    end
    if #lines == 0 then lines[1] = okHal and "No energy storage or tanks found." or "Install the hal package for live readings." end
    root:add(W.label({ x = 2, y = 3, w = self.w - 2, h = self.h - 4, text = table.concat(lines, "\n"), role = "text", bg = "desktop" }))
    self.refresh = function() self:show() end
  end)
end

function TV:openSettings()
  self:push("Settings", function(root)
    root:add(W.label({ x = 2, y = 1, w = self.w - 2, text = "Settings", role = "text", bg = "desktop" }))
    local names = theme.order
    local items = {}
    for i, n in ipairs(names) do items[i] = { text = "Theme: " .. n, name = n } end
    local list = root:add(W.list({ x = 2, y = 3, w = self.w - 2, h = math.min(#items, self.h - 6), items = items,
      onActivate = function(_, item)
        theme.set(item.name, self.t.isColor())
        self.root.background = theme.get().desktop
        local okConfig, config = pcall(require, "tsr.config")
        if okConfig then config.set("ui.theme", item.name, "system") end
        self:show()
      end }))
    root:add(W.button({ x = 2, y = self.h - 2, w = 12, text = "Shut down", onClick = function() self.exit = "shutdown" end }))
    root:add(W.button({ x = 16, y = self.h - 2, w = 10, text = "Restart", onClick = function() self.exit = "reboot" end }))
    list:focus()
  end)
end

---------------------------------------------------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------------------------------------------------

function TV:draw()
  self.t.setBackgroundColor(theme.get().desktop)
  self.root:render()
end

--- Move focus to the nearest focusable widget in a direction (for tile grids).
function TV:moveFocus(dx, dy)
  local current = self.root.focused
  if not current or not self.tiles then return false end
  local cx, cy = current:abs()
  local best, bestScore
  for _, tl in ipairs(self.tiles) do
    if tl ~= current then
      local x, y = tl:abs()
      local ddx, ddy = x - cx, y - cy
      if (dx ~= 0 and ddx * dx > 0) or (dy ~= 0 and ddy * dy > 0) then
        local score = math.abs(ddx) + math.abs(ddy) * 2
        if not best or score < bestScore then best, bestScore = tl, score end
      end
    end
  end
  if best then best:focus() return true end
  return false
end

--- Handle one event. Returns true when it did something.
function TV:event(ev, a, b, c)
  if ev == "monitor_touch" and (not self.monitorName or a == self.monitorName) then
    self.root:dispatch("mouse_click", 1, b, c)
    self.root:dispatch("mouse_up", 1, b, c)
    return true
  elseif ev == "tv_key" or ev == "key" then
    local name = a
    local code
    if ev == "tv_key" then code = NAME_TO_KEY[a] else code = a end
    if not code then return false end
    if code == keys.home and (ev == "tv_key") then self:home() return true end
    if code == keys.backspace and not (self.root.focused and self.root.focused.cursorPos) then self:back() return true end
    local top = self.stack[#self.stack]
    if top and top.title == "Home" and (code == keys.left or code == keys.right or code == keys.up or code == keys.down) then
      local dx = (code == keys.left and -1) or (code == keys.right and 1) or 0
      local dy = (code == keys.up and -1) or (code == keys.down and 1) or 0
      if self:moveFocus(dx, dy) then return true end
    end
    self.root:dispatch("key", code, false)
    return true
  end
  return false
end

function TV:run()
  self:home()
  self:draw()
  local timer = os.startTimer(5)
  while not self.exit do
    local ev = table.pack((self.pull or os.pullEvent)())
    if ev[1] == "timer" and ev[2] == timer then
      timer = os.startTimer(5)
      if self.refresh and self.stack[#self.stack].title == "Dashboard" then self.refresh() end
    elseif ev[1] == "terminate" then
      break
    else
      self:event(table.unpack(ev, 1, ev.n))
    end
    self:draw()
  end
  return self.exit or "shell"
end

--- Start the TV interface. opts: monitor, scale. Returns "shell" | "reboot" | "shutdown".
function M.start(opts)
  opts = opts or {}
  local config = require("tsr.config")
  opts.monitor = opts.monitor or config.get("tv.monitor")
  opts.scale = opts.scale or config.get("tv.scale", 1)
  theme.set(config.get("ui.theme", "dark"), true)
  local tv = M.new(opts)
  local action = tv:run()
  tv.t.setBackgroundColor(colors.black)
  tv.t.clear()
  return action
end

function M.main(args)
  local action = M.start({ monitor = args[1] })
  if action == "reboot" then require("tsr.sys").reboot() elseif action == "shutdown" then require("tsr.sys").shutdown() end
  return true
end

return M
