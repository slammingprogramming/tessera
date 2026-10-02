-- SPDX-License-Identifier: AGPL-3.0-or-later
-- 32vid video files (the compressed video + audio container written by sanjuuni), decoded in pure Lua.
--
-- Format summary (see sanjuuni's README, "32vid file format"):
--   header   "32VD"  u16 width  u16 height  u8 fps  u8 streams  u16 flags     (little endian)
--   flags    bits 0-1 video compression: 0 none, 1 ANS, 2 DEFLATE, 3 custom (Huffman); bits 2-3 audio: 0 8-bit PCM, 1 DFPWM; bit 4: 5-bit
--            symbols (always set by current encoders); bits 5-11: multi-monitor layout
--   streams  u32 size  u32 count  u8 type, then the data: type 0 video, 1 audio (mono), 8 subtitles, 12 COMBINED audio+video+subtitle
--            frames (u32 size, u8 type, data) which is what current sanjuuni writes, 13 index (ignored), 64..127 multi-monitor video (skipped)
--   a video frame: the characters (5 bits each: the teletext character 128 + code), then the foreground and background colour of every cell
--            (4 bits each), then the 16-colour palette (16 x 3 bytes). Compression differs per mode, see the decoders below.
-- This decoder follows that description and was checked against sanjuuni's own Lua reference (lib32vid.lua, MIT licence, Copyright (c) 2025
-- JackMacWindows) on files made by an independent encoder; see tests/media/vid32_test.lua.
--
--   local v = vid32.open("/disk/show.32v")            or  vid32.fromString(data)  /  vid32.fromHandle(handle)
--   v.width, v.height, v.fps
--   while true do
--     local kind, data = v:next()          -- "video": { palette = { [0..15] = {r, g, b} }, [1..height] = { text, fg, bg } }
--     if not kind then break end            -- "audio": list of samples -128..127   "subtitle": { frame, length, x, y, text, color }
--   end
local band, rshift, lshift, bor = bit32.band, bit32.rshift, bit32.lshift, bit32.bor
local floor = math.floor
local schar, sbyte = string.char, string.byte

local M = {}

local HEX = "0123456789abcdef"

---------------------------------------------------------------------------------------------------------------------
-- Byte sources
---------------------------------------------------------------------------------------------------------------------

local function stringSource(data)
  local pos = 1
  local r = {}
  function r.byte() local b = sbyte(data, pos) pos = pos + 1 return b end
  function r.bytes(n)
    if pos + n - 1 > #data then local s = data:sub(pos) pos = #data + 1 return #s > 0 and s or nil end
    local s = data:sub(pos, pos + n - 1)
    pos = pos + n
    return s
  end
  function r.eof() return pos > #data end
  return r
end

