-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The in-game swarm: computers that have a torrent's content hand pieces to computers that want it, BitTorrent-style, over the
-- network of the game world (modems / rednet, via a tsr.net node). Nothing here reaches the real Internet.
--
--   Finding peers:  a broadcast "who has <info hash>?" reaches every computer in modem range; optionally a TRACKER (a computer running
--                   the tracker role) remembers who announced which torrent, so far-away computers find each other too.
--   Transfer:       the content is cut into pieces named by their SHA-256 (see tsr.p2p.meta). A downloader asks different peers for
--                   different pieces in parallel (rarest piece first), checks every piece against its hash and drops peers that send
--                   bad ones. Interrupted downloads resume. Finished downloads are seeded automatically.
--   Politeness:     modems are slow and shared. A seeder caps its total upload rate (default 48 KB/s), serves a limited number of
--                   computers at once and says "busy" instead of queueing; downloaders back off. Messages stay below ~24 KB.
--   Blobs:          the same machinery serves single content-addressed blobs (a package payload named by its SHA-256) to the package
--                   manager's `p2p` source, see tsr.p2p.blobs.
-- Messages are plain tables { t = "p2p", k = <kind>, ... } carried by the node; integrity comes from the hashes, not from the network,
-- so a hostile peer can waste time but cannot make anybody accept wrong data.
local meta = require("tsr.p2p.meta")
local store = require("tsr.p2p.store")
local hash = require("tsr.hash")
local log = require("tsr.log").get("p2p")

local M = {}

M.META_PAGE = 6000          -- bytes of metadata per message
M.BLOB_CHUNK = 16384
M.REQUEST_TIMEOUT = 5
M.MAX_REQUESTERS = 8        -- computers served at the same time (within REQUESTER_WINDOW seconds)
M.REQUESTER_WINDOW = 15
M.UPLOAD_RATE = 49152       -- bytes per second, all torrents together

local Swarm = {}
Swarm.__index = Swarm

local function b64(s) return hash.base64Encode(s) end
local function unb64(s) return type(s) == "string" and hash.base64Decode(s) or nil end

M.BAN_SECONDS = 300

local function isBanned(self, id)
  local until_ = self.banned[id]
  if not until_ then return false end
  if self.clock() > until_ then self.banned[id] = nil return false end
  return true
end

local function ban(self, id) self.banned[id] = self.clock() + M.BAN_SECONDS end

--- The swarm of a node: one per node, shared by everything in the system that wants to use it (the node has a single message handler).
function M.forNode(node, opts)
  if not node.p2pSwarm then node.p2pSwarm = M.new(node, opts) end
  return node.p2pSwarm
end

--- Create the swarm part of a net node. opts: uploadRate, maxRequesters, clock (function -> seconds), blobLookup (function(sha) -> path|nil).
function M.new(node, opts)
  opts = opts or {}
  local self = setmetatable({
    node = node, seeds = {}, uploadRate = opts.uploadRate or M.UPLOAD_RATE, maxRequesters = opts.maxRequesters or M.MAX_REQUESTERS,
    clock = opts.clock or os.clock, requesters = {}, blobLookup = opts.blobLookup, blobVerified = {}, uploaded = 0, downloaded = 0,
    bucket = nil, banned = {}, hooks = {},
  }, Swarm)
  self.bucket = { tokens = self.uploadRate * 2, last = self.clock() }
  node.handlers = node.handlers or {}
  node.handlers.p2p = function(_, from, msg) self:handle(from, msg) end
  return self
end

---------------------------------------------------------------------------------------------------------------------
-- Seeding
---------------------------------------------------------------------------------------------------------------------

--- Offer the finished content of `m` found at `base` (file, or folder for multi-file torrents).
function Swarm:addSeed(m, base)
  local entry = { meta = m, store = store.seed(m, base), verified = {}, base = base }
  self.seeds[m.infohash] = entry
  return entry
end

function Swarm:removeSeed(infohash) self.seeds[infohash] = nil end

local function bitfieldOf(entry)
  if not entry.bits then entry.bits = entry.store.bitfield() end
  return entry.bits
end

