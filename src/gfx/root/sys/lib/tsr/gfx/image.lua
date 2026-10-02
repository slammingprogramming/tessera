-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Image formats.
--   NFP   the paint program's format: one character per pixel, hex digits for the 16 colours, space = transparent
--   BIMG  "blit image": a Lua table of frames; each frame is rows of { text, foreground, background } (blit strings), with an
--         optional palette and animation settings. Several programs and sanjuuni produce it.
-- image.parse(text, kind?) / image.load(path) return an image with:
--   img.kind, img.width, img.height (characters for BIMG, pixels for NFP), img.frames (BIMG)
--   img:draw(t, x, y, frame)      draw on a terminal;  NFP images are rendered through a canvas (2 x 3 pixels per character)
--   img:toCanvas()                NFP only
local gfx = require("tsr.gfx")

local M = {}

local Image = {}
Image.__index = Image

---------------------------------------------------------------------------------------------------------------------
-- NFP
---------------------------------------------------------------------------------------------------------------------

--- Parse NFP text. Returns an image, or nil + reason.
function M.parseNfp(text)
  local rows = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do rows[#rows + 1] = line end
  while #rows > 0 and rows[#rows] == "" do rows[#rows] = nil end
  if #rows == 0 then return nil, "empty image" end
  local w = 0
  for _, r in ipairs(rows) do
    if r:find("[^0-9a-fA-F ]") then return nil, "not an NFP image (unexpected character)" end
    w = math.max(w, #r)
  end
  local img = setmetatable({ kind = "nfp", width = w, height = #rows, pixels = {} }, Image)
  for y, r in ipairs(rows) do
    img.pixels[y] = {}
    for x = 1, #r do
      local ch = r:sub(x, x)
      if ch ~= " " then img.pixels[y][x] = colors.fromBlit(ch:lower()) end
    end
  end
  return img
end

--- Encode a canvas (or any object with w, h and get(x, y)) as NFP text.
function M.toNfp(canvas)
  local out = {}
  for y = 0, canvas.h - 1 do
    local row = {}
    for x = 0, canvas.w - 1 do
      local c = canvas:get(x, y)
      row[#row + 1] = c and colors.toBlit(c) or " "
    end
    out[#out + 1] = table.concat(row)
  end
  return table.concat(out, "\n") .. "\n"
end

function Image:toCanvas()
  assert(self.kind == "nfp", "only NFP images are pixel images")
  local c = gfx.new(math.ceil(self.width / 2), math.ceil(self.height / 3))
  for y = 1, self.height do
    for x = 1, self.width do
      local v = self.pixels[y][x]
      if v then c:set(x - 1, y - 1, v) end
    end
  end
  return c
end

---------------------------------------------------------------------------------------------------------------------
-- BIMG
---------------------------------------------------------------------------------------------------------------------

local function validFrame(frame)
  if type(frame) ~= "table" or #frame == 0 then return false end
  for _, row in ipairs(frame) do
    if type(row) ~= "table" or type(row[1]) ~= "string" or type(row[2]) ~= "string" or type(row[3]) ~= "string" then return false end
    if #row[1] ~= #row[2] or #row[1] ~= #row[3] then return false end
  end
  return true
end

--- Parse a BIMG document (the text of the serialized table). Returns an image, or nil + reason.
function M.parseBimg(text)
  local data = textutils.unserialize(text)
  if type(data) ~= "table" then return nil, "not a BIMG image (not a table)" end
  local frames = {}
  for i = 1, #data do
    if not validFrame(data[i]) then return nil, "frame " .. i .. " is malformed" end
    frames[i] = data[i]
  end
  if #frames == 0 then return nil, "the image has no frames" end
  local first = frames[1]
  return setmetatable({
    kind = "bimg", frames = frames, width = #first[1][1], height = #first, palette = data.palette,
    animated = data.animation == true, secondsPerFrame = data.secondsPerFrame or 0.1,
  }, Image)
end

--- Serialize frames (an array of frames, each an array of { text, fg, bg }) as a BIMG document.
function M.toBimg(frames, opts)
  opts = opts or {}
  local doc = { creator = "tsr.gfx" }
  for i, f in ipairs(frames) do doc[i] = f end
  if #frames > 1 then doc.animation = true doc.secondsPerFrame = opts.secondsPerFrame or 0.1 end
  doc.palette = opts.palette
  return textutils.serialize(doc)
end

---------------------------------------------------------------------------------------------------------------------
-- Common
---------------------------------------------------------------------------------------------------------------------

--- Parse text of either format. `kind` forces one ("nfp" or "bimg"); otherwise a leading "{" means BIMG.
function M.parse(text, kind)
  kind = kind or (text:match("^%s*{") and "bimg" or "nfp")
  if kind == "bimg" then return M.parseBimg(text) end
  return M.parseNfp(text)
end

function M.load(path)
  local h = fs.open(path, "r")
  if not h then return nil, "cannot open " .. tostring(path) end
  local text = h.readAll()
  h.close()
  local kind = path:match("%.bimg$") and "bimg" or (path:match("%.nfp$") and "nfp") or nil
  return M.parse(text, kind)
end

--- Draw frame `frame` (BIMG, default 1) or the whole picture (NFP) with its top-left character at (x, y).
function Image:draw(t, x, y, frame)
  x, y = x or 1, y or 1
  if self.kind == "nfp" then
    self:toCanvas():flush(t, x, y)
    return
  end
  local f = self.frames[frame or 1]
  if not f then return end
  for r, row in ipairs(f) do
    t.setCursorPos(x, y + r - 1)
    t.blit(row[1], row[2], row[3])
  end
end

--- Size in characters.
function Image:charSize()
  if self.kind == "nfp" then return math.ceil(self.width / 2), math.ceil(self.height / 3) end
  return self.width, self.height
end

return M