--- A source over a CC file or HTTP handle (binary mode), reading ahead in blocks.
local function handleSource(h, block)
  block = block or 4096
  local buf, pos = "", 1
  local r = {}
  local function refill()
    local chunk = h.read(block)
    if not chunk or #chunk == 0 then return false end
    buf, pos = chunk, 1
    return true
  end
  function r.byte()
    if pos > #buf and not refill() then return nil end
    local b = sbyte(buf, pos)
    pos = pos + 1
    return b
  end
  function r.bytes(n)
    local out, need = {}, n
    while need > 0 do
      if pos > #buf and not refill() then break end
      local take = math.min(need, #buf - pos + 1)
      out[#out + 1] = buf:sub(pos, pos + take - 1)
      pos = pos + take
      need = need - take
    end
    local s = table.concat(out)
    return #s > 0 and s or nil
  end
  function r.eof()
    if pos <= #buf then return false end
    return not refill()
  end
  return r
end

local function u16(s, p) local a, b = sbyte(s, p, p + 1) return a + b * 256 end
local function u32(s, p) local a, b, c, d = sbyte(s, p, p + 3) return a + b * 256 + c * 65536 + d * 16777216 end

---------------------------------------------------------------------------------------------------------------------
-- Video frame decoders. Each takes a byte source positioned at the start of one frame and returns the screen as three arrays
-- (symbols 0..31, foreground 0..15, background 0..15) plus the palette.
---------------------------------------------------------------------------------------------------------------------

local function readPalette(r)
  local palette = {}
  for i = 0, 15 do
    local a, b, c = r.byte(), r.byte(), r.byte()
    if not c then error("incomplete frame", 0) end
    palette[i] = { a / 255, b / 255, c / 255 }
  end
  return palette
end

--- Uncompressed frame: 5-bit symbols packed 8 per 5 bytes (most significant first), then one colour byte per cell
--- (high nibble background, low nibble foreground).
local function rawFrame(r, count)
  local text, fg, bg = {}, {}, {}
  local tokens = math.ceil(count / 8)
  local n = 0
  for _ = 1, tokens do
    local b1, b2, b3, b4, b5 = sbyte(r.bytes(5) or "", 1, 5)
    if not b5 then error("incomplete frame", 0) end
    local v = (((b1 * 256 + b2) * 256 + b3) * 256 + b4) * 256 + b5
    for k = 0, 7 do
      n = n + 1
      if n <= count then text[n] = floor(v / 2 ^ (35 - 5 * k)) % 32 end
    end
  end
  for i = 1, count do
    local c = r.byte()
    if not c then error("incomplete frame", 0) end
    fg[i], bg[i] = band(c, 15), rshift(c, 4)
  end
  return text, fg, bg
end

--- Canonical Huffman code from a table of code lengths (index -> length, 0 = unused). Returns lookup[length][code] = symbol, maxLength.
local function canonical(lengths, size)
  local list = {}
  for s = 0, size - 1 do if (lengths[s] or 0) > 0 then list[#list + 1] = { s = s, l = lengths[s] } end end
  table.sort(list, function(a, b) if a.l == b.l then return a.s < b.s end return a.l < b.l end)
  if #list == 0 then return nil end
  local lookup, code, maxLen = {}, 0, 0
  for i, e in ipairs(list) do
    if i > 1 then code = lshift(code + 1, e.l - list[i - 1].l) end
    lookup[e.l] = lookup[e.l] or {}
    lookup[e.l][code] = e.s
    if e.l > maxLen then maxLen = e.l end
  end
  return lookup, maxLen
end

local function huffmanLengths(r, size, fiveBit)
  local lengths = {}
  if fiveBit then
    for i = 0, size - 1, 2 do
      local b = r.byte()
      if not b then error("incomplete frame", 0) end
      lengths[i], lengths[i + 1] = rshift(b, 4), band(b, 15)
    end
  else
    -- legacy: 5 bits per length, 8 lengths per 5 bytes
    for i = 0, size - 1, 8 do
      local b1, b2, b3, b4, b5 = sbyte(r.bytes(5) or "", 1, 5)
      if not b5 then error("incomplete frame", 0) end
      local v = (((b1 * 256 + b2) * 256 + b3) * 256 + b4) * 256 + b5
      for k = 0, 7 do lengths[i + k] = floor(v / 2 ^ (35 - 5 * k)) % 32 end
    end
  end
  return lengths
end

--- A most-significant-bit-first reader on a byte source.
local function bitReader(r)
  local cur, left = 0, 0
  local b = {}
  function b.bit()
    if left == 0 then
      cur = r.byte()
      if not cur then error("incomplete frame", 0) end
      left = 8
    end
    left = left - 1
    return floor(cur / 2 ^ left) % 2
  end
  return b
end

--- Frame with per-frame Huffman coding ("custom" compression): a table of code lengths and the codes for the characters, then one for
--- the colours (24 symbols: 16 colours and 8 repeat symbols; foreground first, then background), then the palette.
local function huffmanFrame(r, count, fiveBit)
  local text, fg, bg = {}, {}, {}
  -- characters
  local lengths = huffmanLengths(r, fiveBit and 32 or 64, fiveBit)
  local lookup, maxLen = canonical(lengths, fiveBit and 32 or 64)
  if not lookup then
    local solid = r.byte()
    for i = 1, count do text[i] = solid end
  else
    local bits = bitReader(r)
    for i = 1, count do
      local code, len = 0, 0
      while true do
        code, len = code * 2 + bits.bit(), len + 1
        local tbl = lookup[len]
        if tbl and tbl[code] ~= nil then text[i] = tbl[code] break end
        if len > maxLen then error("invalid code", 0) end
      end
    end
    -- the character block ends on a byte boundary: nothing to skip because bitReader consumes whole bytes
  end
  -- colours
  local clengths = huffmanLengths(r, 24, true)
  local clookup, cmax = canonical(clengths, 24)
  if not clookup then
    local solid = r.byte()
    for i = 1, count do fg[i], bg[i] = solid, solid end
  else
    local bits = bitReader(r)
    local function plane(out)
      local last, i = 0, 1
      while i <= count do
        local code, len = 0, 0
        local sym
        while true do
          code, len = code * 2 + bits.bit(), len + 1
          local tbl = clookup[len]
          if tbl and tbl[code] ~= nil then sym = tbl[code] break end
          if len > cmax then error("invalid code", 0) end
        end
        if sym >= 16 then
          for _ = 1, 2 ^ (sym - 15) do
            if i <= count then out[i] = last i = i + 1 end
          end
        else
          out[i], last, i = sym, sym, i + 1
        end
      end
    end
    plane(fg)
    plane(bg)
  end
  return text, fg, bg
end

--- ANS (table-based asymmetric numeral systems) decoder state for one frame, after sanjuuni's reader. `init(isColor)` reads a symbol
--- table (the number of state bits R, then 4-bit codes: code c means that symbol owns 2^(c-1) of the 2^R states, 0 = unused); `read(n)` decodes
--- n symbols. With R = 0 every symbol equals the one byte that follows. Colour streams use symbols >= 16 as runs of 2^(s-15) copies.
local function ansDecoder(r)
  local self = {}
  local table_, X, isColor, partial, nbits

  local function readbits(n)
    if n == 0 then return 0 end
    while nbits < n do
      local b = r.byte()
      if not b then error("incomplete frame", 0) end
      partial, nbits = partial * 256 + b, nbits + 8
    end
    local value = floor(partial / 2 ^ (nbits - n)) % 2 ^ n
    nbits = nbits - n
    partial = partial % 2 ^ nbits
    return value
  end

  function self.init(color)
    isColor = color
    local R = r.byte()
    if not R then error("incomplete frame", 0) end
    local L = 2 ^ R
    local size = color and 24 or 32
    local Ls = {}
    for i = 0, size - 1, 2 do
      local b = r.byte()
      if not b then error("incomplete frame", 0) end
      Ls[i], Ls[i + 1] = rshift(b, 4), band(b, 15)
    end
    if R == 0 then
      table_ = r.byte()
      X = nil
      return
    end
    local total = 0
    for i = 0, size - 1 do
      Ls[i] = Ls[i] == 0 and 0 or 2 ^ (Ls[i] - 1)
      total = total + Ls[i]
    end
    if total ~= L then error("corrupt ANS table", 0) end
    table_ = {}
    local x, step, nxt, symbol = 0, 0.625 * L + 3, {}, {}
    for i = 0, size - 1 do
      nxt[i] = Ls[i]
      for _ = 1, Ls[i] do
        while symbol[x] do x = (x + 1) % L end
        symbol[x] = i
        x = (x + step) % L
      end
    end
    for xx = 0, L - 1 do
      local s = symbol[xx]
      local n = R - (select(2, math.frexp(nxt[s])) - 1)
      table_[xx] = { s = s, n = n, X = lshift(nxt[s], n) - L }
      nxt[s] = nxt[s] + 1
    end
    partial, nbits = 0, 0
    X = readbits(R)
  end

  function self.read(count)
    local out = {}
    if X == nil then
      for i = 1, count do out[i] = table_ end
      return out
    end
    local i, last = 1, 0
    while i <= count do
      local t = table_[X]
      if not t then error("corrupt ANS stream", 0) end
      if isColor and t.s >= 16 then
        for n = 0, 2 ^ (t.s - 15) - 1 do if i + n <= count then out[i + n] = last end end
        i = i + 2 ^ (t.s - 15)
      else
        out[i], last, i = t.s, t.s, i + 1
      end
      X = t.X + readbits(t.n)
    end
    return out
  end

  return self
end

local function ansFrame(r, count)
  local coder = ansDecoder(r)
  coder.init(false)
  local text = coder.read(count)
  coder.init(true)
  local bg = coder.read(count)         -- background first, then foreground (current sanjuuni)
  local fg = coder.read(count)
  return text, fg, bg
end

--- Turn symbol arrays into the strings of a blit image row by row.
local function toLines(text, fg, bg, width, height)
  local lines = {}
  for y = 0, height - 1 do
    local t, f, b = {}, {}, {}
    for x = 1, width do
      local i = y * width + x
      t[x] = schar(128 + (text[i] or 0))
      local fv, bv = (fg[i] or 0) % 16, (bg[i] or 0) % 16
      f[x], b[x] = HEX:sub(fv + 1, fv + 1), HEX:sub(bv + 1, bv + 1)
    end
    lines[y + 1] = { table.concat(t), table.concat(f), table.concat(b) }
  end
  return lines
end

---------------------------------------------------------------------------------------------------------------------
-- Reader
---------------------------------------------------------------------------------------------------------------------

local Video = {}
Video.__index = Video

local COMPRESSION = { [0] = "none", "ans", "deflate", "custom" }

--- Decode one video frame from the source `r` (positioned at its first byte).
local function decodeVideoFrame(self, r)
  local count = self.width * self.height
  local text, fg, bg
  local comp = band(self.flags, 3)
  if comp == 0 or comp == 2 then text, fg, bg = rawFrame(r, count)
  elseif comp == 3 then text, fg, bg = huffmanFrame(r, count, band(self.flags, 16) ~= 0)
  elseif comp == 1 then text, fg, bg = ansFrame(r, count) end
  local frame = toLines(text, fg, bg, self.width, self.height)
  frame.palette = readPalette(r)
  return frame
end

local function parseHeader(r)
  local magic = r.bytes(4)
  if magic ~= "32VD" then return nil, "not a 32vid file" end
  local rest = r.bytes(8)
  if not rest or #rest < 8 then return nil, "the 32vid file is incomplete" end
  local self = setmetatable({
    width = u16(rest, 1), height = u16(rest, 3), fps = sbyte(rest, 5), streamCount = sbyte(rest, 6), flags = u16(rest, 7),
    source = r, subtitles = {}, vframe = 0, audioQueue = {},
  }, Video)
  self.compression = COMPRESSION[band(self.flags, 3)]
  if self.width < 1 or self.height < 1 or self.fps < 1 then return nil, "the 32vid header is not valid" end
  return self
end

--- Open a stream of bytes (string source or handle source). Returns a reader or nil + reason.
local function begin(r)
  local self, err = parseHeader(r)
  if not self then return nil, err end
  -- the first stream tells us the layout
  local head = r.bytes(9)
  if not head or #head < 9 then return nil, "the 32vid file has no streams" end
  local size, count, kind = u32(head, 1), u32(head, 5), sbyte(head, 9)
  if kind == 12 then
    self.mode = "combo"
    self.frames = count
    return self
  end
  -- separate streams: video, audio and subtitles each in their own stream. Collect them (they have to be read in full).
  self.mode = "separate"
  local function loadStream(sz, n, k)
    local data = r.bytes(sz) or ""
    if #data < sz then error("the 32vid file is incomplete", 0) end
    if k == 0 then
      if band(self.flags, 3) == 2 then
        local inflate = require("tsr.inflate")
        local ok, raw = pcall(inflate.inflate, data, 1)
        if not ok then error("cannot unpack the video stream: " .. tostring(raw), 0) end
        data = raw
      end
      self.videoSource, self.videoFrames = stringSource(data), n
    elseif k == 1 or k == 2 or k == 3 then
      if not self.audioData then self.audioData = data end
    elseif k == 8 then
      local pos = 1
      for _ = 1, n do
        local frame, length = u32(data, pos), u32(data, pos + 4)
        local x, y, color = u16(data, pos + 8), u16(data, pos + 10), sbyte(data, pos + 12)
        local len = u16(data, pos + 14)
        local text = data:sub(pos + 16, pos + 15 + len)
        self.subtitles[#self.subtitles + 1] = { frame = frame, length = length, x = x, y = y, color = color, text = text }
        pos = pos + 16 + len
      end
    end
  end
  local ok, lerr = pcall(function()
    loadStream(size, count, kind)
    for _ = 2, self.streamCount do
      local h = r.bytes(9)
      if not h or #h < 9 then break end
      loadStream(u32(h, 1), u32(h, 5), sbyte(h, 9))
    end
  end)
  if not ok then return nil, tostring(lerr) end
  if not self.videoSource then return nil, "the file has no video stream" end
  self.frames = self.videoFrames
  return self
end

--- Decode audio bytes into samples (8-bit PCM -128..127 or DFPWM through cc.audio.dfpwm).
function Video:decodeAudio(data)
  if band(self.flags, 12) == 0 then
    local out = {}
    for i = 1, #data do out[i] = sbyte(data, i) - 128 end
    return out
  end
  local ok, dfpwm = pcall(require, "cc.audio.dfpwm")
  if not ok then return nil, "DFPWM audio needs cc.audio.dfpwm" end
  self.decoder = self.decoder or dfpwm.make_decoder()
  return self.decoder(data)
end

--- Audio of a file with separate streams, as a list of chunks of samples (about half a second each); nil for combined files (their audio comes from next()).
function Video:audioChunks()
  if self.mode ~= "separate" or not self.audioData then return nil end
  local chunks = {}
  local size = band(self.flags, 12) == 0 and 24000 or 3000
  for pos = 1, #self.audioData, size do
    local samples = self:decodeAudio(self.audioData:sub(pos, pos + size - 1))
    if samples then chunks[#chunks + 1] = samples end
  end
  return chunks
end

local function subtitlesFor(self)
  local active = {}
  for _, s in ipairs(self.subtitles) do
    if self.vframe >= s.frame and self.vframe < s.frame + s.length then active[#active + 1] = s end
  end
  return active
end

--- The next item of the file: "video", frame | "audio", samples | "subtitle", event; nil at the end. A frame carries .subtitles (the ones to show with it).
function Video:next()
  local r = self.source
  if self.mode == "separate" then
    if self.vframe >= self.videoFrames then return nil end
    local ok, frame = pcall(decodeVideoFrame, self, self.videoSource)
    if not ok then return nil, tostring(frame) end
    frame.subtitles = subtitlesFor(self)
    frame.index = self.vframe
    self.vframe = self.vframe + 1
    return "video", frame
  end
  if self.consumed and self.consumed >= self.frames then return nil end
  while true do
    local head = r.bytes(5)
    if not head or #head < 5 then return nil end
    self.consumed = (self.consumed or 0) + 1
    local size, kind = u32(head, 1), sbyte(head, 5)
    if kind == 0 then
      local ok, frame = pcall(decodeVideoFrame, self, r)
      if not ok then return nil, tostring(frame) end
      frame.subtitles = subtitlesFor(self)
      frame.index = self.vframe
      self.vframe = self.vframe + 1
      return "video", frame
    elseif kind == 1 or kind == 2 or kind == 3 then
      local data = r.bytes(size)
      if not data or #data < size then return nil, "incomplete audio frame" end
      local samples, err = self:decodeAudio(data)
      if samples then return "audio", samples end
      return nil, err
    elseif kind == 8 then
      local data = r.bytes(size)
      if not data or #data < 16 then return nil, "incomplete subtitle" end
      local len = u16(data, 15)
      local s = { frame = u32(data, 1), length = u32(data, 5), x = u16(data, 9), y = u16(data, 11), color = sbyte(data, 13), text = data:sub(17, 16 + len) }
      self.subtitles[#self.subtitles + 1] = s
      return "subtitle", s
    else
      -- index tables, multi-monitor frames and anything unknown: skip by size
      if size > 0 then r.bytes(size) end
      if self.consumed >= self.frames then return nil end
    end
  end
end

function Video:close()
  if self.handle and self.handle.close then self.handle.close() end
end

--- Open a 32vid file on disk (or a disk drive). Returns a reader or nil + reason.
function M.open(path)
  local h = fs.open(path, "rb")
  if not h then return nil, "cannot open " .. tostring(path) end
  local v, err = M.fromHandle(h)
  if not v then h.close() return nil, err end
  return v
end

--- A reader over an open binary handle (a file, or http.get(url, nil, true) for streaming).
function M.fromHandle(h)
  local v, err = begin(handleSource(h))
  if v then v.handle = h end
  return v, err
end

--- A reader over the bytes of a whole file.
function M.fromString(data) return begin(stringSource(data)) end

M.compressionName = function(flags) return COMPRESSION[band(flags, 3)] end

return M
