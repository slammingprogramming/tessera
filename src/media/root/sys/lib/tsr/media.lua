-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Media playback.
--   .bimg   pictures and videos in "blit image" format (sanjuuni's default output; several frames = an animation)
--   .nfp    pictures from the paint program
--   .dfpwm  audio for speakers (a video's sound is the .dfpwm file next to it with the same name)
--   (32vid, sanjuuni's compressed video container, is not supported yet: convert with `sanjuuni --bimg`.)
--   play <file> [--monitor name] [--loop]     play list [folder]
local image = require("tsr.gfx.image")

local M = {}

M.AUDIO_CHUNK = 16 * 1024

local KINDS = { bimg = "video", nfp = "picture", dfpwm = "audio" }

--- "video" (BIMG), "picture" (NFP) or "audio" (DFPWM) from the file name, or nil.
function M.kind(path)
  local ext = tostring(path):match("%.(%w+)$")
  return ext and KINDS[ext:lower()] or nil
end

--- Files in `dir` that can be played: { name, path, kind, size }, sorted by name.
function M.library(dir)
  local out = {}
  if not fs.isDir(dir) then return out end
  for _, name in ipairs(fs.list(dir)) do
    local path = dir .. "/" .. name
    if not fs.isDir(path) then
      local kind = M.kind(name)
      if kind then out[#out + 1] = { name = name, path = path, kind = kind, size = fs.getSize(path) } end
    end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

local function interrupted(ev, a)
  return ev == "key" or ev == "mouse_click" or ev == "monitor_touch" or ev == "tv_key" or (ev == "char" and a == "q")
end

--- Show a picture or play a BIMG animation on terminal `t`. opts: loop, interruptible (default true), pull (event source, tests),
--- stop (function -> true to stop early), center (default true), duration (seconds; ends the show, "done"), once (draw and return).
--- Returns "done" or "stopped".
function M.playVideo(path, t, opts)
  opts = opts or {}
  local img, err = image.load(path)
  if not img then return nil, err end
  local pull = opts.pull or function() return os.pullEvent() end
  local tw, th = t.getSize()
  local cw, ch = img:charSize()
  local x, y = 1, 1
  if opts.center ~= false then x, y = math.max(1, math.floor((tw - cw) / 2) + 1), math.max(1, math.floor((th - ch) / 2) + 1) end
  t.setBackgroundColor(colors.black)
  t.clear()
  local frames = (img.kind == "bimg") and #img.frames or 1
  local endTimer = opts.duration and os.startTimer(opts.duration)
  if frames == 1 then
    img:draw(t, x, y, 1)
    if opts.once then return "done" end
    while true do
      local ev, a = pull()
      if opts.interruptible ~= false and interrupted(ev, a) then return "stopped" end
      if opts.stop and opts.stop() then return "stopped" end
      if endTimer and ev == "timer" and a == endTimer then return "done" end
    end
  end
  local frame = 1
  local delay = img.secondsPerFrame or 0.1
  local timer = os.startTimer(delay)
  while true do
    img:draw(t, x, y, frame)
    local ev, a
    repeat
      ev, a = pull()
      if opts.interruptible ~= false and interrupted(ev, a) then return "stopped" end
      if opts.stop and opts.stop() then return "stopped" end
      if endTimer and ev == "timer" and a == endTimer then return "done" end
    until ev == "timer" and a == timer
    frame = frame + 1
    if frame > frames then
      if opts.loop then frame = 1 else return "done" end
    end
    timer = os.startTimer(delay)
  end
end

--- Play a .dfpwm file on the given speakers (all play the same stream). opts: volume (0-3, default 1), stop, decoder (tests),
--- pull. Returns "done" or "stopped".
function M.playAudio(path, speakers, opts)
  opts = opts or {}
  if #speakers == 0 then return nil, "no speaker available" end
  local h = fs.open(path, "rb")
  if not h then return nil, "cannot open " .. tostring(path) end
  local decoder = opts.decoder or require("cc.audio.dfpwm").make_decoder()
  local pull = opts.pull or function() return os.pullEvent() end
  local volume = opts.volume or 1
  while true do
    local chunk = h.read(M.AUDIO_CHUNK)
    if not chunk then break end
    local samples = decoder(chunk)
    for _, sp in ipairs(speakers) do
      while not sp.playAudio(samples, volume) do
        local ev, a = pull()
        if ev == "key" and a == keys.q then h.close() return "stopped" end
        if opts.stop and opts.stop() then h.close() return "stopped" end
      end
    end
    if opts.stop and opts.stop() then h.close() return "stopped" end
  end
  h.close()
  return "done"
end

--- Play whatever `path` is. opts: term, speakers (array), loop, volume, pull. A video is accompanied by the .dfpwm file with the same
--- name if one exists. Returns "done" / "stopped", or nil + reason.
function M.play(path, opts)
  opts = opts or {}
  local kind = M.kind(path)
  if not kind then return nil, "not a media file I can play (bimg, nfp, dfpwm)" end
  if not fs.exists(path) then return nil, "no such file: " .. tostring(path) end
  if kind == "audio" then return M.playAudio(path, opts.speakers or {}, opts) end
  local t = opts.term or term.current()
  local companion = path:gsub("%.%w+$", ".dfpwm")
  local speakers = opts.speakers or {}
  if kind == "video" and #speakers > 0 and fs.exists(companion) then
    local result
    local stopFlag = false
    parallel.waitForAny(
      function() result = M.playVideo(path, t, { loop = opts.loop, stop = function() return stopFlag end, pull = opts.pull }) end,
      function() M.playAudio(companion, speakers, { volume = opts.volume, stop = function() return stopFlag end, pull = opts.pull }) end)
    stopFlag = true
    return result or "done"
  end
  return M.playVideo(path, t, opts)
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

--- play <file> [--monitor name] [--loop] [--volume n] | play list [folder]
function M.run(args, io, env)
  io = io or defaultIO()
  env = env or {}
  local per = env.peripheral or peripheral
  if args[1] == "list" then
    local list = M.library(args[2] or "/media")
    if #list == 0 then io.say("No playable files.") end
    for _, f in ipairs(list) do io.say(("%-8s %-28s %d B"):format(f.kind, f.name, f.size)) end
    return true
  end
  local file, monitor, loop, volume
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--monitor" then monitor = args[i + 1] i = i + 2
    elseif a == "--loop" then loop = true i = i + 1
    elseif a == "--volume" then volume = tonumber(args[i + 1]) i = i + 2
    else file = file or a i = i + 1 end
  end
  if not file then io.err("usage: play <file> [--monitor name] [--loop] [--volume 0-3]   |   play list [folder]") return false end
  local t = env.term or term.current()
  if monitor then
    t = per.wrap(monitor)
    if not t then io.err("no monitor named " .. monitor) return false end
  end
  local speakers = {}
  for _, name in ipairs(per.getNames()) do
    if per.getType(name) == "speaker" then speakers[#speakers + 1] = per.wrap(name) end
  end
  local path = (rawget(_G, "shell") and not env.noShell) and shell.resolve(file) or file
  local result, err = M.play(path, { term = t, speakers = speakers, loop = loop, volume = volume, pull = env.pull })
  if not result then io.err(tostring(err)) return false end
  if not monitor and not env.noClear then
    t.setBackgroundColor(colors.black)
    t.clear()
    t.setCursorPos(1, 1)
  end
  return true
end

function M.main(args) return M.run(args) end

return M
