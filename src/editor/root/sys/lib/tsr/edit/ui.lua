-- SPDX-License-Identifier: AGPL-3.0-or-later
-- ted: the editor's screen, keyboard and mouse handling on top of tsr.edit.buffer.
--   Ctrl+S save   Ctrl+Q quit   Ctrl+F find   F3 / Shift+F3 next/previous   Ctrl+H replace all   Ctrl+L go to line
--   Ctrl+Z / Ctrl+Y undo / redo   Ctrl+A select all   Ctrl+C / X / V copy / cut / paste   Ctrl+K delete line
--   Tab / Shift+Tab indent / outdent   Shift+arrows select   mouse: click, drag, wheel
local Buffer = require("tsr.edit.buffer")
local lua = require("tsr.edit.lua")

local M = {}

local UI = {}
UI.__index = UI

local GUTTER_MIN = 3

--- opts: path, term, text (instead of reading path), readFile/writeFile (tests), tabWidth
function M.new(opts)
  opts = opts or {}
  local t = opts.term or term.current()
  local w, h = t.getSize()
  local self = setmetatable({
    t = t, w = w, h = h, path = opts.path, buf = Buffer.new(), top = 1, left = 0, clipboard = "",
    mods = { ctrl = false, shift = false, alt = false }, prompt = nil, message = nil, done = false,
    tabWidth = opts.tabWidth or 2, lastFind = nil, color = t.isColor(),
    readFile = opts.readFile or function(p)
      local hnd = fs.open(p, "r")
      if not hnd then return nil end
      local s = hnd.readAll()
      hnd.close()
      return s or ""
    end,
    writeFile = opts.writeFile or function(p, s)
      local hnd, err = fs.open(p, "w")
      if not hnd then return false, err end
      hnd.write(s)
      hnd.close()
      return true
    end,
  }, UI)
  if opts.text then self.buf:load(opts.text)
  elseif self.path then
    local text = self.readFile(self.path)
    if text then self.buf:load(text) else self.message = "New file" end
  end
  self.isLua = self.path and self.path:match("%.lua$") ~= nil
  return self
end

