-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Widget toolkit for the Tessera desktop (written from scratch for CC: Tweaked terminals).
--
--   local W = require("tsr.gui.widgets")
--   local root = W.root(term.current())
--   local ok = root:add(W.button{ x = 2, y = 2, text = "OK", onClick = function() ... end })
--   root:draw()
--   -- in an event loop:  root:dispatch(os.pullEvent())
--
-- Coordinates of a child are relative to its parent. Widgets: label, button, checkbox, input, list, progress, panel, dialog.
-- Colours come from the current theme (tsr.gui.theme), never from the widgets themselves.
local theme = require("tsr.gui.theme")

local W = {}

---------------------------------------------------------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------------------------------------------------------

local function fill(t, x, y, w, h, bg)
  if w <= 0 or h <= 0 then return end
  t.setBackgroundColor(bg)
  local row = string.rep(" ", w)
  for i = 0, h - 1 do
    t.setCursorPos(x, y + i)
    t.write(row)
  end
end
W.fill = fill

--- Write `text` clipped/padded to `width` at x,y.
local function put(t, x, y, text, fg, bg, width)
  if width and width <= 0 then return end
  text = tostring(text)
  if width then
    if #text > width then text = text:sub(1, width) else text = text .. string.rep(" ", width - #text) end
  end
  t.setCursorPos(x, y)
  t.setTextColor(fg)
  t.setBackgroundColor(bg)
  t.write(text)
end
W.put = put

