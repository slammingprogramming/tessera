-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A tracker for the in-game swarm: a computer that remembers which computers announced which torrent, so that peers far apart (outside
-- each other's modem range, but both able to reach the tracker) can find each other. It stores only computer ids and counts, never data.
-- Limits keep it small: a fixed number of torrents and peers per torrent, entries expire after 30 minutes without an announcement.
local M = {}

M.MAX_SWARMS = 200
M.MAX_PEERS = 50
M.TTL = 1800
M.REPLY_PEERS = 30

--- Attach tracker behaviour to a swarm (tsr.p2p.swarm). opts: clock (function -> seconds).
function M.attach(swarm, opts)
  opts = opts or {}
  local clock = opts.clock or function() return os.epoch and os.epoch("utc") / 1000 or os.clock() end
  local tracker = { swarms = {} }

  local function expire(now)
    for ih, sw in pairs(tracker.swarms) do
      local n = 0
      for id, p in pairs(sw.peers) do
        if now - p.last > M.TTL then sw.peers[id] = nil else n = n + 1 end
      end
      if n == 0 then tracker.swarms[ih] = nil end
    end
  end

  local function counts(sw)
    local seeders, leechers = 0, 0
    for _, p in pairs(sw.peers) do if p.seed then seeders = seeders + 1 else leechers = leechers + 1 end end
    return seeders, leechers
  end

  swarm.hooks.announce = function(from, msg)
    if type(msg.ih) ~= "string" or #msg.ih ~= 64 or not msg.ih:match("^%x+$") then return end
    local now = clock()
    expire(now)
    local sw = tracker.swarms[msg.ih]
    if not sw then
      local n = 0
      for _ in pairs(tracker.swarms) do n = n + 1 end
      if n >= M.MAX_SWARMS then return end
      sw = { peers = {} }
      tracker.swarms[msg.ih] = sw
    end
    if msg.event == "stopped" then
      sw.peers[from] = nil
    else
      local known = sw.peers[from] ~= nil
      local count = 0
      for _ in pairs(sw.peers) do count = count + 1 end
      if known or count < M.MAX_PEERS then
        sw.peers[from] = { last = now, seed = (tonumber(msg.left) or 1) == 0, name = type(msg.host) == "string" and msg.host:sub(1, 32) or nil }
      end
    end
    local list = {}
    for id in pairs(sw.peers) do
      if id ~= from then list[#list + 1] = id end
    end
    table.sort(list)
    while #list > M.REPLY_PEERS do table.remove(list, math.random(#list)) end
    local seeders, leechers = counts(sw)
    swarm:send(from, "peers", { ih = msg.ih, peers = list, seeders = seeders, leechers = leechers })
  end

  swarm.hooks.scrape = function(from, msg)
    local sw = type(msg.ih) == "string" and tracker.swarms[msg.ih]
    local seeders, leechers = 0, 0
    if sw then seeders, leechers = counts(sw) end
    swarm:send(from, "scrape", { ih = msg.ih, seeders = seeders, leechers = leechers })
  end

  swarm.tracker = tracker
  return tracker
end

--- A summary for `torrent tracker`: { swarms = n, peers = n }.
function M.summary(tracker)
  local swarms, peers = 0, 0
  for _, sw in pairs(tracker.swarms) do
    swarms = swarms + 1
    for _ in pairs(sw.peers) do peers = peers + 1 end
  end
  return { swarms = swarms, peers = peers }
end

return M