function UI:gutterWidth() return math.max(GUTTER_MIN, #tostring(self.buf:lineCount())) + 1 end
function UI:textWidth() return self.w - self:gutterWidth() end
function UI:textHeight() return self.h - 1 end

function UI:scrollToCursor()
  local b = self.buf
  local th, tw = self:textHeight(), self:textWidth()
  if b.cy < self.top then self.top = b.cy end
  if b.cy > self.top + th - 1 then self.top = b.cy - th + 1 end
  if b.cx - 1 < self.left then self.left = b.cx - 1 end
  if b.cx - 1 > self.left + tw - 1 then self.left = b.cx - tw end
  if self.left < 0 then self.left = 0 end
end

---------------------------------------------------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------------------------------------------------

local PALETTE_COLOR = { k = colors.yellow, s = colors.orange, c = colors.lightGray, n = colors.lightBlue, f = colors.cyan, o = colors.white }
local PALETTE_MONO = { k = colors.white, s = colors.lightGray, c = colors.gray, n = colors.lightGray, f = colors.white, o = colors.white }

function UI:draw()
  local t, b = self.t, self.buf
  self:scrollToCursor()
  local gw, tw, th = self:gutterWidth(), self:textWidth(), self:textHeight()
  local pal = self.color and PALETTE_COLOR or PALETTE_MONO
  local toBlit = colors.toBlit
  local sel = { b:selectionBounds() }
  local spans = self.isLua and lua.highlight(b.lines) or nil
  t.setCursorBlink(false)
  for row = 1, th do
    local y = self.top + row - 1
    local line = b.lines[y]
    t.setCursorPos(1, row)
    if not line then
      t.blit(string.rep(" ", gw), string.rep(toBlit(colors.gray), gw), string.rep("f", gw))
      t.blit(string.rep(" ", tw), string.rep("0", tw), string.rep("f", tw))
    else
      local num = ("%" .. (gw - 1) .. "d "):format(y)
      t.blit(num, string.rep(toBlit(colors.gray), gw), string.rep("f", gw))
      local text = line:sub(self.left + 1, self.left + tw)
      local fg, bg = {}, {}
      for i = 1, #text do
        local x = self.left + i
        local c = spans and spans[y]:sub(x, x) or "o"
        fg[i] = toBlit(pal[c] or colors.white)
        bg[i] = "f"
        if sel[1] then
          local inSel = (y > sel[1] or (y == sel[1] and x >= sel[2])) and (y < sel[3] or (y == sel[3] and x < sel[4]))
          if inSel then bg[i] = "8" fg[i] = "f" end
        end
      end
      -- selected line breaks (the newline at the end of a line inside the selection)
      local pad = tw - #text
      local padFg, padBg = string.rep("0", pad), string.rep("f", pad)
      if sel[1] and pad > 0 and y >= sel[1] and y < sel[3] then padBg = "8" .. string.rep("f", pad - 1) end
      t.blit(text .. string.rep(" ", pad), table.concat(fg) .. padFg, table.concat(bg) .. padBg)
    end
  end
  self:drawStatus()
  if not self.prompt then
    t.setCursorPos(gw + b.cx - self.left, b.cy - self.top + 1)
    t.setTextColor(colors.white)
    t.setCursorBlink(true)
  end
end

function UI:drawStatus()
  local t = self.t
  t.setCursorPos(1, self.h)
  t.setBackgroundColor(colors.gray)
  t.setTextColor(colors.white)
  local text
  if self.prompt then
    text = self.prompt.label .. self.prompt.text
  else
    local b = self.buf
    local name = self.path or "[no name]"
    text = ("%s%s  %d:%d  %d lines"):format(name, b.modified and " *" or "", b.cy, b.cx, b:lineCount())
    if self.message then text = text .. "  - " .. self.message
    else text = text .. "  ^S save ^Q quit ^F find" end
  end
  t.write(text:sub(1, self.w) .. string.rep(" ", math.max(0, self.w - #text)))
  if self.prompt then
    t.setCursorPos(math.min(self.w, #self.prompt.label + self.prompt.cursor + 1), self.h)
    t.setTextColor(colors.white)
    t.setCursorBlink(true)
  end
  t.setBackgroundColor(colors.black)
end

---------------------------------------------------------------------------------------------------------------------
-- Prompts (one-line questions in the status bar)
---------------------------------------------------------------------------------------------------------------------

function UI:ask(label, initial, onDone, choices)
  self.prompt = { label = label, text = initial or "", cursor = #(initial or ""), onDone = onDone, choices = choices }
end

local function promptKey(self, key)
  local p = self.prompt
  if key == keys.enter then
    self.prompt = nil
    p.onDone(p.text)
  elseif require("tsr.util").isEscape(key) or (key == keys.q and self.mods.ctrl) then
    self.prompt = nil
    self.message = "Cancelled"
  elseif key == keys.backspace then
    if p.cursor > 0 then p.text = p.text:sub(1, p.cursor - 1) .. p.text:sub(p.cursor + 1) p.cursor = p.cursor - 1 end
  elseif key == keys.delete then p.text = p.text:sub(1, p.cursor) .. p.text:sub(p.cursor + 2)
  elseif key == keys.left then p.cursor = math.max(0, p.cursor - 1)
  elseif key == keys.right then p.cursor = math.min(#p.text, p.cursor + 1)
  elseif key == keys.home then p.cursor = 0
  elseif key == keys["end"] then p.cursor = #p.text
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------------------------------------------------

function UI:save(path)
  path = path or self.path
  if not path then
    self:ask("Save as: ", "", function(name)
      if name == "" then self.message = "Not saved" return end
      self.path = name
      self.isLua = name:match("%.lua$") ~= nil
      self:save(name)
    end)
    return
  end
  local ok, err = self.writeFile(path, self.buf:text())
  if ok then
    self.buf.modified = false
    self.message = "Saved " .. path
  else
    self.message = "Cannot save: " .. tostring(err)
  end
end

function UI:quit()
  if self.buf.modified then
    self:ask("Save changes? (y/n, Esc = keep editing) ", "", function(answer)
      answer = answer:lower():sub(1, 1)
      if answer == "y" then
        self:save()
        if not self.buf.modified then self.done = true end
      elseif answer == "n" then
        self.done = true
      end
    end)
  else
    self.done = true
  end
end

function UI:find(backwards)
  local b = self.buf
  if not self.lastFind then
    self:ask("Find: ", "", function(text)
      if text == "" then return end
      self.lastFind = text
      self:find(backwards)
    end)
    return
  end
  local found
  if backwards then
    -- search from the start of the current selection so the same match is not found again
    local y1, x1 = b:selectionBounds()
    if y1 then b:setCursor(y1, x1) end
    local y, x, len = b:find(self.lastFind, { backwards = true, ignoreCase = true })
    if y then b.anchor = { y = y, x = x } b.cy, b.cx = y, x + len found = true end
  else
    found = b:findNext(self.lastFind, { ignoreCase = true })
  end
  self.message = found and nil or ("Not found: " .. self.lastFind)
end

function UI:replaceAll()
  self:ask("Replace: ", self.lastFind or "", function(find)
    if find == "" then return end
    self:ask("With: ", "", function(with)
      local n = self.buf:replaceAll(find, with, false)
      self.message = n .. " replaced"
    end)
  end)
end

function UI:gotoLine()
  self:ask("Go to line: ", "", function(text)
    local n = tonumber(text)
    if n then self.buf:setCursor(n, 1) end
  end)
end

function UI:copy(cut)
  local b = self.buf
  if b:hasSelection() then
    self.clipboard = b:selectedText()
    if cut then b:deleteSelection() end
  else
    -- no selection: the whole line
    self.clipboard = b.lines[b.cy] .. "\n"
    if cut then b:deleteLine() end
  end
end

function UI:paste(text)
  text = text or self.clipboard
  if text ~= "" then self.buf:insert(text:gsub("\r", ""), false) end
end

---------------------------------------------------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------------------------------------------------

local function wordJump(b, dir, extend)
  if extend and not b.anchor then b.anchor = { y = b.cy, x = b.cx } end
  if not extend then b.anchor = nil end
  local line = b.lines[b.cy]
  local x = b.cx
  if dir > 0 then
    if x > #line then b:move(0, 1, extend) return end
    while x <= #line and line:sub(x, x):match("[%w_]") do x = x + 1 end
    while x <= #line and not line:sub(x, x):match("[%w_]") do x = x + 1 end
  else
    if x == 1 then b:move(0, -1, extend) return end
    x = x - 1
    while x > 1 and not line:sub(x, x):match("[%w_]") do x = x - 1 end
    while x > 1 and line:sub(x - 1, x - 1):match("[%w_]") do x = x - 1 end
  end
  b.cx, b.wantX, b.lastKind = x, x, nil
end

--- Handle one event. Returns true when the screen should be redrawn.
function UI:event(name, a, b2, c)
  local buf, m = self.buf, self.mods
  if name == "key_up" then
    if a == keys.leftCtrl or a == keys.rightCtrl then m.ctrl = false
    elseif a == keys.leftShift or a == keys.rightShift then m.shift = false
    elseif a == keys.leftAlt or a == keys.rightAlt then m.alt = false end
    return false
  end
  if name == "key" then
    if a == keys.leftCtrl or a == keys.rightCtrl then m.ctrl = true return false
    elseif a == keys.leftShift or a == keys.rightShift then m.shift = true return false
    elseif a == keys.leftAlt or a == keys.rightAlt then m.alt = true return false end
    self.message = nil
    if self.prompt then promptKey(self, a) return true end
    local ctrl, shift = m.ctrl, m.shift
    if ctrl then
      if a == keys.s then self:save()
      elseif a == keys.q then self:quit()
      elseif a == keys.f then self.lastFind = nil self:find(false)
      elseif a == keys.h then self:replaceAll()
      elseif a == keys.l then self:gotoLine()
      elseif a == keys.z then buf:undo()
      elseif a == keys.y then buf:redo()
      elseif a == keys.a then buf:selectAll()
      elseif a == keys.c then self:copy(false)
      elseif a == keys.x then self:copy(true)
      elseif a == keys.v then self:paste()
      elseif a == keys.k then buf:deleteLine()
      elseif a == keys.left then wordJump(buf, -1, shift)
      elseif a == keys.right then wordJump(buf, 1, shift)
      elseif a == keys.home then buf:setCursor(1, 1, shift)
      elseif a == keys["end"] then buf:setCursor(buf:lineCount(), #buf.lines[buf:lineCount()] + 1, shift)
      else return false end
      return true
    end
    if a == keys.up then buf:move(-1, 0, shift)
    elseif a == keys.down then buf:move(1, 0, shift)
    elseif a == keys.left then buf:move(0, -1, shift)
    elseif a == keys.right then buf:move(0, 1, shift)
    elseif a == keys.home then buf:home(shift)
    elseif a == keys["end"] then buf:endOfLine(shift)
    elseif a == keys.pageUp then buf:gotoLine(buf.cy - self:textHeight(), shift)
    elseif a == keys.pageDown then buf:gotoLine(buf.cy + self:textHeight(), shift)
    elseif a == keys.enter then buf:insert("\n", true)
    elseif a == keys.backspace then buf:backspace()
    elseif a == keys.delete then buf:deleteForward()
    elseif a == keys.tab then buf:indent(self.tabWidth, shift)
    elseif a == keys.f3 then self:find(shift)
    else return false end
    return true
  elseif name == "char" then
    if self.prompt then
      local p = self.prompt
      p.text = p.text:sub(1, p.cursor) .. a .. p.text:sub(p.cursor + 1)
      p.cursor = p.cursor + #a
      return true
    end
    if m.ctrl then return false end
    self.message = nil
    buf:insert(a, false)
    return true
  elseif name == "paste" then
    if self.prompt then
      local p = self.prompt
      p.text = p.text:sub(1, p.cursor) .. a .. p.text:sub(p.cursor + 1)
      p.cursor = p.cursor + #a
    else
      self:paste(a)
    end
    return true
  elseif name == "mouse_click" or name == "mouse_drag" then
    if self.prompt or c >= self.h then return false end
    local y = math.max(1, math.min(buf:lineCount(), self.top + c - 1))
    local x = math.max(1, self.left + b2 - self:gutterWidth())
    if name == "mouse_click" then
      buf:setCursor(y, x)
      buf:select(buf.cy, buf.cx)
    else
      buf:setCursor(y, x, true)
    end
    return true
  elseif name == "mouse_scroll" then
    self.top = math.max(1, math.min(math.max(1, buf:lineCount() - self:textHeight() + 1), self.top + a * 3))
    return true
  end
  return false
end

--- Run the editor on the terminal until the user quits.
function UI:run()
  self.t.setBackgroundColor(colors.black)
  self.t.clear()
  self:draw()
  while not self.done do
    local ev = table.pack(os.pullEvent())
    if ev[1] == "terminate" then break end
    if ev[1] == "term_resize" then
      self.w, self.h = self.t.getSize()
      self:draw()
    elseif self:event(table.unpack(ev, 1, ev.n)) then
      self:draw()
    end
  end
  self.t.setBackgroundColor(colors.black)
  self.t.setTextColor(colors.white)
  self.t.clear()
  self.t.setCursorPos(1, 1)
  self.t.setCursorBlink(false)
end

return M
