-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Sub-pixel canvas. Every terminal character is 2 x 3 pixels (the "teletext" characters 128-159), so an 51 x 19 screen is a
-- 102 x 57 pixel canvas. Pixels hold CraftOS colours (powers of two); nil is transparent.
--
--   local gfx = require("tsr.gfx")
--   local c = gfx.new(26, 10)                 -- 26 x 10 characters = 52 x 30 pixels
--   c:line(0, 0, 51, 29, colors.red)
--   c:rect(5, 5, 20, 10, colors.blue, true)
--   c:text(2, 2, "HI", colors.white, 2)       -- the 3x5 font at scale 2
--   c:flush(term.current(), 1, 1)
--
-- A character can show only two colours. Where a cell holds more, the two most common win (the bottom-right pixel's colour
-- is always the background, as the teletext characters require).
local font = require("tsr.gfx.font")

local M = {}
M.font = font

local Canvas = {}
Canvas.__index = Canvas

local toBlit = colors.toBlit

--- A canvas of `cols` x `rows` characters.
function M.new(cols, rows)
  local c = setmetatable({ cols = cols, rows = rows, w = cols * 2, h = rows * 3, px = {} }, Canvas)
  for y = 1, c.h do c.px[y] = {} end
  return c
end

function Canvas:clear(color)
  for y = 1, self.h do
    local row = self.px[y]
    for x = 1, self.w do row[x] = color end
  end
end

--- Pixel coordinates are 0-based from the top-left corner.
function Canvas:set(x, y, color)
  x, y = math.floor(x), math.floor(y)
  if x < 0 or y < 0 or x >= self.w or y >= self.h then return end
  self.px[y + 1][x + 1] = color
end

function Canvas:get(x, y)
  if x < 0 or y < 0 or x >= self.w or y >= self.h then return nil end
  return self.px[y + 1][x + 1]
end

--- Bresenham line.
function Canvas:line(x1, y1, x2, y2, color)
  x1, y1, x2, y2 = math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2)
  local dx, dy = math.abs(x2 - x1), -math.abs(y2 - y1)
  local sx, sy = x1 < x2 and 1 or -1, y1 < y2 and 1 or -1
  local err = dx + dy
  while true do
    self:set(x1, y1, color)
    if x1 == x2 and y1 == y2 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy x1 = x1 + sx end
    if e2 <= dx then err = err + dx y1 = y1 + sy end
  end
end

function Canvas:rect(x, y, w, h, color, fill)
  if w <= 0 or h <= 0 then return end
  if fill then
    for yy = y, y + h - 1 do for xx = x, x + w - 1 do self:set(xx, yy, color) end end
  else
    self:line(x, y, x + w - 1, y, color)
    self:line(x, y + h - 1, x + w - 1, y + h - 1, color)
    self:line(x, y, x, y + h - 1, color)
    self:line(x + w - 1, y, x + w - 1, y + h - 1, color)
  end
end

--- Midpoint circle; with fill the disc is drawn.
function Canvas:circle(cx, cy, r, color, fill)
  local x, y, err = r, 0, 1 - r
  local function plot(px, py)
    if fill then self:line(cx - px, cy + py, cx + px, cy + py, color) else self:set(cx + px, cy + py, color) self:set(cx - px, cy + py, color) end
  end
  while x >= y do
    plot(x, y) plot(x, -y) plot(y, x) plot(y, -x)
    if not fill then
      self:set(cx + y, cy + x, color) self:set(cx - y, cy + x, color) self:set(cx + y, cy - x, color) self:set(cx - y, cy - x, color)
    end
    y = y + 1
    if err < 0 then err = err + 2 * y + 1 else x = x - 1 err = err + 2 * (y - x) + 1 end
  end
end

--- Copy another canvas onto this one at (x, y); nil pixels of the source are transparent.
function Canvas:blit(other, x, y)
  for yy = 0, other.h - 1 do
    for xx = 0, other.w - 1 do
      local c = other.px[yy + 1][xx + 1]
      if c ~= nil then self:set(x + xx, y + yy, c) end
    end
  end
end

