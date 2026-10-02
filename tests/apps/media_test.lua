-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local media = require("tsr.media")
local image = require("tsr.gfx.image")

local DIR = "/tmp-media"

local function put(path, text, binary)
  local h = fs.open(path, binary and "wb" or "w")
  h.write(text)
  h.close()
end

local function fresh()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
end

local function win(w, h) return window.create(term.current(), 1, 1, w or 20, h or 6, false) end

local function frames(n)
  local out = {}
  for i = 1, n do out[i] = { { string.char(64 + i) .. string.char(64 + i), "00", "ff" } } end
  return out
end

--- A fake speaker that accepts a few buffers and then makes the caller wait for speaker_audio_empty.
local function speaker(acceptEvery)
  local sp = { buffers = {}, calls = 0 }
  function sp.playAudio(samples, volume)
    sp.calls = sp.calls + 1
    if acceptEvery and sp.calls % acceptEvery ~= 0 then return false end
    sp.buffers[#sp.buffers + 1] = { n = #samples, volume = volume }
    return true
  end
  return sp
end

test("files are classified by extension", function()
  eq(media.kind("a.bimg"), "video")
  eq(media.kind("B.NFP"), "picture")
  eq(media.kind("song.dfpwm"), "audio")
  eq(media.kind("clip.32vid"), "video")
  eq(media.kind("clip.mp4"), nil)
  eq(media.kind("readme"), nil)
end)

test("the library lists only playable files", function()
  fresh()
  put(DIR .. "/b.bimg", "x")
  put(DIR .. "/A.dfpwm", "xyz")
  put(DIR .. "/notes.txt", "n")
  fs.makeDir(DIR .. "/sub.bimg")
  local list = media.library(DIR)
  eq({ #list, list[1].name, list[1].kind, list[1].size, list[2].name, list[2].kind }, { 2, "A.dfpwm", "audio", 3, "b.bimg", "video" })
  eq(media.library("/nope"), {})
end)

test("a picture is drawn centred and waits for a key", function()
  fresh()
  put(DIR .. "/p.nfp", "0f\nf0\n")
  local t = win(10, 5)
  local events = { { "mouse_move" }, { "key", keys.space } }
  local i = 0
  local r = media.playVideo(DIR .. "/p.nfp", t, { pull = function() i = i + 1 return table.unpack(events[i]) end })
  eq(r, "stopped")
  eq(i, 2)
  local drawn = false
  for y = 1, 5 do if t.getLine(y):find("[\128-\159]") then drawn = true end end
  ok(drawn)
  -- centred: a 1x1 character picture on a 10x5 screen sits in the middle
  local row, col
  for y = 1, 5 do local pos = t.getLine(y):find("[\128-\159]") if pos then row, col = y, pos end end
  eq({ row, col }, { 3, 5 })
end)

test("a picture can be shown for a fixed time", function()
  fresh()
  put(DIR .. "/p.nfp", "0f\n")
  local t = win(10, 5)
  local r
  parallel.waitForAll(
    function() r = media.playVideo(DIR .. "/p.nfp", t, { duration = 0.2 }) end,
    function() end)
  eq(r, "done")
end)

test("a BIMG animation plays its frames in order at its own speed", function()
  fresh()
  put(DIR .. "/v.bimg", image.toBimg(frames(3), { secondsPerFrame = 0.05 }))
  local t = win(10, 3)
  local seen = {}
  local r
  local start = os.clock()
  parallel.waitForAll(
    function()
      -- sample the screen whenever a frame timer fires
      r = media.playVideo(DIR .. "/v.bimg", t, {
        center = false,
        pull = function()
          local ev, a = os.pullEvent()
          if ev == "timer" then seen[#seen + 1] = t.getLine(1):sub(1, 2) end
          return ev, a
        end,
      })
    end,
    function() end)
  eq(r, "done")
  eq(seen, { "AA", "BB", "CC" }, "each frame was on screen when the next timer fired")
  ok(os.clock() - start >= 0.1)
end)

test("an animation loops until interrupted", function()
  fresh()
  put(DIR .. "/v.bimg", image.toBimg(frames(2), { secondsPerFrame = 0.05 }))
  local t = win(10, 3)
  local r
  parallel.waitForAll(
    function() r = media.playVideo(DIR .. "/v.bimg", t, { loop = true, center = false }) end,
    function() sleep(0.3) os.queueEvent("char", "q") end)
  eq(r, "stopped")
  -- the stop callback works too
  local stop = false
  parallel.waitForAll(
    function() r = media.playVideo(DIR .. "/v.bimg", t, { loop = true, center = false, stop = function() return stop end }) end,
    function() sleep(0.2) stop = true end)
  eq(r, "stopped")
end)

test("bad files are reported", function()
  fresh()
  put(DIR .. "/bad.bimg", "{ nonsense")
  local r, err = media.playVideo(DIR .. "/bad.bimg", win())
  ok(r == nil and err)
  r, err = media.playVideo(DIR .. "/missing.bimg", win())
  ok(r == nil and err:find("cannot open"))
  r, err = media.play(DIR .. "/x.txt", {})
  ok(r == nil and err:find("not a media file"))
  r, err = media.play(DIR .. "/missing.nfp", {})
  ok(r == nil and err:find("no such file"))
  r, err = media.playAudio(DIR .. "/missing.dfpwm", { speaker() })
  ok(r == nil and err:find("cannot open"))
  r, err = media.playAudio(DIR .. "/x.dfpwm", {})
  ok(r == nil and err:find("no speaker"))
end)

test("audio is decoded in chunks and sent to every speaker, waiting when they are full", function()
  fresh()
  put(DIR .. "/a.dfpwm", string.rep("\85", media.AUDIO_CHUNK * 2 + 100), true)
  local a, b = speaker(), speaker(2)         -- b accepts every second offer
  local events = 0
  local r = media.playAudio(DIR .. "/a.dfpwm", { a, b }, { volume = 2, pull = function() events = events + 1 return "speaker_audio_empty" end })
  eq(r, "done")
  eq(#a.buffers, 3)
  eq(#b.buffers, 3)
  eq(a.buffers[1].n, media.AUDIO_CHUNK * 8, "DFPWM expands to 8 samples per byte")
  eq(a.buffers[1].volume, 2)
  ok(events > 0, "it waited for the speaker to drain")
  -- stopping early
  local c = speaker()
  local n = 0
  r = media.playAudio(DIR .. "/a.dfpwm", { c }, { stop = function() n = n + 1 return n > 1 end })
  eq(r, "stopped")
  ok(#c.buffers < 3)
end)

test("a video plays together with its .dfpwm soundtrack", function()
  fresh()
  put(DIR .. "/v.bimg", image.toBimg(frames(2), { secondsPerFrame = 0.05 }))
  put(DIR .. "/v.dfpwm", string.rep("\85", 2000), true)
  local sp = speaker()
  local result
  parallel.waitForAll(
    function() result = media.play(DIR .. "/v.bimg", { term = win(10, 3), speakers = { sp } }) end,
    function() end)
  eq(result, "done")
  ok(#sp.buffers >= 1, "the soundtrack played")
end)

test("the play command", function()
  fresh()
  put(DIR .. "/p.nfp", "0f\n")
  put(DIR .. "/song.dfpwm", string.rep("\85", 500), true)
  local sp = speaker()
  local mon = win(10, 4)
  local per = F.peripheralApi({ speaker_0 = (function() sp._type = "speaker" return sp end)(), screen = (function() mon._type = "monitor" return mon end)() })
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local events = { { "key", keys.space } }
    local r = media.run({ ... }, io, { peripheral = per, noShell = true, term = win(10, 4), noClear = true,
                                       pull = function() return table.unpack(table.remove(events, 1) or { "key", keys.q }) end })
    return r, table.concat(io.said, "\n"), table.concat(io.errs, "\n")
  end
  local r, text = run("list", DIR)
  ok(r and text:find("song.dfpwm", 1, true) and text:find("picture", 1, true), text)
  r = run(DIR .. "/song.dfpwm", "--volume", "1.5")
  ok(r)
  eq(sp.buffers[1].volume, 1.5)
  r = run(DIR .. "/p.nfp", "--monitor", "screen")
  ok(r)
  local drawn = false
  for y = 1, 4 do if mon.getLine(y):find("[\128-\159]") then drawn = true end end
  ok(drawn, "drawn on the monitor")
  local bad, _, err = run(DIR .. "/p.nfp", "--monitor", "ghost")
  ok(bad == false and err:find("no monitor"))
  eq(run(), false)
  bad, _, err = run(DIR .. "/none.nfp")
  ok(bad == false and err:find("no such file"))
end)
