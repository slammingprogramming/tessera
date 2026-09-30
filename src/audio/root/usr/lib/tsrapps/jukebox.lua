-- SPDX-License-Identifier: AGPL-3.0-or-later
-- jukebox: a music player for speakers.
--   jukebox [path|url ...] [--volume 0-3] [--loop] [--shuffle] [--once]
-- Plays .dfpwm files (CC:T's audio format; convert other music at music.madefor.cc or with sanjuuni's tools). A folder
-- is played as a playlist; with no argument /music is used. Every attached speaker plays at once.
-- Keys:  n next   p previous   space pause   + / - volume   l loop   s shuffle   q quit
local cli = require("tsrapps.cli")
local dfpwm = require("cc.audio.dfpwm")

local M = {}

M.SPEC = { volume = "number", loop = "bool", shuffle = "bool", once = "bool" }
M.CHUNK = 16 * 1024

---------------------------------------------------------------------------------------------------------------------
-- Playlist
---------------------------------------------------------------------------------------------------------------------

--- Expand files, folders and URLs into an ordered list of sources.
function M.playlist(items)
  local out = {}
  local function add(path)
    if fs.isDir(path) then
      local names = fs.list(path)
      table.sort(names)
      for _, n in ipairs(names) do add((path:gsub("/$", "")) .. "/" .. n) end
    elseif path:lower():match("%.dfpwm$") then
      out[#out + 1] = path
    end
  end
  for _, item in ipairs(items) do
    if item:match("^https?://") then out[#out + 1] = item
    elseif fs.exists(item) then add(item) end
  end
  return out
end

function M.shuffle(list, rand)
  rand = rand or math.random
  for i = #list, 2, -1 do
    local j = rand(1, i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

--- A short title for a source.
function M.title(src)
  return (src:match("([^/]+)$") or src):gsub("%.dfpwm$", "")
end

--- Load the bytes of a source (file or URL). Returns data or nil + reason.
function M.load(src, env)
  if src:match("^https?://") then
    local h = ((env and env.http) or http)
    if not h then return nil, "HTTP is disabled" end
    local r = h.get(src, nil, true)
    if not r then return nil, "cannot download " .. src end
    local data = r.readAll()
    r.close()
    return data
  end
  local f = fs.open(src, "rb")
  if not f then return nil, "cannot read " .. src end
  local data = f.readAll()
  f.close()
  return data
end

---------------------------------------------------------------------------------------------------------------------
-- Playback
---------------------------------------------------------------------------------------------------------------------

--- Apply every queued control command. Returns "next", "prev" or "quit" when the track must end, else nil.
local function control(state, pullEvent)
  while true do
    local cmd = table.remove(state.queue, 1)
    if cmd == nil then return nil end
    if cmd == "next" or cmd == "prev" or cmd == "quit" then return cmd end
    if cmd == "volup" then state.volume = math.min(3, state.volume + 0.25)
    elseif cmd == "voldown" then state.volume = math.max(0, state.volume - 0.25)
    elseif cmd == "loop" then state.loop = not state.loop
    elseif cmd == "shuffle" then state.shuffle = not state.shuffle
    elseif cmd == "pause" then
      state.paused = true
      while state.paused do
        local c = table.remove(state.queue, 1)
        if c == "pause" then state.paused = false
        elseif c == "quit" or c == "next" or c == "prev" then state.paused = false return c
        elseif c == nil then pullEvent("tsr_audio_wake") end
      end
    end
  end
end

--- Play one track. Returns "done", "next", "prev" or "quit".
function M.playTrack(speakers, data, state, env)
  local decoder = dfpwm.make_decoder()
  local pullEvent = (env and env.pullEvent) or os.pullEvent
  local pos = 1
  while pos <= #data do
    local ended = control(state, pullEvent)
    if ended then return ended end
    local buffer = decoder(data:sub(pos, pos + M.CHUNK - 1))
    pos = pos + M.CHUNK
    for _, sp in ipairs(speakers) do
      while not sp.playAudio(buffer, state.volume) do
        pullEvent("speaker_audio_empty")
      end
    end
  end
  return "done"
end

--- Play a playlist. state: { volume, loop, shuffle, queue = {} }. Returns the number of tracks played.
function M.play(list, speakers, state, io, env)
  state.queue = state.queue or {}
  state.volume = state.volume or 1
  local index, played = 1, 0
  local order = list
  if state.shuffle then order = M.shuffle({ table.unpack(list) }, env and env.random) end
  while index >= 1 and index <= #order do
    local src = order[index]
    local data, err = M.load(src, env)
    if not data then
      io.warn(err)
      index = index + 1
    else
      io.say(("Now playing: %s (%d/%d)"):format(M.title(src), index, #order))
      local result = M.playTrack(speakers, data, state, env)
      played = played + 1
      if result == "quit" then break
      elseif result == "prev" then index = math.max(1, index - 1)
      else
        index = index + 1
        if index > #order and state.loop then index = 1 end
      end
    end
    if state.stopAfter and played >= state.stopAfter then break end
  end
  return played
end

--- Key reader: translates keypresses into commands for the player.
function M.keyLoop(state, env)
  local pull = (env and env.pullEvent) or os.pullEvent
  local map = { n = "next", p = "prev", [" "] = "pause", ["+"] = "volup", ["="] = "volup", ["-"] = "voldown",
                l = "loop", s = "shuffle", q = "quit" }
  while true do
    local _, ch = pull("char")
    local cmd = map[ch]
    if cmd then
      state.queue[#state.queue + 1] = cmd
      os.queueEvent("tsr_audio_wake")
      if cmd == "quit" then return end
    end
  end
end

function M.main(args, io, env)
  io = io or cli.io()
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  local per = (env and env.peripheral) or peripheral
  local speakers = { per.find("speaker") }
  if #speakers == 0 then io.err("No speaker attached.") return false end
  local items = #pos > 0 and pos or { "/music" }
  local list = M.playlist(items)
  if #list == 0 then io.err("Nothing to play: give .dfpwm files, folders or URLs (default folder: /music).") return false end
  local state = { volume = math.max(0, math.min(3, opts.volume or 1)), loop = opts.loop and not opts.once, shuffle = opts.shuffle, queue = {} }
  if env and env.noKeys then
    M.play(list, speakers, state, io, env)
    return true
  end
  io.say("Keys: n next, p previous, space pause, + / - volume, l loop, s shuffle, q quit")
  parallel.waitForAny(function() M.play(list, speakers, state, io, env) end, function() M.keyLoop(state, env) end)
  return true
end

return M
