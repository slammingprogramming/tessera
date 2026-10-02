-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Text buffer for the editor: lines, cursor, selection, undo/redo, search. No UI in here.
-- Positions are (y, x): line number and character column, both 1-based; x may be #line + 1 (just after the last character).
-- Every change goes through replace(), which records what it removed and inserted, so undo/redo is exact.
local B = {}
B.__index = B

local UNDO_LIMIT = 500

function B.new(text)
  local self = setmetatable({ lines = { "" }, cy = 1, cx = 1, anchor = nil, undoStack = {}, redoStack = {}, modified = false,
                              wantX = 1, lastKind = nil }, B)
  if text and text ~= "" then self:load(text) end
  return self
end

--- Replace the whole content (no undo history).
function B:load(text)
  local lines = {}
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  if #lines > 1 and lines[#lines] == "" and text:sub(-1) == "\n" then lines[#lines] = nil end
  self.lines = lines
  self.cy, self.cx, self.anchor = 1, 1, nil
  self.undoStack, self.redoStack, self.modified = {}, {}, false
end

function B:text() return table.concat(self.lines, "\n") .. "\n" end

function B:lineCount() return #self.lines end

---------------------------------------------------------------------------------------------------------------------
-- The one editing primitive
---------------------------------------------------------------------------------------------------------------------