--- Split text into lines of at most `width` characters (words are kept whole where possible).
function W.wrap(text, width)
  local out = {}
  for para in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    if para == "" then out[#out + 1] = "" end
    local line = ""
    for word in para:gmatch("%S+") do
      while #word > width do
        if line ~= "" then out[#out + 1] = line line = "" end
        out[#out + 1] = word:sub(1, width)
        word = word:sub(width + 1)
      end
      if line == "" then line = word
      elseif #line + 1 + #word <= width then line = line .. " " .. word
      else out[#out + 1] = line line = word end
    end
    if line ~= "" then out[#out + 1] = line end
  end
  if #out > 0 and out[#out] == "" and text:sub(-1) ~= "\n" then out[#out] = nil end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Base widget
---------------------------------------------------------------------------------------------------------------------

local Widget = {}
Widget.__index = Widget
W.Widget = Widget

--- Make a subclass of `base` (default Widget).
function W.class(base)
  local c = {}
  c.__index = c
  setmetatable(c, { __index = base or Widget })
  return c
end

local function init(self, props)
  for k, v in pairs(props or {}) do self[k] = v end
  self.x, self.y = self.x or 1, self.y or 1
  self.w, self.h = self.w or 1, self.h or 1
  if self.visible == nil then self.visible = true end
  if self.enabled == nil then self.enabled = true end
  self.children = {}
  return self
end

function W.widget(props) return init(setmetatable({}, Widget), props) end

function Widget:add(child)
  child.parent = self
  self.children[#self.children + 1] = child
  return child
end

function Widget:remove(child)
  for i, c in ipairs(self.children) do
    if c == child then table.remove(self.children, i) child.parent = nil return true end
  end
  return false
end

function Widget:clear() for _, c in ipairs(self.children) do c.parent = nil end self.children = {} end

--- Where children's coordinates start, relative to this widget's top-left corner (panels have a border).
function Widget:origin() return 0, 0 end

--- Absolute screen position of the top-left corner.
function Widget:abs()
  local x, y = self.x, self.y
  local p = self.parent
  while p do
    local ox, oy = p:origin()
    x, y = x + p.x - 1 + ox, y + p.y - 1 + oy
    p = p.parent
  end
  return x, y
end

function Widget:root()
  local w = self
  while w.parent do w = w.parent end
  return w
end

function Widget:contains(px, py)
  local ax, ay = self:abs()
  return px >= ax and px < ax + self.w and py >= ay and py < ay + self.h
end

--- Deepest visible widget at an absolute point (last added = on top).
function Widget:hit(px, py)
  if not self.visible or not self:contains(px, py) then return nil end
  for i = #self.children, 1, -1 do
    local h = self.children[i]:hit(px, py)
    if h then return h end
  end
  return self
end

function Widget:draw(t)
  if not self.visible then return end
  self:paint(t)
  for _, c in ipairs(self.children) do c:draw(t) end
end

function Widget:paint() end
function Widget:onMouse() return false end
function Widget:onKey() return false end
function Widget:onChar() return false end
function Widget:onPaste() return false end

--- Ask the root to redraw soon (the event loop draws after each event anyway).
function Widget:invalidate() local r = self:root() if r.dirty ~= nil then r.dirty = true end end

--- Move keyboard focus to this widget.
function Widget:focus()
  local r = self:root()
  if r.setFocus then r:setFocus(self) end
end

function Widget:hasFocus() local r = self:root() return r.focused == self end

---------------------------------------------------------------------------------------------------------------------
-- Root: owns the terminal, focus and event dispatch
---------------------------------------------------------------------------------------------------------------------

local Root = W.class(Widget)

function W.root(t)
  local w, h = t.getSize()
  local r = init(setmetatable({}, Root), { x = 1, y = 1, w = w, h = h })
  r.t = t
  r.dirty = true
  r.shift = false
  r.lastClick = { time = 0 }
  return r
end

function Root:paint(t)
  fill(t, self.x, self.y, self.w, self.h, self.background or theme.get().window)
end

local function collectFocusable(w, out)
  if not w.visible then return end
  if w.focusable and w.enabled then out[#out + 1] = w end
  for _, c in ipairs(w.children) do collectFocusable(c, out) end
end

function Root:setFocus(widget)
  if self.focused == widget then return end
  local old = self.focused
  self.focused = widget
  if old and old.onBlur then old:onBlur() end
  if widget and widget.onFocus then widget:onFocus() end
  self.dirty = true
end

function Root:focusNext(backwards)
  local list = {}
  collectFocusable(self, list)
  if #list == 0 then return end
  local idx = 0
  for i, w in ipairs(list) do if w == self.focused then idx = i end end
  idx = backwards and (idx - 1) or (idx + 1)
  if idx < 1 then idx = #list elseif idx > #list then idx = 1 end
  self:setFocus(list[idx])
end

--- Redraw everything. Uses setVisible on windows to avoid flicker.
function Root:render()
  local t = self.t
  local buffered = t.setVisible ~= nil and (t.isVisible == nil or t.isVisible())
  if buffered then t.setVisible(false) end
  self:draw(t)
  -- cursor: shown only on a focused text input
  local f = self.focused
  if f and f.cursorPos and f.visible then
    local cx, cy = f:cursorPos()
    t.setCursorPos(cx, cy)
    t.setTextColor(theme.get().inputText)
    t.setCursorBlink(true)
  else
    t.setCursorBlink(false)
  end
  if buffered then t.setVisible(true) end
  self.dirty = false
end

local function bubbleMouse(widget, kind, px, py, extra)
  local w = widget
  while w do
    if w.enabled then
      local ax, ay = w:abs()
      if w:onMouse(kind, px - ax + 1, py - ay + 1, extra) then return w end
    end
    w = w.parent
  end
end

--- Feed one CraftOS event to the widget tree. Returns true when the screen should be redrawn.
function Root:dispatch(name, a, b, c)
  if name == "mouse_click" then
    local target = self:hit(b, c)
    if not target then return false end
    local w = target
    while w and not (w.focusable and w.enabled) do w = w.parent end
    if w and w ~= self then self:setFocus(w) end
    self.capture = bubbleMouse(target, "down", b, c, a)
    if self.capture then
      local now = os.clock()
      local lc = self.lastClick
      if lc.target == self.capture and now - lc.time < 0.5 and lc.x == b and lc.y == c then
        bubbleMouse(target, "double", b, c, a)
      end
      self.lastClick = { time = now, target = self.capture, x = b, y = c }
    end
    return true
  elseif name == "mouse_drag" then
    if self.capture then
      local ax, ay = self.capture:abs()
      self.capture:onMouse("drag", b - ax + 1, c - ay + 1, a)
      return true
    end
  elseif name == "mouse_up" then
    if self.capture then
      local ax, ay = self.capture:abs()
      self.capture:onMouse("up", b - ax + 1, c - ay + 1, a)
      self.capture = nil
      return true
    end
  elseif name == "mouse_scroll" then
    local target = self:hit(b, c)
    if target then bubbleMouse(target, "scroll", b, c, a) return true end
  elseif name == "key" then
    if a == keys.leftShift or a == keys.rightShift then self.shift = true end
    local f = self.focused
    local w = f
    while w do
      if w.enabled and w:onKey(a, b) then return true end
      w = w.parent
    end
    if a == keys.tab then self:focusNext(self.shift) return true end
    return false
  elseif name == "key_up" then
    if a == keys.leftShift or a == keys.rightShift then self.shift = false end
  elseif name == "char" then
    local w = self.focused
    while w do
      if w.enabled and w:onChar(a) then return true end
      w = w.parent
    end
  elseif name == "paste" then
    local w = self.focused
    while w do
      if w.enabled and w:onPaste(a) then return true end
      w = w.parent
    end
  end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- Label
---------------------------------------------------------------------------------------------------------------------

local Label = W.class(Widget)

--- props: text, align ("left"|"center"|"right"), role (theme text role, default "windowText"), wrap (bool), w, h
function W.label(props)
  local l = init(setmetatable({}, Label), props)
  l.text = l.text or ""
  if not props.w then l.w = #tostring(l.text) end
  return l
end

function Label:lines()
  if self.wrap then return W.wrap(self.text, self.w) end
  local out = {}
  for line in (tostring(self.text) .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  if out[#out] == "" and #out > 1 then out[#out] = nil end
  return out
end

function Label:paint(t)
  local th = theme.get()
  local ax, ay = self:abs()
  local lines = self:lines()
  for i = 1, self.h do
    local line = lines[i] or ""
    local pad = 0
    if self.align == "center" then pad = math.floor((self.w - #line) / 2)
    elseif self.align == "right" then pad = self.w - #line end
    put(t, ax, ay + i - 1, string.rep(" ", math.max(0, pad)) .. line, th[self.role or "windowText"], self.bg and th[self.bg] or th.window, self.w)
  end
end

function Label:setText(text) self.text = text end

---------------------------------------------------------------------------------------------------------------------
-- Button
---------------------------------------------------------------------------------------------------------------------

local Button = W.class(Widget)
Button.focusable = true

--- props: text, onClick, w (default text + 2), primary (accent colour)
function W.button(props)
  local b = init(setmetatable({}, Button), props)
  b.text = b.text or "OK"
  if not props.w then b.w = #b.text + 2 end
  b.h = 1
  return b
end

function Button:paint(t)
  local th = theme.get()
  local ax, ay = self:abs()
  local bg, fg = th.button, th.buttonText
  if self.pressed then bg, fg = th.buttonActive, th.buttonActiveText
  elseif self.primary then bg, fg = th.accent, th.buttonActiveText end
  if not self.enabled then bg, fg = th.window, th.disabled end
  if self:hasFocus() then bg, fg = th.inputFocus, th.inputFocusText end
  local label = self.text
  local pad = math.max(0, self.w - #label)
  local left = math.floor(pad / 2)
  put(t, ax, ay, string.rep(" ", left) .. label .. string.rep(" ", pad - left), fg, bg, self.w)
end

function Button:click()
  if self.enabled and self.onClick then self.onClick(self) end
end

function Button:onMouse(kind, x, y)
  if kind == "down" then self.pressed = true self:invalidate() return true
  elseif kind == "drag" then self.pressed = x >= 1 and x <= self.w and y == 1 self:invalidate() return true
  elseif kind == "up" then
    local was = self.pressed
    self.pressed = false
    self:invalidate()
    if was and x >= 1 and x <= self.w and y == 1 then self:click() end
    return true
  end
  return false
end

function Button:onKey(key)
  if key == keys.enter or key == keys.space then self:click() return true end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- Checkbox
---------------------------------------------------------------------------------------------------------------------

local Checkbox = W.class(Widget)
Checkbox.focusable = true

function W.checkbox(props)
  local c = init(setmetatable({}, Checkbox), props)
  c.text = c.text or ""
  c.checked = c.checked and true or false
  if not props.w then c.w = #c.text + 4 end
  c.h = 1
  return c
end

function Checkbox:toggle()
  self.checked = not self.checked
  if self.onChange then self.onChange(self.checked, self) end
  self:invalidate()
end

function Checkbox:paint(t)
  local th = theme.get()
  local ax, ay = self:abs()
  local focus = self:hasFocus()
  put(t, ax, ay, (self.checked and "[x] " or "[ ] ") .. self.text, focus and th.inputFocusText or (self.enabled and th.windowText or th.disabled),
    focus and th.inputFocus or th.window, self.w)
end

function Checkbox:onMouse(kind)
  if kind == "down" then self:toggle() return true end
  return false
end

function Checkbox:onKey(key)
  if key == keys.space or key == keys.enter then self:toggle() return true end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- Text input
---------------------------------------------------------------------------------------------------------------------

local Input = W.class(Widget)
Input.focusable = true

--- props: text, placeholder, secret (show * instead), onChange(text), onSubmit(text), w, maxLength
function W.input(props)
  local i = init(setmetatable({}, Input), props)
  i.text = i.text or ""
  i.cursor = #i.text
  i.scroll = 0
  i.h = 1
  if not props.w then i.w = 20 end
  return i
end

function Input:shown() return self.secret and string.rep("*", #self.text) or self.text end

function Input:clampScroll()
  if self.cursor < self.scroll then self.scroll = self.cursor end
  if self.cursor > self.scroll + self.w - 1 then self.scroll = self.cursor - self.w + 1 end
  if self.scroll < 0 then self.scroll = 0 end
end

function Input:cursorPos()
  self:clampScroll()
  local ax, ay = self:abs()
  return ax + self.cursor - self.scroll, ay
end

function Input:paint(t)
  local th = theme.get()
  local ax, ay = self:abs()
  local focus = self:hasFocus()
  self:clampScroll()
  local bg, fg = focus and th.inputFocus or th.input, focus and th.inputFocusText or th.inputText
  if not self.enabled then fg = th.disabled end
  local text = self:shown()
  if text == "" and not focus and self.placeholder then
    put(t, ax, ay, self.placeholder, th.textDim, bg, self.w)
  else
    put(t, ax, ay, text:sub(self.scroll + 1, self.scroll + self.w), fg, bg, self.w)
  end
end

function Input:setText(text)
  self.text = text
  self.cursor = math.min(self.cursor, #text)
  self:invalidate()
end

local function changed(self)
  if self.onChange then self.onChange(self.text, self) end
  self:invalidate()
end

function Input:insert(s)
  if self.maxLength and #self.text + #s > self.maxLength then s = s:sub(1, math.max(0, self.maxLength - #self.text)) end
  if s == "" then return end
  self.text = self.text:sub(1, self.cursor) .. s .. self.text:sub(self.cursor + 1)
  self.cursor = self.cursor + #s
  changed(self)
end

function Input:onChar(c) self:insert(c) return true end
function Input:onPaste(text) self:insert((text:gsub("[\r\n]+", " "))) return true end

function Input:onKey(key)
  if key == keys.left then self.cursor = math.max(0, self.cursor - 1)
  elseif key == keys.right then self.cursor = math.min(#self.text, self.cursor + 1)
  elseif key == keys.home then self.cursor = 0
  elseif key == keys["end"] then self.cursor = #self.text
  elseif key == keys.backspace then
    if self.cursor > 0 then
      self.text = self.text:sub(1, self.cursor - 1) .. self.text:sub(self.cursor + 1)
      self.cursor = self.cursor - 1
      changed(self)
    end
  elseif key == keys.delete then
    if self.cursor < #self.text then
      self.text = self.text:sub(1, self.cursor) .. self.text:sub(self.cursor + 2)
      changed(self)
    end
  elseif key == keys.enter then
    if self.onSubmit then self.onSubmit(self.text, self) end
  else
    return false
  end
  self:invalidate()
  return true
end

function Input:onMouse(kind, x)
  if kind == "down" then
    self.cursor = math.max(0, math.min(#self.text, self.scroll + x - 1))
    self:invalidate()
    return true
  end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- List box
---------------------------------------------------------------------------------------------------------------------

local List = W.class(Widget)
List.focusable = true

--- props: items (array of strings or { text = ... }), onSelect(index, item), onActivate(index, item) (Enter / double click)
function W.list(props)
  local l = init(setmetatable({}, List), props)
  l.items = l.items or {}
  l.selected = l.selected or (#l.items > 0 and 1 or 0)
  l.top = 1
  return l
end

local function itemText(item) return type(item) == "table" and tostring(item.text) or tostring(item) end

function List:setItems(items, keepSelection)
  self.items = items
  if not keepSelection or self.selected > #items then self.selected = #items > 0 and 1 or 0 end
  self.top = 1
  self:invalidate()
end

function List:scrollIntoView()
  if self.selected < self.top then self.top = self.selected end
  if self.selected > self.top + self.h - 1 then self.top = self.selected - self.h + 1 end
  self.top = math.max(1, math.min(self.top, math.max(1, #self.items - self.h + 1)))
end

function List:select(index)
  if #self.items == 0 then self.selected = 0 return end
  index = math.max(1, math.min(#self.items, index))
  local changedSel = index ~= self.selected
  self.selected = index
  self:scrollIntoView()
  if changedSel and self.onSelect then self.onSelect(index, self.items[index], self) end
  self:invalidate()
end

function List:paint(t)
  local th = theme.get()
  local ax, ay = self:abs()
  self:scrollIntoView()
  local textW = self.w - ((#self.items > self.h) and 1 or 0)
  for row = 0, self.h - 1 do
    local idx = self.top + row
    local item = self.items[idx]
    local sel = idx == self.selected
    local bg = sel and (self:hasFocus() and th.selection or th.border) or th.window
    local fg = sel and th.selectionText or th.windowText
    put(t, ax, ay + row, item and (" " .. itemText(item)) or "", fg, bg, textW)
  end
  if #self.items > self.h then
    local barH = math.max(1, math.floor(self.h * self.h / #self.items))
    local pos = math.floor((self.top - 1) / math.max(1, #self.items - self.h) * (self.h - barH) + 0.5)
    for row = 0, self.h - 1 do
      local on = row >= pos and row < pos + barH
      put(t, ax + self.w - 1, ay + row, " ", th.window, on and th.accent or th.border, 1)
    end
  end
end

function List:onMouse(kind, x, y, extra)
  if kind == "down" then
    local idx = self.top + y - 1
    if idx >= 1 and idx <= #self.items then self:select(idx) end
    return true
  elseif kind == "double" then
    if self.selected > 0 and self.onActivate then self.onActivate(self.selected, self.items[self.selected], self) end
    return true
  elseif kind == "scroll" then
    self.top = math.max(1, math.min(math.max(1, #self.items - self.h + 1), self.top + extra))
    self:invalidate()
    return true
  end
  return false
end

function List:onKey(key)
  if key == keys.up then self:select(self.selected - 1)
  elseif key == keys.down then self:select(self.selected + 1)
  elseif key == keys.pageUp then self:select(self.selected - self.h)
  elseif key == keys.pageDown then self:select(self.selected + self.h)
  elseif key == keys.home then self:select(1)
  elseif key == keys["end"] then self:select(#self.items)
  elseif key == keys.enter then
    if self.selected > 0 and self.onActivate then self.onActivate(self.selected, self.items[self.selected], self) end
  else
    return false
  end
  return true
end

function List:selectedItem() return self.items[self.selected] end

---------------------------------------------------------------------------------------------------------------------
-- Progress bar
---------------------------------------------------------------------------------------------------------------------

local Progress = W.class(Widget)

--- props: value (0..1), text (overlay, default the percentage), w
function W.progress(props)
  local p = init(setmetatable({}, Progress), props)
  p.value = p.value or 0
  p.h = 1
  return p
end

function Progress:paint(t)
  local th = theme.get()
  local ax, ay = self:abs()
  local v = math.max(0, math.min(1, self.value))
  local filled = math.floor(self.w * v + 0.5)
  local label = self.text or ("%d%%"):format(math.floor(v * 100 + 0.5))
  local pad = math.floor((self.w - #label) / 2)
  local line = string.rep(" ", math.max(0, pad)) .. label
  line = line .. string.rep(" ", self.w - #line)
  for i = 1, self.w do
    local on = i <= filled
    t.setCursorPos(ax + i - 1, ay)
    t.setBackgroundColor(on and th.accent or th.border)
    t.setTextColor(on and th.selectionText or th.windowText)
    t.write(line:sub(i, i))
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Panel (bordered container) and dialogs
---------------------------------------------------------------------------------------------------------------------

local Panel = W.class(Widget)

--- props: title, border (default true), w, h. Children are positioned inside the border (1,1 = first inner cell).
function W.panel(props)
  local p = init(setmetatable({}, Panel), props)
  if p.border == nil then p.border = true end
  return p
end

function Panel:origin() if self.border then return 1, 1 end return 0, 0 end

function Panel:paint(t)
  local th = theme.get()
  local ax, ay = self:abs()
  ax, ay = ax, ay                      -- abs() gives this widget's own corner
  fill(t, ax, ay, self.w, self.h, th.window)
  if not self.border then return end
  local top = "+" .. string.rep("-", self.w - 2) .. "+"
  put(t, ax, ay, top, th.border, th.window)
  put(t, ax, ay + self.h - 1, top, th.border, th.window)
  for row = 1, self.h - 2 do
    put(t, ax, ay + row, "|", th.border, th.window)
    put(t, ax + self.w - 1, ay + row, "|", th.border, th.window)
  end
  if self.title and #self.title > 0 then
    local title = " " .. self.title:sub(1, self.w - 6) .. " "
    put(t, ax + 2, ay, title, th.accent, th.window)
  end
end

--- Modal-style message box centred on `parent` (a root or window content). buttons = { "OK" } or { "Yes", "No" }.
--- onChoice(buttonText) is called and the dialog removes itself. Returns the dialog panel.
function W.dialog(parent, opts)
  local buttons = opts.buttons or { "OK" }
  local textW = 0
  for line in (opts.text .. "\n"):gmatch("(.-)\n") do textW = math.max(textW, #line) end
  local btnW = 0
  for _, b in ipairs(buttons) do btnW = btnW + #b + 4 end
  local w = math.max(textW + 4, btnW + 2, #(opts.title or "") + 8, 16)
  w = math.min(w, parent.w)
  local lines = W.wrap(opts.text, w - 4)
  local h = #lines + 5
  local dlg = W.panel({ title = opts.title, x = math.max(1, math.floor((parent.w - w) / 2) + 1),
                        y = math.max(1, math.floor((parent.h - h) / 2) + 1), w = w, h = h })
  dlg:add(W.label({ x = 1, y = 1, w = w - 4, h = #lines, text = table.concat(lines, "\n") }))
  local x = math.floor((w - 2 - btnW + 2) / 2) + 1
  for _, text in ipairs(buttons) do
    dlg:add(W.button({ x = x, y = h - 3, text = text, onClick = function()
      local root = dlg:root()
      parent:remove(dlg)
      if root.setFocus then root:setFocus(opts.restoreFocus) end
      if opts.onChoice then opts.onChoice(text) end
    end }))
    x = x + #text + 4
  end
  parent:add(dlg)
  local root = parent:root()
  if root.setFocus then root:setFocus(dlg.children[2] or dlg.children[1]) end
  return dlg
end

W.Label, W.Button, W.Checkbox, W.Input, W.List, W.Progress, W.Panel, W.Root = Label, Button, Checkbox, Input, List, Progress, Panel, Root

return W