local function spend(self, n)
  local b = self.bucket
  local now = self.clock()
  b.tokens = math.min(self.uploadRate * 2, b.tokens + (now - b.last) * self.uploadRate)
  b.last = now
  if b.tokens < n then return false end
  b.tokens = b.tokens - n
  return true
end

local function admit(self, from)
  local now = self.clock()
  self.requesters[from] = now
  local n = 0
  for id, t in pairs(self.requesters) do
    if now - t > M.REQUESTER_WINDOW then self.requesters[id] = nil else n = n + 1 end
  end
  return n <= self.maxRequesters
end

function Swarm:send(to, k, fields)
  fields.t, fields.k = "p2p", k
  self.node:send(to, fields)
end

--- Handle one incoming message (the node's "p2p" handler).
function Swarm:handle(from, msg)
  local k = msg.k
  if isBanned(self, from) then return end
  local hook = self.hooks[k]                          -- extra message kinds (the tracker role registers some)
  if hook then return hook(from, msg) end
  if k == "find" and type(msg.ih) == "string" then
    local entry = self.seeds[msg.ih]
    if entry then self:send(from, "has", { ih = msg.ih, have = bitfieldOf(entry) }) end
  elseif k == "getmeta" and type(msg.ih) == "string" then
    local entry = self.seeds[msg.ih]
    local off = tonumber(msg.off) or 0
    if entry and off >= 0 then
      local raw = entry.meta.infoRaw
      self:send(from, "meta", { ih = msg.ih, off = off, total = #raw, data = b64(raw:sub(off + 1, off + M.META_PAGE)) })
    end
  elseif k == "req" and type(msg.ih) == "string" and type(msg.i) == "number" then
    local entry = self.seeds[msg.ih]
    local i = msg.i
    if not entry or i < 1 or i > meta.pieceCount(entry.meta) or i % 1 ~= 0 then return self:send(from, "no", { ih = msg.ih, i = i, why = "unknown" }) end
    if not admit(self, from) then return self:send(from, "no", { ih = msg.ih, i = i, why = "busy" }) end
    if not spend(self, meta.pieceLength(entry.meta, i)) then return self:send(from, "no", { ih = msg.ih, i = i, why = "busy" }) end
    local data = entry.store.read(i)
    if not data or (not entry.verified[i] and hash.fromHex(hash.sha256(data)) ~= meta.pieceHash(entry.meta, i)) then
      return self:send(from, "no", { ih = msg.ih, i = i, why = "unknown" })
    end
    entry.verified[i] = true
    self.uploaded = self.uploaded + #data
    self:send(from, "piece", { ih = msg.ih, i = i, data = b64(data) })
  elseif k == "bfind" and type(msg.sha) == "string" and self.blobLookup then
    local path = self.blobLookup(msg.sha)
    if path then self:send(from, "bhas", { sha = msg.sha, size = fs.getSize(path) }) end
  elseif k == "breq" and type(msg.sha) == "string" and type(msg.off) == "number" and self.blobLookup then
    local path = self.blobLookup(msg.sha)
    if not path then return self:send(from, "no", { sha = msg.sha, why = "unknown" }) end
    if not admit(self, from) or not spend(self, M.BLOB_CHUNK) then return self:send(from, "no", { sha = msg.sha, why = "busy" }) end
    local h = fs.open(path, "rb")
    if not h then return self:send(from, "no", { sha = msg.sha, why = "unknown" }) end
    local data = h.readAll() or ""
    h.close()
    if not self.blobVerified[msg.sha] then
      if hash.sha256(data) ~= msg.sha then return self:send(from, "no", { sha = msg.sha, why = "unknown" }) end   -- a modified file is never served
      self.blobVerified[msg.sha] = true
    end
    local piece = data:sub(msg.off + 1, msg.off + M.BLOB_CHUNK)
    self.uploaded = self.uploaded + #piece
    self:send(from, "bdata", { sha = msg.sha, off = msg.off, size = #data, data = b64(piece) })
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Tracker client
---------------------------------------------------------------------------------------------------------------------

--- Tell a tracker about a torrent and get its peers. event: "started", "completed", "stopped" or nil. Returns { ids..., seeders, leechers } or nil + reason.
function Swarm:announce(tracker, infohash, event, left)
  local id, err = self.node:resolve(tracker, 2)
  if not id then return nil, err end
  self:send(id, "announce", { ih = infohash, event = event, left = left or 0, host = self.node.hostname })
  local reply = self.node:await(id, function(m) return m.t == "p2p" and m.k == "peers" and m.ih == infohash end, 3)
  if not reply then return nil, "the tracker " .. tostring(tracker) .. " did not answer" end
  return { peers = reply.peers or {}, seeders = reply.seeders or 0, leechers = reply.leechers or 0 }
end

---------------------------------------------------------------------------------------------------------------------
-- Finding peers
---------------------------------------------------------------------------------------------------------------------

--- Who has `infohash`? Broadcasts and asks the trackers. Returns { [computer id] = { have = "1010..." } }.
function Swarm:discover(infohash, trackers, wait)
  local peers = {}
  local asked = {}
  local node = self.node
  node:broadcast({ t = "p2p", k = "find", ih = infohash })
  for _, tr in ipairs(trackers or {}) do
    local res = self:announce(tr, infohash, nil, 1)
    if res then
      for _, id in ipairs(res.peers) do
        if id ~= node.id and not asked[id] then asked[id] = true self:send(id, "find", { ih = infohash }) end
      end
    end
  end
  local deadline = self.clock() + (wait or 1.5)
  while true do
    local remaining = deadline - self.clock()
    if remaining <= 0 then break end
    local id, msg = node:receive(remaining)
    if id == nil then break end
    if type(msg) == "table" and msg.t == "p2p" and msg.k == "has" and msg.ih == infohash and type(msg.have) == "string" and not isBanned(self, id) then
      peers[id] = { id = id, have = msg.have, fails = 0, bad = 0 }
    end
  end
  return peers
end

--- Fetch the metadata of a torrent known only by its info hash (from a magnet link). Returns meta or nil + reason.
function Swarm:fetchMeta(infohash, trackers)
  local peers = self:discover(infohash, trackers, 2)
  for id in pairs(peers) do
    local parts, off, total = {}, 0, nil
    while true do
      self:send(id, "getmeta", { ih = infohash, off = off })
      local reply = self.node:await(id, function(m) return m.t == "p2p" and m.k == "meta" and m.ih == infohash and m.off == off end, 3)
      if not reply then break end
      local data = unb64(reply.data)
      if not data then break end
      parts[#parts + 1] = data
      off = off + #data
      total = reply.total
      if off >= total or #data == 0 then
        local m = meta.fromInfoRaw(table.concat(parts), infohash)
        if m then return m end
        break
      end
    end
  end
  return nil, "could not get the torrent's metadata from any peer (is anybody seeding it?)"
end

---------------------------------------------------------------------------------------------------------------------
-- Downloading
---------------------------------------------------------------------------------------------------------------------

--- Download `m` into the folder `dest`. opts: trackers (list), maxWorkers (default 4), stall (give up after this many seconds without
--- progress, default 40), onProgress(owned, count), keepSeeding (default true).
--- Returns the path of the finished file or folder, or nil + reason.
function Swarm:download(m, dest, opts)
  opts = opts or {}
  local st = store.download(m, dest)
  local count = meta.pieceCount(m)
  local trackers = opts.trackers or {}
  if m.announce and #trackers == 0 then trackers = { m.announce } end
  local lastProgress = self.clock()
  local peers = {}
  local inflight = {}
  local function progress() if opts.onProgress then opts.onProgress(st.owned(), count) end end
  progress()

  while not st.complete() do
    peers = self:discover(m.infohash, trackers, 1.5)
    local list = {}
    for _, p in pairs(peers) do list[#list + 1] = p end
    table.sort(list, function(a, b) return a.id < b.id end)
    if #list == 0 then
      if self.clock() - lastProgress > (opts.stall or 40) then return nil, "no peers found for this torrent" end
      sleep(1)
    else
      -- availability of each piece across peers (for rarest-first)
      local avail = {}
      for _, p in ipairs(list) do
        for i = 1, count do if p.have:sub(i, i) == "1" then avail[i] = (avail[i] or 0) + 1 end end
      end
      local function pick(p)
        local best, bestScore
        for i = 1, count do
          if not st.have[i] and not inflight[i] and p.have:sub(i, i) == "1" then
            local score = (avail[i] or 1) * 100000 + ((i * 7 + p.id) % 97)         -- rarest first, spread peers over different pieces
            if not bestScore or score < bestScore then best, bestScore = i, score end
          end
        end
        return best
      end
      local function worker(p)
        while not st.complete() and p.fails < 3 and p.bad < 2 do
          local i = pick(p)
          if not i then return end
          inflight[i] = p.id
          self:send(p.id, "req", { ih = m.infohash, i = i })
          local reply = self.node:await(p.id, function(r) return r.t == "p2p" and r.ih == m.infohash and r.i == i and (r.k == "piece" or r.k == "no") end, M.REQUEST_TIMEOUT)
          inflight[i] = nil
          if not reply then
            p.fails = p.fails + 1
          elseif reply.k == "piece" then
            local data = unb64(reply.data)
            local ok, why = false, "bad data"
            if data then ok, why = st.put(i, data) end
            if ok then
              self.downloaded = self.downloaded + #data
              p.fails = 0
              lastProgress = self.clock()
              progress()
            else
              p.bad = p.bad + 1
              log.warn("computer %d sent a bad piece %d: %s", p.id, i, tostring(why))
            end
          elseif reply.why == "busy" then
            sleep(1)
          else
            p.have = p.have:sub(1, i - 1) .. "0" .. p.have:sub(i + 1)         -- it does not have it after all
          end
        end
      end
      local workers = {}
      for n = 1, math.min(opts.maxWorkers or 4, #list) do
        local p = list[n]
        workers[#workers + 1] = function() worker(p) end
      end
      parallel.waitForAll(table.unpack(workers))
      for _, p in ipairs(list) do if p.bad >= 2 then ban(self, p.id) end end
      if not st.complete() and self.clock() - lastProgress > (opts.stall or 40) then return nil, "the download stalled" end
    end
  end

  local path, err = st.assemble()
  if not path then return nil, err end
  for _, tr in ipairs(trackers) do self:announce(tr, m.infohash, "completed", 0) end
  if opts.keepSeeding ~= false then self:addSeed(m, path) end
  return path
end

---------------------------------------------------------------------------------------------------------------------
-- Single blobs (the package manager's `p2p` source)
---------------------------------------------------------------------------------------------------------------------

--- Fetch the content-addressed blob `sha` (hex SHA-256) from whichever computers have it. Returns the data or nil + reason.
function Swarm:fetchBlob(sha, opts)
  opts = opts or {}
  local holders = {}
  self.node:broadcast({ t = "p2p", k = "bfind", sha = sha })
  local deadline = self.clock() + (opts.wait or 1.2)
  local size
  while true do
    local remaining = deadline - self.clock()
    if remaining <= 0 then break end
    local id, msg = self.node:receive(remaining)
    if id == nil then break end
    if type(msg) == "table" and msg.t == "p2p" and msg.k == "bhas" and msg.sha == sha and type(msg.size) == "number" and not isBanned(self, id) then
      holders[#holders + 1] = id
      size = msg.size
    end
  end
  if #holders == 0 then return nil, "no computer nearby has that file" end
  local parts, off, turn = {}, 0, 1
  local failures = 0
  while off < size or (size == 0 and off == 0) do
    local id = holders[(turn - 1) % #holders + 1]
    turn = turn + 1
    self:send(id, "breq", { sha = sha, off = off })
    local reply = self.node:await(id, function(r) return r.t == "p2p" and r.sha == sha and (r.k == "bdata" and r.off == off or r.k == "no") end, M.REQUEST_TIMEOUT)
    if reply and reply.k == "bdata" then
      local data = unb64(reply.data)
      if not data then failures = failures + 1 else
        parts[#parts + 1] = data
        off = off + #data
        if size == 0 or #data == 0 then break end
        failures = 0
      end
    else
      failures = failures + 1
      if reply and reply.why == "busy" then sleep(0.5) end
    end
    if failures > 3 * #holders + 2 then return nil, "the computers holding the file stopped answering" end
  end
  local data = table.concat(parts)
  if hash.sha256(data) ~= sha then
    for _, id in ipairs(holders) do ban(self, id) end
    return nil, "the file failed its checksum (the senders are ignored for a while)"
  end
  self.downloaded = self.downloaded + #data
  return data
end

return M
