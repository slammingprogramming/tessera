-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local jukebox = require("tsrapps.jukebox")

local function track(bytes)
  -- any byte string is valid DFPWM
  local t = {}
  for i = 1, bytes do t[i] = string.char((i * 37) % 256) end
  return table.concat(t)
end

local function speaker(opts)
  opts = opts or {}
  local sp = { _type = "speaker", calls = {}, volumes = {}, rejectFirst = opts.rejectFirst }
  function sp.playAudio(buffer, volume)
    if sp.rejectFirst then
      sp.rejectFirst = false
      os.queueEvent("speaker_audio_empty")
      return false
    end
    sp.calls[#sp.calls + 1] = #buffer
    sp.volumes[#sp.volumes + 1] = volume
    return true
  end
  return sp
end

local function setup()
  fs.delete("/tmp-music")
  fs.makeDir("/tmp-music/sub")
  local function put(p, n) local h = fs.open(p, "wb") h.write(track(n)) h.close() end
  put("/tmp-music/b.dfpwm", 40000)
  put("/tmp-music/a.dfpwm", 10000)
  put("/tmp-music/sub/c.DFPWM", 5000)
  local h = fs.open("/tmp-music/notes.txt", "w") h.write("not music") h.close()
end

test("playlist expands folders, sorts, filters by extension and keeps URLs", function()
  setup()
  local list = jukebox.playlist({ "/tmp-music", "https://example.org/x.dfpwm", "/missing" })
  eq(list, { "/tmp-music/a.dfpwm", "/tmp-music/b.dfpwm", "/tmp-music/sub/c.DFPWM", "https://example.org/x.dfpwm" })
  eq(jukebox.playlist({ "/tmp-music/notes.txt" }), {})
  fs.delete("/tmp-music")
end)

test("title and shuffle", function()
  eq(jukebox.title("/music/Song One.dfpwm"), "Song One")
  eq(jukebox.title("https://h/x/y.dfpwm"), "y")
  local list = jukebox.shuffle({ 1, 2, 3, 4 }, function(lo, hi) return lo end)
  eq(#list, 4)
  local sum = 0
  for _, v in ipairs(list) do sum = sum + v end
  eq(sum, 10)
end)

test("a track is decoded and sent to the speaker in chunks", function()
  local sp = speaker()
  local state = { volume = 1, queue = {} }
  local data = track(40000)
  eq(jukebox.playTrack({ sp }, data, state), "done")
  eq(#sp.calls, math.ceil(40000 / jukebox.CHUNK))
  eq(sp.calls[1], jukebox.CHUNK * 8, "1 bit per sample")
  eq(sp.volumes[1], 1)
end)

test("a full speaker buffer makes the player wait for speaker_audio_empty", function()
  local sp = speaker({ rejectFirst = true })
  local state = { volume = 1, queue = {} }
  eq(jukebox.playTrack({ sp }, track(20000), state), "done")
  eq(#sp.calls, 2)
end)

test("several speakers all receive the audio", function()
  local a, b = speaker(), speaker()
  jukebox.playTrack({ a, b }, track(20000), { volume = 1, queue = {} })
  eq(#a.calls, #b.calls)
  ok(#a.calls > 0)
end)

test("controls: volume, next, prev and quit", function()
  local sp = speaker()
  local state = { volume = 1, queue = { "volup", "volup" } }
  jukebox.playTrack({ sp }, track(40000), state)
  eq(sp.volumes[1], 1.5)
  state = { volume = 1, queue = { "next" } }
  eq(jukebox.playTrack({ speaker() }, track(40000), state), "next")
  state = { volume = 1, queue = { "prev" } }
  eq(jukebox.playTrack({ speaker() }, track(40000), state), "prev")
  state = { volume = 1, queue = { "quit" } }
  eq(jukebox.playTrack({ speaker() }, track(40000), state), "quit")
end)

test("volume is clamped", function()
  local state = { volume = 2.9, queue = { "volup", "volup", "volup" } }
  jukebox.playTrack({ speaker() }, track(80000), state)
  eq(state.volume, 3)
  state = { volume = 0.1, queue = { "voldown", "voldown" } }
  jukebox.playTrack({ speaker() }, track(80000), state)
  eq(state.volume, 0)
end)

test("pause waits until resumed", function()
  local sp = speaker()
  local state = { volume = 1, queue = { "pause" } }
  local woke = false
  local env = { pullEvent = function(name)
    if name == "tsr_audio_wake" then woke = true state.queue[#state.queue + 1] = "pause" return end
    return os.pullEvent(name)
  end }
  eq(jukebox.playTrack({ sp }, track(20000), state, env), "done")
  ok(woke, "the player waited while paused")
  eq(#sp.calls, 2)
end)

test("play walks the playlist, loops and reports unreadable tracks", function()
  setup()
  local io = F.io()
  local sp = speaker()
  local list = { "/tmp-music/a.dfpwm", "/tmp-music/missing.dfpwm", "/tmp-music/sub/c.DFPWM" }
  local state = { volume = 1, queue = {} }
  eq(jukebox.play(list, { sp }, state, io), 2)
  ok(io.said[1]:find("Now playing: a") and io.said[1]:find("1/3"))
  ok(io.warned[1]:find("cannot read"))
  local looping = { volume = 1, queue = {}, loop = true, stopAfter = 5 }
  eq(jukebox.play({ "/tmp-music/a.dfpwm" }, { speaker() }, looping, F.io()), 5)
  local q = { volume = 1, queue = { "quit" } }
  eq(jukebox.play(list, { speaker() }, q, F.io()), 1)
  local prev = { volume = 1, queue = {}, stopAfter = 3 }
  table.insert(prev.queue, "next")
  fs.delete("/tmp-music")
end)

test("main validates speakers and sources", function()
  setup()
  local none = F.io()
  eq(jukebox.main({ "/tmp-music" }, none, { peripheral = F.peripheralApi({}), noKeys = true }), false)
  ok(none.errs[1]:find("No speaker"))
  local sp = speaker()
  local env = { peripheral = F.peripheralApi({ speaker_1 = sp }), noKeys = true }
  local empty = F.io()
  eq(jukebox.main({ "/tmp-music/notes.txt" }, empty, env), false)
  ok(empty.errs[1]:find("Nothing to play"))
  local io = F.io()
  ok(jukebox.main({ "/tmp-music/a.dfpwm", "--volume", "2" }, io, env))
  eq(sp.volumes[1], 2)
  eq(jukebox.main({ "--volume" }, F.io(), env), false)
  fs.delete("/tmp-music")
end)

test("URLs are downloaded through the http API", function()
  local served = track(2000)
  local fakeHttp = { get = function(url, headers, binary)
    if url == "https://example.org/song.dfpwm" and binary then
      return { readAll = function() return served end, close = function() end }
    end
  end }
  eq(jukebox.load("https://example.org/song.dfpwm", { http = fakeHttp }), served)
  local data, err = jukebox.load("https://example.org/missing.dfpwm", { http = fakeHttp })
  ok(data == nil and err:find("cannot download"))
  data, err = jukebox.load("https://x/y.dfpwm", { http = nil })
  ok(data == nil)
end)
