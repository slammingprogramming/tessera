-- SPDX-License-Identifier: AGPL-3.0-or-later
local vid32 = require("tsr.media.vid32")
local hash = require("tsr.hash")
local fx = dofile("/tests/fixtures/vid32_fixtures.lua")

local function bytes(file) return hash.base64Decode(file.b64) end

--- Decode a whole file. Returns { video = { frames }, audio = { chunks }, subtitles = { events } } or nil + reason.
local function drain(v, limit)
  local out = { video = {}, audio = {}, subtitles = {} }
  for _ = 1, limit or 1000 do
    local kind, data = v:next()
    if not kind then return out, data end
    if kind == "video" then out.video[#out.video + 1] = data
    elseif kind == "audio" then out.audio[#out.audio + 1] = data
    elseif kind == "subtitle" then out.subtitles[#out.subtitles + 1] = data end
  end
  return out
end

local function sameFrame(got, want, label)
  eq(#got, #want.lines, label .. ": rows")
  for y, row in ipairs(want.lines) do
    eq(got[y][1], row[1], label .. ": text of row " .. y)
    eq(got[y][2], row[2], label .. ": foreground of row " .. y)
    eq(got[y][3], row[3], label .. ": background of row " .. y)
  end
  for i = 0, 15 do
    for c = 1, 3 do eq(got.palette[i][c], want.palette[i + 1][c] / 255, label .. ": palette " .. i) end
  end
end

for _, file in ipairs(fx.files) do
  test("32vid " .. file.name .. ": header, every frame, audio and subtitles", function()
    local v, err = vid32.fromString(bytes(file))
    ok(v, err)
    eq(v.width, fx.width)
    eq(v.height, fx.height)
    ok(v.fps >= 8)
    local got, derr = drain(v)
    eq(derr, nil)
    eq(#got.video, file.frames)
    for i = 1, file.frames do sameFrame(got.video[i], fx.expected[i], "frame " .. i) end
    if v.mode == "combo" then
      local wanted = {}
      for i = 1, file.frames do if fx.audio[i] then wanted[#wanted + 1] = fx.audio[i] end end
      eq(#got.audio, #wanted, "audio chunks")
      for i, chunk in ipairs(wanted) do
        eq(#got.audio[i], #chunk)
        eq(got.audio[i][1], chunk:byte(1) - 128)
        eq(got.audio[i][#chunk], chunk:byte(#chunk) - 128)
      end
    else
      local chunks = v:audioChunks()
      if file.name == "separate uncompressed" then
        ok(chunks and #chunks >= 1)
        local total = 0
        for _, c in ipairs(chunks) do total = total + #c end
        eq(total, 900)
      end
    end
    -- subtitles are attached to the frames they belong to
    if file.name ~= "separate DEFLATE" and file.name ~= "separate ANS" and file.name ~= "combo uncompressed" then
      eq(#got.video[2].subtitles, 1)
      eq(got.video[2].subtitles[1].text, "hello 32vid")
      eq(#got.video[3].subtitles, 1, "a subtitle lasts for 2 frames")
      eq(#got.video[4].subtitles, 1)
      eq(got.video[4].subtitles[1].text, "bye")
      eq(#got.video[1].subtitles, 0)
      eq(#got.video[5].subtitles, 0)
    end
  end)
end

test("the ANS decoder agrees with sanjuuni's own reference reader (lib32vid) on every frame", function()
  local okRef, ref = pcall(dofile, "/tests/lib/ref_lib32vid.lua")
  if not okRef then skip("the reference library needs string.unpack and cc.audio.dfpwm: " .. tostring(ref)) end
  local file
  for _, f in ipairs(fx.files) do if f.name == "combo ANS" then file = f end end
  local good, reader = pcall(ref.load, bytes(file))
  if not good then skip("reference reader unavailable here: " .. tostring(reader)) end
  local mine = assert(vid32.fromString(bytes(file)))
  local frames = 0
  while true do
    local k1, d1 = reader:next()
    local k2, d2 = mine:next()
    eq(k1, k2, "same kind of item")
    if not k1 then break end
    if k1 == "video" then
      frames = frames + 1
      for y = 1, fx.height do
        eq(d2[y][1], d1[y][1], "text, frame " .. frames .. " row " .. y)
        eq(d2[y][2], d1[y][2], "foreground")
        eq(d2[y][3], d1[y][3], "background")
      end
      for i = 0, 15 do for c = 1, 3 do eq(d2.palette[i][c], d1.palette[i][c]) end end
    elseif k1 == "audio" then
      eq(#d2, #d1)
      eq(d2[1], d1[1])
    end
  end
  eq(frames, 5)
end)

test("damaged and foreign files are refused or stop cleanly", function()
  local v, err = vid32.fromString("not a video")
  ok(v == nil and err:find("not a 32vid", 1, true), tostring(err))
  v, err = vid32.fromString("32VD")
  ok(v == nil)
  local file
  for _, f in ipairs(fx.files) do if f.name == "combo ANS" then file = f end end
  local data = bytes(file)
  local cut = assert(vid32.fromString(data:sub(1, 300)))
  local got, derr = drain(cut)
  ok(#got.video < 5, "a truncated file ends early")
  local zero = data:sub(1, 12) .. string.rep("\0", 8) .. data:sub(21)
  ok(select(2, pcall(function() return vid32.fromString(zero) end)) ~= nil)
  -- bad header values
  local badHeader = "32VD" .. string.char(0, 0, 10, 0, 10, 1, 16, 0)
  ok(vid32.fromString(badHeader) == nil)
end)

test("a file can be read from a handle (disk drive / HTTP) in blocks", function()
  local path = "/tmp-vid32.32v"
  local file
  for _, f in ipairs(fx.files) do if f.name == "combo custom Huffman" then file = f end end
  local h = fs.open(path, "wb") h.write(bytes(file)) h.close()
  local v, err = vid32.open(path)
  ok(v, err)
  local got = drain(v)
  eq(#got.video, 5)
  sameFrame(got.video[3], fx.expected[3], "frame 3 from a file")
  v:close()
  fs.delete(path)
  ok(select(2, vid32.open("/nothing.32v")))
end)

local media = require("tsr.media")

--- A terminal that records what is drawn.
local function fakeTerm(w, h)
  local t = { rows = {}, palette = {}, cur = { 1, 1 }, cleared = 0 }
  function t.getSize() return w, h end
  function t.setBackgroundColor() end
  function t.clear() t.cleared = t.cleared + 1 end
  function t.setCursorPos(x, y) t.cur = { x, y } end
  function t.blit(text, fg, bg) t.rows[t.cur[2]] = { x = t.cur[1], text = text, fg = fg, bg = bg } end
  function t.setPaletteColor(c, r, g, b) t.palette[c] = { r, g, b } end
  function t.nativePaletteColor(c) return 0.5, 0.5, 0.5 end
  return t
end

local function fileOf(name)
  for _, f in ipairs(fx.files) do if f.name == name then return f end end
end

test("the media player recognises and plays 32vid files: frames, palette, sound, pacing", function()
  eq(media.kind("show.32vid"), "video")
  eq(media.kind("show.32v"), "video")
  local path = "/tmp-show.32vid"
  local h = fs.open(path, "wb") h.write(bytes(fileOf("combo ANS"))) h.close()
  local t = fakeTerm(40, 20)
  local audio = {}
  local sp = { playAudio = function(samples, volume) audio[#audio + 1] = #samples return true end }
  local now = 1000000
  -- the clock moves 100 ms every time the player asks to wait, so pacing waits are short; timers fire at once
  local result, err = media.play32vid(path, t, {
    speakers = { sp },
    clock = function() now = now + 100 return now end,
    pull = function() local ev, id = os.pullEvent("timer") return ev, id end,
  })
  eq(result, "done", tostring(err))
  eq(audio, { 480, 240, 120 }, "the three audio chunks of the file reached the speaker")
  -- the last frame is on screen, centred: (40-24)/2+1 = 9, (20-10)/2+1 = 6
  eq(t.rows[6].x, 9)
  eq(#t.rows[6].text, 24)
  eq(t.rows[6].text, fx.expected[5].lines[1][1])
  eq(t.palette[1][1], 0.5, "the palette is restored to the native colours at the end")
  fs.delete(path)
end)

test("32vid playback stops on a key and refuses missing or damaged files", function()
  local path = "/tmp-show2.32vid"
  local h = fs.open(path, "wb") h.write(bytes(fileOf("combo custom Huffman"))) h.close()
  local t = fakeTerm(30, 12)
  local result = media.play32vid(path, t, { pull = function() return "key", 30 end, clock = function() return 0 end })
  eq(result, "stopped")
  local none, err = media.play32vid("/tmp-nothing.32vid", t, {})
  ok(none == nil and err:find("cannot open", 1, true), tostring(err))
  h = fs.open(path, "wb") h.write("garbage") h.close()
  none, err = media.play32vid(path, t, {})
  ok(none == nil and err:find("not a 32vid", 1, true), tostring(err))
  fs.delete(path)
  ok(select(2, media.play("/tmp-nothing.32vid", {})) ~= nil)
end)
