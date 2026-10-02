-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The netmon command:
--   netmon [options]                 watch the messages that this computer sends and receives (the network daemon, ssh, torrent... keep
--                                    reading; netmon looks over their shoulder)
--   netmon sniff [first-last]        promiscuous mode: listen for rednet traffic between OTHER computers in range, on the channels of the
--                                    computer ids first..last (default 1-30) and on the broadcast channel
--   netmon read <file>               show a capture saved with --save
-- options:  --type a,b   only these kinds (e.g. ssh,rpc,p2p)    --peer 5,7   only these computers    --drops   only messages the firewall refused
--           --count n    stop after n messages                   --seconds n  stop after n seconds      --save <file>   keep the capture
--           --summary    print totals by kind and computer at the end (always printed when the run ends)
-- Only administrators may run it when accounts exist: what it shows can include who talks to whom.
local netmon = require("tsr.netmon")
local vfs = require("tsr.vfs")

local M = {}

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor and term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  function io.pull(timeout)
    local timer = os.startTimer(timeout)
    while true do
      local ev = { os.pullEventRaw() }
      if ev[1] == "timer" and ev[2] == timer then return nil end
      if ev[1] == "terminate" then return { "terminate" } end
      if ev[1] == "modem_message" then os.cancelTimer(timer) return ev end
      if ev[1] == "tsr_netmon_wake" then os.cancelTimer(timer) return ev end
    end
  end
  return io
end

local function admin(io)
  local okAuth, auth = pcall(require, "tsr.auth")
  if not okAuth or not auth.hasUsers() then return true end
  local me = auth.current()
  if me == nil or auth.can(me, "auth.manage") then return true end
  io.err("only administrators can watch the network")
  return false
end

local function set(text, convert)
  local s = {}
  for item in tostring(text):gmatch("[^,]+") do s[convert and convert(item) or item] = true end
  return s
end

function M.run(args, io, node)
  io = io or defaultIO()
  if not admin(io) then return false end
  local mode = "node"
  local filter = {}
  local count, seconds, savePath
  local first, last = 1, 30
  local i = 1
  if args[1] == "read" then
    local path = args[2]
    if not path then io.err("usage: netmon read <file>") return false end
    local mon, err = netmon.load(vfs.normalize(path))
    if not mon then io.err(tostring(err)) return false end
    local base = mon.records[1] and mon.records[1].at or 0
    for _, r in ipairs(mon.records) do io.say(netmon.format(r, base)) end
    for _, l in ipairs(mon:summary()) do io.say(l) end
    return true
  elseif args[1] == "sniff" then
    mode = "sniff"
    i = 2
    local range = args[2]
    if range and not range:match("^%-%-") then
      local a, b = range:match("^(%d+)%-(%d+)$")
      if a then first, last = tonumber(a), tonumber(b)
      elseif range:match("^%d+$") then first, last = tonumber(range), tonumber(range)
      else io.err("netmon: the channel range looks like 1-30") return false end
      i = 3
    end
    if last - first > 100 then io.err("netmon: at most 100 channels at a time (a modem opens 128)") return false end
  end
  while i <= #args do
    local a = args[i]
    if a == "--type" then i = i + 1 filter.types = set(args[i] or "")
    elseif a == "--peer" then i = i + 1 filter.peers = set(args[i] or "", tonumber)
    elseif a == "--drops" then filter.dropsOnly = true
    elseif a == "--count" then i = i + 1 count = tonumber(args[i])
    elseif a == "--seconds" then i = i + 1 seconds = tonumber(args[i])
    elseif a == "--save" then i = i + 1 savePath = args[i]
    elseif a == "--summary" then -- always printed
    else io.err("netmon: unknown option " .. a) return false end
    i = i + 1
  end
  local startAt = os.clock()
  local shown = 0
  local mon
  local function onRecord(rec)
    shown = shown + 1
    io.say(netmon.format(rec, startAt))
  end
  if mode == "sniff" then
    local channels = { 65535 }
    for ch = first, last do channels[#channels + 1] = ch end
    local opened
    mon, opened = netmon.sniffer({ channels = channels, filter = filter, onRecord = onRecord })
    if opened == 0 then io.err("netmon: no modem to listen with") return false end
    io.say(("Listening on %d channel(s) (computers %d-%d and broadcast). Press Ctrl+T to stop."):format(opened, first, last))
  else
    node = node or require("tsr.net").default()
    mon = netmon.attach(node, { filter = filter, onRecord = onRecord })
    io.say("Watching this computer's network traffic. Press Ctrl+T to stop.")
  end
  local deadline = seconds and (os.clock() + seconds)
  while true do
    if count and shown >= count then break end
    local wait = 1
    if deadline then
      wait = math.min(wait, deadline - os.clock())
      if wait <= 0 then break end
    end
    local ev = io.pull(wait)
    if ev then
      if ev[1] == "terminate" then break end
      if mode == "sniff" then mon:event(ev) end
    end
  end
  mon:stop()
  for _, l in ipairs(mon:summary()) do io.say(l) end
  if savePath then
    local ok, err = mon:save(vfs.normalize(savePath))
    io.say(ok and ("Capture saved to " .. savePath .. ".") or ("Could not save: " .. tostring(err)))
  end
  return true
end

function M.main(args) return M.run(args) end

return M