--- Pixel width of `str` at `scale` (glyphs are 3 wide with 1 pixel between them).
function M.textWidth(str, scale)
  scale = scale or 1
  if #str == 0 then return 0 end
  return (#str * 4 - 1) * scale
end

function M.textHeight(scale) return 5 * (scale or 1) end

--- Draw text with the 3x5 font, each font pixel becoming a scale x scale block.
function Canvas:text(x, y, str, color, scale)
  scale = math.max(1, math.floor(scale or 1))
  local cx = x
  for i = 1, #str do
    local rows = font.glyph(str:sub(i, i))
    for r = 1, 5 do
      for col = 1, 3 do
        if rows[r][col] then
          for sy = 0, scale - 1 do for sx = 0, scale - 1 do
            self:set(cx + (col - 1) * scale + sx, y + (r - 1) * scale + sy, color)
          end end
        end
      end
    end
    cx = cx + 4 * scale
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------------------------------------------------

-- bit values of the five non-background pixels of a cell: (col, row) -> bit
local BIT = { [1] = { [1] = 1, [2] = 4, [3] = 16 }, [2] = { [1] = 2, [2] = 8 } }

--- The text, foreground and background strings for one row of characters (1-based row). Transparent pixels render as
--- `background` (default black).
function Canvas:rowBlit(row, background)
  background = background or colors.black
  local text, fg, bg = {}, {}, {}
  for col = 1, self.cols do
    local pix = {}
    for cy = 1, 3 do
      for cx = 1, 2 do
        local v = self.px[(row - 1) * 3 + cy][(col - 1) * 2 + cx]
        pix[(cy - 1) * 2 + cx] = v == nil and background or v
      end
    end
    local bgColor = pix[6]                    -- bottom-right pixel is the background of the character
    local counts, order = {}, {}
    for i = 1, 5 do
      local c = pix[i]
      if c ~= bgColor then
        if not counts[c] then counts[c] = 0 order[#order + 1] = c end
        counts[c] = counts[c] + 1
      end
    end
    local fgColor = bgColor
    local best = 0
    for _, c in ipairs(order) do if counts[c] > best then best, fgColor = counts[c], c end end
    local bits = 0
    for i = 1, 5 do
      if pix[i] == fgColor and fgColor ~= bgColor then
        local cx, cy = (i - 1) % 2 + 1, math.floor((i - 1) / 2) + 1
        bits = bits + BIT[cx][cy]
      end
    end
    text[col] = string.char(128 + bits)
    fg[col] = toBlit(fgColor)
    bg[col] = toBlit(bgColor)
  end
  return table.concat(text), table.concat(fg), table.concat(bg)
end

--- Draw onto a terminal (or window/monitor) with the canvas' top-left character at (ox, oy).
function Canvas:flush(t, ox, oy, background)
  ox, oy = ox or 1, oy or 1
  for row = 1, self.rows do
    local text, fg, bg = self:rowBlit(row, background)
    t.setCursorPos(ox, oy + row - 1)
    t.blit(text, fg, bg)
  end
end

--- The canvas as a BIMG frame (rows of { text, fg, bg }), ready to save.
function Canvas:toBimg(background)
  local frame = {}
  for row = 1, self.rows do
    local text, fg, bg = self:rowBlit(row, background)
    frame[row] = { text, fg, bg }
  end
  return { frame, creator = "tsr.gfx", width = self.cols, height = self.rows }
end

---------------------------------------------------------------------------------------------------------------------
-- Big text without a canvas
---------------------------------------------------------------------------------------------------------------------

--- Draw `str` in big letters on terminal `t` with its top-left corner at character cell (x, y). scale 1 = 3x5 pixels per letter,
--- which is about 2 x 2 characters. Returns the width and height used, in characters.
function M.bigText(t, x, y, str, fg, bg, scale)
  scale = scale or 1
  local pxW, pxH = M.textWidth(str, scale), M.textHeight(scale)
  local cols, rows = math.ceil(pxW / 2), math.ceil(pxH / 3)
  local c = M.new(cols, rows)
  c:clear(bg or colors.black)
  c:text(0, 0, str, fg or colors.white, scale)
  c:flush(t, x, y)
  return cols, rows
end

M.Canvas = Canvas

return M