local function clampPos(self, y, x)
  y = math.max(1, math.min(#self.lines, y))
  x = math.max(1, math.min(#self.lines[y] + 1, x))
  return y, x
end

local function ordered(y1, x1, y2, x2)
  if y1 > y2 or (y1 == y2 and x1 > x2) then return y2, x2, y1, x1 end
  return y1, x1, y2, x2
end

--- Text between two positions.
function B:range(y1, x1, y2, x2)
  y1, x1, y2, x2 = ordered(y1, x1, y2, x2)
  if y1 == y2 then return self.lines[y1]:sub(x1, x2 - 1) end
  local out = { self.lines[y1]:sub(x1) }
  for y = y1 + 1, y2 - 1 do out[#out + 1] = self.lines[y] end
  out[#out + 1] = self.lines[y2]:sub(1, x2 - 1)
  return table.concat(out, "\n")
end

--- Position reached by walking `text` from (y, x).
local function endOf(y, x, text)
  local nl = 0
  local last = 0
  for pos in text:gmatch("()\n") do nl = nl + 1 last = pos end
  if nl == 0 then return y, x + #text end
  return y + nl, #text - last + 1
end

local function apply(self, y1, x1, y2, x2, text)
  local head = self.lines[y1]:sub(1, x1 - 1)
  local tail = self.lines[y2]:sub(x2)
  local pieces = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do pieces[#pieces + 1] = line end
  pieces[1] = head .. pieces[1]
  pieces[#pieces] = pieces[#pieces] .. tail
  local newLines = {}
  for i = 1, y1 - 1 do newLines[#newLines + 1] = self.lines[i] end
  for _, p in ipairs(pieces) do newLines[#newLines + 1] = p end
  for i = y2 + 1, #self.lines do newLines[#newLines + 1] = self.lines[i] end
  self.lines = newLines
end

--- Replace the text between two positions with `text`. kind groups consecutive edits of the same sort for undo ("type", "delete").
--- Returns the position just after the inserted text.
function B:replace(y1, x1, y2, x2, text, kind)
  y1, x1 = clampPos(self, y1, x1)
  y2, x2 = clampPos(self, y2, x2)
  y1, x1, y2, x2 = ordered(y1, x1, y2, x2)
  local removed = self:range(y1, x1, y2, x2)
  if removed == "" and text == "" then return y1, x1 end
  apply(self, y1, x1, y2, x2, text)
  local ey, ex = endOf(y1, x1, text)
  -- merge with the previous undo entry when the user is just typing / deleting in a row
  local top = self.undoStack[#self.undoStack]
  if kind and top and top.kind == kind and self.lastKind == kind and top.y == y1 and top.x + #top.inserted == x1 and removed == "" and top.removed == "" and kind == "type" then
    top.inserted = top.inserted .. text
  else
    self.undoStack[#self.undoStack + 1] = { y = y1, x = x1, removed = removed, inserted = text, kind = kind }
    if #self.undoStack > UNDO_LIMIT then table.remove(self.undoStack, 1) end
  end
  self.lastKind = kind
  self.redoStack = {}
  self.modified = true
  return ey, ex
end

function B:undo()
  local e = table.remove(self.undoStack)
  if not e then return false end
  local ey, ex = endOf(e.y, e.x, e.inserted)
  apply(self, e.y, e.x, ey, ex, e.removed)
  self.redoStack[#self.redoStack + 1] = e
  self.cy, self.cx = endOf(e.y, e.x, e.removed)
  self.anchor, self.lastKind = nil, nil
  self.modified = true
  return true
end

function B:redo()
  local e = table.remove(self.redoStack)
  if not e then return false end
  local ey, ex = endOf(e.y, e.x, e.removed)
  apply(self, e.y, e.x, ey, ex, e.inserted)
  self.undoStack[#self.undoStack + 1] = e
  self.cy, self.cx = endOf(e.y, e.x, e.inserted)
  self.anchor, self.lastKind = nil, nil
  self.modified = true
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Cursor and selection
---------------------------------------------------------------------------------------------------------------------

function B:setCursor(y, x, keepAnchor)
  if not keepAnchor then self.anchor = nil end
  self.cy, self.cx = clampPos(self, y, x)
  self.wantX = self.cx
  self.lastKind = nil
end

function B:select(y, x) self.anchor = { y = y, x = x } end

function B:hasSelection()
  return self.anchor ~= nil and (self.anchor.y ~= self.cy or self.anchor.x ~= self.cx)
end

--- Selection bounds in document order: y1, x1, y2, x2 (or nil).
function B:selectionBounds()
  if not self:hasSelection() then return nil end
  return ordered(self.anchor.y, self.anchor.x, self.cy, self.cx)
end

function B:selectedText()
  local y1, x1, y2, x2 = self:selectionBounds()
  if not y1 then return "" end
  return self:range(y1, x1, y2, x2)
end

function B:selectAll()
  self.anchor = { y = 1, x = 1 }
  self.cy, self.cx = #self.lines, #self.lines[#self.lines] + 1
end

--- Delete the selection (if any). Returns true when something was deleted.
function B:deleteSelection()
  local y1, x1, y2, x2 = self:selectionBounds()
  if not y1 then self.anchor = nil return false end
  self:replace(y1, x1, y2, x2, "", "delete")
  self.cy, self.cx, self.anchor = y1, x1, nil
  self.wantX = x1
  return true
end

--- Move the cursor. `extend` keeps/starts a selection.
function B:move(dy, dx, extend)
  if extend and not self.anchor then self.anchor = { y = self.cy, x = self.cx } end
  if not extend then
    if self:hasSelection() and (dx ~= 0 and dy == 0) then
      -- left/right collapses the selection to its edge
      local y1, x1, y2, x2 = self:selectionBounds()
      if dx < 0 then self.cy, self.cx = y1, x1 else self.cy, self.cx = y2, x2 end
      self.anchor, self.wantX, self.lastKind = nil, self.cx, nil
      return
    end
    self.anchor = nil
  end
  local y, x = self.cy, self.cx
  if dx ~= 0 then
    x = x + dx
    if x < 1 then
      if y > 1 then y = y - 1 x = #self.lines[y] + 1 else x = 1 end
    elseif x > #self.lines[y] + 1 then
      if y < #self.lines then y = y + 1 x = 1 else x = #self.lines[y] + 1 end
    end
    self.wantX = x
  end
  if dy ~= 0 then
    y = math.max(1, math.min(#self.lines, y + dy))
    x = math.min(self.wantX, #self.lines[y] + 1)
  end
  self.cy, self.cx, self.lastKind = y, x, nil
end

function B:home(extend)
  if extend and not self.anchor then self.anchor = { y = self.cy, x = self.cx } end
  if not extend then self.anchor = nil end
  local line = self.lines[self.cy]
  local indent = #line:match("^%s*")
  -- smart home: first press goes to the first non-blank, again to column 1
  self.cx = (self.cx ~= indent + 1 and indent + 1 <= #line + 1) and (indent + 1) or 1
  self.wantX, self.lastKind = self.cx, nil
end

function B:endOfLine(extend)
  if extend and not self.anchor then self.anchor = { y = self.cy, x = self.cx } end
  if not extend then self.anchor = nil end
  self.cx = #self.lines[self.cy] + 1
  self.wantX, self.lastKind = self.cx, nil
end

function B:gotoLine(n, extend)
  if extend and not self.anchor then self.anchor = { y = self.cy, x = self.cx } end
  if not extend then self.anchor = nil end
  self.cy = math.max(1, math.min(#self.lines, n))
  self.cx = math.min(self.wantX, #self.lines[self.cy] + 1)
  self.lastKind = nil
end

---------------------------------------------------------------------------------------------------------------------
-- Editing commands
---------------------------------------------------------------------------------------------------------------------

--- Type text at the cursor, replacing the selection. Newlines get the indentation of the line above when autoindent is on.
function B:insert(text, autoindent)
  if self:hasSelection() then self:deleteSelection() end
  if autoindent and text == "\n" then
    local line = self.lines[self.cy]
    local indent = line:match("^%s*")
    local before = line:sub(1, self.cx - 1)
    -- one more level after an opening keyword
    if before:match("%f[%w]then%s*$") or before:match("%f[%w]do%s*$") or before:match("%f[%w]else%s*$") or before:match("%f[%w]function%f[%W].*%)%s*$")
       or before:match("{%s*$") or before:match("%f[%w]repeat%s*$") then
      indent = indent .. "  "
    end
    text = "\n" .. indent
  end
  local y, x = self:replace(self.cy, self.cx, self.cy, self.cx, text, text:find("\n", 1, true) and "newline" or "type")
  self.cy, self.cx, self.anchor = y, x, nil
  self.wantX = x
end

function B:backspace()
  if self:deleteSelection() then return end
  if self.cx > 1 then
    self:replace(self.cy, self.cx - 1, self.cy, self.cx, "", "delete")
    self.cx = self.cx - 1
  elseif self.cy > 1 then
    local px = #self.lines[self.cy - 1] + 1
    self:replace(self.cy - 1, px, self.cy, 1, "", "delete")
    self.cy, self.cx = self.cy - 1, px
  end
  self.wantX = self.cx
end

function B:deleteForward()
  if self:deleteSelection() then return end
  local line = self.lines[self.cy]
  if self.cx <= #line then self:replace(self.cy, self.cx, self.cy, self.cx + 1, "", "delete")
  elseif self.cy < #self.lines then self:replace(self.cy, self.cx, self.cy + 1, 1, "", "delete") end
end

--- Indent (or outdent) the selected lines, or insert spaces at the cursor.
function B:indent(width, outdent)
  width = width or 2
  local pad = string.rep(" ", width)
  if not self:hasSelection() and not outdent then
    self:insert(pad)
    return
  end
  local y1, y2 = self.cy, self.cy
  if self:hasSelection() then
    local a, _, b = self:selectionBounds()
    y1, y2 = a, b
    if self.cx == 1 and b > a and self.anchor and (self.anchor.y == b or self.cy == b) then
      local sy, sx, ey, ex = self:selectionBounds()
      if ex == 1 then y2 = ey - 1 end
    end
  end
  for y = y1, y2 do
    if outdent then
      local n = #self.lines[y]:match("^ *")
      local cut = math.min(width, n)
      if cut > 0 then self:replace(y, 1, y, cut + 1, "", "indent") end
    else
      self:replace(y, 1, y, 1, pad, "indent")
    end
  end
  self.cx = math.min(#self.lines[self.cy] + 1, math.max(1, self.cx + (outdent and -width or width)))
  if self.anchor then self.anchor.x = math.max(1, self.anchor.x + (outdent and -width or width)) end
end

function B:deleteLine()
  local y = self.cy
  if #self.lines == 1 then self:replace(1, 1, 1, #self.lines[1] + 1, "", "delete") self.cx = 1 return end
  if y < #self.lines then self:replace(y, 1, y + 1, 1, "", "delete") else self:replace(y - 1, #self.lines[y - 1] + 1, y, #self.lines[y] + 1, "", "delete") self.cy = y - 1 end
  self.cx = math.min(self.cx, #self.lines[self.cy] + 1)
  self.anchor = nil
end

---------------------------------------------------------------------------------------------------------------------
-- Search
---------------------------------------------------------------------------------------------------------------------

--- Find `needle` starting after (or before, with backwards) the cursor, wrapping around. Plain text unless `pattern`.
--- Returns y, x, length or nil.
function B:find(needle, opts)
  opts = opts or {}
  if needle == "" then return nil end
  local plain = not opts.pattern
  local function inLine(y, from)
    local line = self.lines[y]
    if opts.ignoreCase then line = line:lower() needle = needle:lower() end
    local s, e = line:find(needle, from, plain)
    return s, e
  end
  local count = #self.lines
  if not opts.backwards then
    local startY, startX = self.cy, self.cx
    for i = 0, count do
      local y = ((startY - 1 + i) % count) + 1
      local from = (i == 0) and startX or 1
      local s, e = inLine(y, from)
      if s and not (i == count and s >= startX) then return y, s, e - s + 1 end
    end
  else
    for i = 0, count do
      local y = ((self.cy - 1 - i) % count) + 1
      local line = self.lines[y]
      local last
      local from = 1
      while true do
        local s, e = (opts.ignoreCase and line:lower() or line):find(opts.ignoreCase and needle:lower() or needle, from, plain)
        if not s then break end
        if i == 0 and s >= self.cx - 0 then break end
        last = { s, e }
        from = s + 1
      end
      if last then return y, last[1], last[2] - last[1] + 1 end
    end
  end
  return nil
end

--- Select the next match. Returns true when found.
function B:findNext(needle, opts)
  local y, x, len = self:find(needle, opts)
  if not y then return false end
  self.anchor = { y = y, x = x }
  self.cy, self.cx = y, x + len
  self.wantX = self.cx
  return true
end

--- Replace every occurrence (plain text). Returns how many.
function B:replaceAll(needle, replacement, ignoreCase)
  if needle == "" then return 0 end
  local count = 0
  for y = 1, #self.lines do
    local line = self.lines[y]
    local from = 1
    local hay = ignoreCase and line:lower() or line
    local pat = ignoreCase and needle:lower() or needle
    local rebuilt, last = {}, 1
    while true do
      local s, e = hay:find(pat, from, true)
      if not s then break end
      rebuilt[#rebuilt + 1] = line:sub(last, s - 1)
      rebuilt[#rebuilt + 1] = replacement
      last = e + 1
      from = e + 1
      count = count + 1
    end
    if last > 1 then
      rebuilt[#rebuilt + 1] = line:sub(last)
      self:replace(y, 1, y, #line + 1, table.concat(rebuilt), "replace")
    end
  end
  self.cy, self.cx = clampPos(self, self.cy, self.cx)
  return count
end

return B
