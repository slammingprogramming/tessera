-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Output capture and input feeding for pipes and redirects.
--   capture.new()  -> a terminal-shaped object that records what a program prints, as text
--   capture.stdin(text) -> a reader object (read / lines) over a string, used to feed `<` and pipes
local M = {}

local WIDTH = 255   -- wide on purpose: captured output must not be word-wrapped by the program
local HEIGHT = 100000

--- A fake terminal. Programs write to it through the usual term API (print, write, io.write, textutils...).
--- obj.term is the terminal object; obj.text() returns everything written so far.
function M.new()
  local lines = { {} }        -- lines[y] = array of single characters, indexed by x
  local cx, cy = 1, 1
  local t = {}

  local function ensure(y)
    for i = #lines + 1, y do lines[i] = {} end
  end

  local function put(ch)
    if cx >= 1 and cx <= WIDTH then
      local row = lines[cy]
      for x = #row + 1, cx - 1 do row[x] = " " end
      row[cx] = ch
    end
    cx = cx + 1
  end

  function t.write(s)
    s = tostring(s == nil and "" or s)
    for i = 1, #s do put(s:sub(i, i)) end
  end
  function t.blit(text) t.write(text) end
  function t.clear() lines, cx, cy = { {} }, 1, 1 end
  function t.clearLine() lines[cy] = {} end
  function t.getCursorPos() return cx, cy end
  function t.setCursorPos(x, y)
    cx, cy = math.floor(x), math.max(1, math.floor(y))
    if cy > HEIGHT then cy = HEIGHT end
    ensure(cy)
  end
  function t.getSize() return WIDTH, HEIGHT end
  function t.scroll(n)
    -- keep everything: a scroll just moves content up in a real terminal, which for a recording means "nothing lost"
    n = n or 1
    if n > 0 then
      ensure(cy + n)
      cy = cy + n
    end
  end
  function t.getCursorBlink() return false end
  function t.isColor() return false end
  t.isColour = t.isColor
  function t.getTextColor() return 1 end
  function t.getBackgroundColor() return 32768 end
  t.getTextColour, t.getBackgroundColour = t.getTextColor, t.getBackgroundColor
  function t.getPaletteColor() return 0, 0, 0 end
  t.getPaletteColour = t.getPaletteColor
  function t.getLine(y)
    local row = lines[y]
    if not row then return nil end
    local text = table.concat(row)
    return text, string.rep("0", #text), string.rep("f", #text)
  end
  for _, name in ipairs({ "setCursorBlink", "setTextColor", "setTextColour", "setBackgroundColor", "setBackgroundColour",
                          "setPaletteColor", "setPaletteColour", "setTextScale" }) do
    t[name] = function() end
  end

  local obj = { term = t }

  --- Text written so far. Trailing blanks on a line are dropped; the text ends with a newline when the cursor sits at the
  --- start of a later line (that is what `print` leaves behind).
  function obj.text()
    local out = {}
    local last = cy
    for y = 1, last do
      local row = lines[y] or {}
      out[y] = (table.concat(row):gsub("%s+$", ""))
    end
    return table.concat(out, "\n")
  end
  return obj
end

--- Reader over a string. read(fmt) understands "l", "L", "a", "n" (optionally with a leading "*") and byte counts.
function M.stdin(text)
  local r = { text = text or "", pos = 1 }

  function r.readLine(keepNewline)
    if r.pos > #r.text then return nil end
    local nl = r.text:find("\n", r.pos, true)
    local line
    if nl then
      line = r.text:sub(r.pos, keepNewline and nl or nl - 1)
      r.pos = nl + 1
    else
      line = r.text:sub(r.pos)
      r.pos = #r.text + 1
    end
    return line
  end

  function r.read(fmt)
    if fmt == nil then fmt = "l" end
    if type(fmt) == "number" then
      if r.pos > #r.text then return nil end
      local chunk = r.text:sub(r.pos, r.pos + fmt - 1)
      r.pos = r.pos + #chunk
      return chunk
    end
    fmt = tostring(fmt):gsub("^%*", "")
    if fmt == "l" then return r.readLine(false)
    elseif fmt == "L" then return r.readLine(true)
    elseif fmt == "a" then
      local rest = r.text:sub(r.pos)
      r.pos = #r.text + 1
      return rest
    elseif fmt == "n" then
      local s, e = r.text:find("^%s*[%+%-]?%d*%.?%d+", r.pos)
      if not s then return nil end
      local n = tonumber(r.text:sub(s, e))
      r.pos = e + 1
      return n
    end
    error("bad argument #1 to 'read' (invalid format)", 2)
  end

  function r.lines(fmt)
    return function() return r.read(fmt or "l") end
  end

  return r
end

--- A replacement `io` table for programs whose input is fed: reads come from `reader`, everything else is the real io.
function M.ioFor(reader, realIo)
  local stdin = {
    read = function(_, ...) return reader.read(...) end,
    lines = function(_, ...) return reader.lines(...) end,
    close = function() return true end,
  }
  local proxy = {
    read = function(...) return reader.read(...) end,
    lines = function(name, ...)
      if name == nil then return reader.lines(...) end
      return realIo.lines(name, ...)
    end,
    stdin = stdin,
  }
  return setmetatable(proxy, { __index = realIo })
end

return M
