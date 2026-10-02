-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Torrent metadata ("metainfo", .tsrt files) for the in-game swarm, modelled on BitTorrent v2's choices: the content is cut into
-- pieces, each piece is identified by its SHA-256, and the whole torrent by the info hash = SHA-256 of the bencoded `info` dictionary.
--
--   info = { name, ["piece length"], pieces (32 bytes per piece, concatenated), length (one file) | files = { { length, path = {...} } } }
--   file = { info = ..., announce = trackerHost (optional), comment, ["creation date"] }
--
-- A magnet link carries only the info hash (and a name and tracker hints):  magnet:?xt=urn:btmh:1220<hex>&dn=<name>&tr=<tracker>
-- The 1220 prefix is the multihash code of SHA-256. The info dictionary itself is then fetched from the swarm (see tsr.p2p.swarm).
local bencode = require("tsr.p2p.bencode")
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local yield = require("tsr.crypto.yield")

local M = {}

M.PIECE_LENGTH = 16384

local function sha256raw(data) return hash.fromHex(hash.sha256(data)) end

local function listFiles(path, prefix, out)
  for _, name in ipairs(fs.list(path)) do
    local full = path .. "/" .. name
    local rel = prefix and (prefix .. "/" .. name) or name
    if fs.isDir(full) then listFiles(full, rel, out) else out[#out + 1] = { path = full, rel = rel, length = fs.getSize(full) } end
  end
  return out
end

--- Hash the content of `path` (a file or a directory) into a metainfo. opts: pieceLength, name, tracker, comment, created (seconds).
--- Returns meta = { info, infoRaw, infohash (hex), announce, comment, created }.
function M.create(path, opts)
  opts = opts or {}
  local pl = opts.pieceLength or M.PIECE_LENGTH
  assert(pl >= 1024 and pl <= 262144, "piece length must be between 1 KB and 256 KB")
  path = "/" .. fs.combine(path, "")
  if not fs.exists(path) then return nil, "no such file or folder: " .. path end
  local files = fs.isDir(path) and listFiles(path, nil, {}) or { { path = path, rel = fs.getName(path), length = fs.getSize(path) } }
  table.sort(files, function(a, b) return a.rel < b.rel end)
  local pieces, buffer, total = {}, {}, 0
  local pending = 0
  local function flush(force)
    local data = table.concat(buffer)
    local pos = 1
    while #data - pos + 1 >= pl or (force and pos <= #data) do
      pieces[#pieces + 1] = sha256raw(data:sub(pos, pos + pl - 1))
      pos = pos + pl
    end
    buffer = { data:sub(pos) }
    yield.maybe()
  end
  for _, f in ipairs(files) do
    local h = fs.open(f.path, "rb")
    if not h then return nil, "cannot read " .. f.path end
    local data = h.readAll() or ""
    h.close()
    f.length = #data
    total = total + #data
    buffer[#buffer + 1] = data
    pending = pending + #data
    if pending >= pl * 4 then flush(false) pending = 0 end
  end
  flush(true)
  if #pieces == 0 then pieces[1] = sha256raw("") end        -- an empty torrent still has one (empty) piece
  local info = { name = opts.name or fs.getName(path), ["piece length"] = pl, pieces = table.concat(pieces) }
  if fs.isDir(path) then
    info.files = {}
    for i, f in ipairs(files) do
      local parts = {}
      for part in f.rel:gmatch("[^/]+") do parts[#parts + 1] = part end
      info.files[i] = { length = f.length, path = parts }
    end
  else
    info.length = total
  end
  local infoRaw = bencode.encode(info)
  return { info = info, infoRaw = infoRaw, infohash = hash.sha256(infoRaw), announce = opts.tracker, comment = opts.comment,
           created = opts.created or math.floor((os.epoch and os.epoch("utc") or 0) / 1000), total = total }
end

--- The bencoded .tsrt file for a metainfo.
function M.encode(meta)
  return bencode.encode({ info = meta.info, announce = meta.announce, comment = meta.comment, ["creation date"] = meta.created })
end

local function validateInfo(info)
  if type(info) ~= "table" or type(info.name) ~= "string" or info.name == "" or info.name:find("[/\\]") or info.name:find("..", 1, true) then return nil, "bad name" end
  local pl = info["piece length"]
  if type(pl) ~= "number" or pl < 1024 or pl > 262144 or pl % 1 ~= 0 then return nil, "bad piece length" end
  if type(info.pieces) ~= "string" or #info.pieces % 32 ~= 0 or #info.pieces == 0 then return nil, "bad piece hashes" end
  local total
  if info.files then
    total = 0
    if type(info.files) ~= "table" or #info.files == 0 then return nil, "no files" end
    for _, f in ipairs(info.files) do
      if type(f) ~= "table" or type(f.length) ~= "number" or f.length < 0 or type(f.path) ~= "table" or #f.path == 0 then return nil, "bad file entry" end
      for _, part in ipairs(f.path) do
        if type(part) ~= "string" or part == "" or part == ".." or part:find("[/\\]") then return nil, "unsafe file path" end
      end
      total = total + f.length
    end
  else
    if type(info.length) ~= "number" or info.length < 0 then return nil, "bad length" end
    total = info.length
  end
  if math.ceil(total / pl) ~= #info.pieces / 32 and not (total == 0 and #info.pieces == 32) then return nil, "piece count does not match the size" end
  return total
end

--- Metainfo from the bytes of a .tsrt file. Returns meta or nil + reason.
function M.parse(data)
  local doc, err = bencode.decode(data)
  if not doc then return nil, "not a torrent file: " .. tostring(err) end
  return M.fromInfo(doc.info, doc)
end

--- Metainfo from a decoded info dictionary (and optionally the surrounding document). Returns meta or nil + reason.
function M.fromInfo(info, doc)
  local total, err = validateInfo(info)
  if not total then return nil, "invalid torrent: " .. tostring(err) end
  local raw = bencode.encode(info)
  doc = doc or {}
  return { info = info, infoRaw = raw, infohash = hash.sha256(raw), announce = doc.announce, comment = doc.comment, created = doc["creation date"], total = total }
end

--- Metainfo from an info dictionary received over the network; it must hash to the expected info hash.
function M.fromInfoRaw(raw, expectedHash)
  if hash.sha256(raw) ~= expectedHash then return nil, "the metadata does not match the info hash" end
  local info, err = bencode.decode(raw)
  if not info then return nil, err end
  return M.fromInfo(info)
end

function M.pieceCount(meta) return #meta.info.pieces / 32 end

--- Hash (raw 32 bytes) of piece i (1-based).
function M.pieceHash(meta, i) return meta.info.pieces:sub((i - 1) * 32 + 1, i * 32) end

--- Length in bytes of piece i (the last one may be short).
function M.pieceLength(meta, i)
  local pl = meta.info["piece length"]
  if i < M.pieceCount(meta) then return pl end
  local rest = meta.total - pl * (M.pieceCount(meta) - 1)
  return rest > 0 and rest or 0
end

--- List of { path (list of parts), length, offset } in torrent order (a single file has one entry).
function M.files(meta)
  local out, offset = {}, 0
  if meta.info.files then
    for _, f in ipairs(meta.info.files) do
      out[#out + 1] = { path = f.path, length = f.length, offset = offset }
      offset = offset + f.length
    end
  else
    out[1] = { path = { meta.info.name }, length = meta.info.length, offset = 0 }
  end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Magnet links
---------------------------------------------------------------------------------------------------------------------

local function escape(s) return (s:gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end)) end
local function unescape(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

function M.magnet(meta, trackers)
  local uri = "magnet:?xt=urn:btmh:1220" .. meta.infohash .. "&dn=" .. escape(meta.info.name)
  for _, t in ipairs(trackers or { meta.announce }) do uri = uri .. "&tr=" .. escape(tostring(t)) end
  return uri
end

--- Parse a magnet link. Returns { infohash, name, trackers } or nil + reason.
function M.parseMagnet(uri)
  local query = tostring(uri):match("^magnet:%?(.+)$")
  if not query then return nil, "not a magnet link" end
  local out = { trackers = {} }
  for pair in query:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]+)=(.*)$")
    if k == "xt" then out.infohash = unescape(v):match("^urn:btmh:1220(%x+)$") end
    if k == "dn" then out.name = unescape(v) end
    if k == "tr" then out.trackers[#out.trackers + 1] = unescape(v) end
  end
  if not out.infohash or #out.infohash ~= 64 then return nil, "the magnet link has no info hash" end
  out.infohash = out.infohash:lower()
  return out
end

return M
