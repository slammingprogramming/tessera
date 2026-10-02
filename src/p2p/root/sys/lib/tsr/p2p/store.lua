-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Where torrent data lives.
--   Seed:      reads pieces out of the finished file or folder (verified against the piece hashes before they are served).
--   Download:  keeps every verified piece in its own small file under <dir>/.tsrt-<infohash prefix>/ so an interrupted download resumes,
--              then assembles the finished file or folder piece by piece (deleting each piece as it is copied, so the disk never has to
--              hold the data twice) and removes the work folder.
local meta = require("tsr.p2p.meta")
local hash = require("tsr.hash")

local M = {}

local function sha256raw(data) return hash.fromHex(hash.sha256(data)) end

local function readAll(path)
  local h = fs.open(path, "rb")
  if not h then return nil end
  local data = h.readAll() or ""
  h.close()
  return data
end

---------------------------------------------------------------------------------------------------------------------
-- Seeding from finished content
---------------------------------------------------------------------------------------------------------------------

--- A reader for the content of `m` stored at `base` (the file itself, or the folder for multi-file torrents).
--- Returns { read(i) -> data | nil, verify(i) -> bool, bitfield() -> string of 0/1 }.
function M.seed(m, base)
  base = "/" .. fs.combine(base, "")
  local files = meta.files(m)
  local pl = m.info["piece length"]
  local self = { meta = m, base = base }
  local cache = {}                                    -- one open file image at a time

  local function pathOf(f)
    if m.info.files then return base .. "/" .. table.concat(f.path, "/") end
    return base
  end

  local function fileData(f)
    local p = pathOf(f)
    if cache.path ~= p then cache = { path = p, data = readAll(p) } end
    return cache.data
  end

  --- Piece i (1-based) from the files, or nil when a file is missing or too short.
  function self.read(i)
    local len = meta.pieceLength(m, i)
    local start = (i - 1) * pl
    local out, got = {}, 0
    for _, f in ipairs(files) do
      local fstart, fend = f.offset, f.offset + f.length
      if fend > start and fstart < start + len then
        local data = fileData(f)
        if not data or #data ~= f.length then return nil end
        local from = math.max(start, fstart) - fstart
        local to = math.min(start + len, fend) - fstart
        out[#out + 1] = data:sub(from + 1, to)
        got = got + (to - from)
      end
    end
    if got ~= len then return nil end
    return table.concat(out)
  end

  function self.verify(i)
    local data = self.read(i)
    return data ~= nil and sha256raw(data) == meta.pieceHash(m, i)
  end

  --- "1010..." for every piece that checks out (slow for big torrents: hashes everything; yields while doing so).
  function self.bitfield()
    local bits = {}
    for i = 1, meta.pieceCount(m) do
      bits[i] = self.verify(i) and "1" or "0"
      if i % 8 == 0 then os.queueEvent("p2p_yield") os.pullEventRaw("p2p_yield") end
    end
    return table.concat(bits)
  end

  return self
end

---------------------------------------------------------------------------------------------------------------------
-- Download storage
---------------------------------------------------------------------------------------------------------------------

--- Storage for downloading `m` into the folder `dest`. Resumes from pieces already in the work folder (each one re-verified).
function M.download(m, dest)
  dest = "/" .. fs.combine(dest, "")
  local work = dest .. "/.tsrt-" .. m.infohash:sub(1, 12)
  local count = meta.pieceCount(m)
  local self = { meta = m, dest = dest, work = work, have = {}, count = count }
  local owned = 0

  local function pieceFile(i) return work .. "/" .. i end

  function self.resume()
    owned = 0
    for i = 1, count do
      self.have[i] = false
      if fs.exists(pieceFile(i)) then
        local data = readAll(pieceFile(i))
        if data and #data == meta.pieceLength(m, i) and sha256raw(data) == meta.pieceHash(m, i) then
          self.have[i] = true
          owned = owned + 1
        else
          fs.delete(pieceFile(i))
        end
      end
    end
    return owned
  end

  function self.owned() return owned end
  function self.complete() return owned == count end

  --- Store a received piece after checking its hash. Returns true, or false + reason.
  function self.put(i, data)
    if i < 1 or i > count then return false, "no such piece" end
    if self.have[i] then return true end
    if #data ~= meta.pieceLength(m, i) then return false, "wrong piece size" end
    if sha256raw(data) ~= meta.pieceHash(m, i) then return false, "piece failed its hash check" end
    local h = fs.open(pieceFile(i), "wb")
    if not h then return false, "cannot write to " .. work end
    h.write(data)
    h.close()
    self.have[i] = true
    owned = owned + 1
    return true
  end

  function self.get(i)
    if not self.have[i] then return nil end
    return readAll(pieceFile(i))
  end

  function self.bitfield()
    local bits = {}
    for i = 1, count do bits[i] = self.have[i] and "1" or "0" end
    return table.concat(bits)
  end

  --- Write the finished content to `dest/<name>` and remove the work folder. Returns the path or nil + reason.
  function self.assemble()
    if not self.complete() then return nil, "not complete" end
    local files = meta.files(m)
    local target = dest .. "/" .. m.info.name
    local pl = m.info["piece length"]
    -- stream pieces into the files in order
    local piece, pieceIndex, pieceData = 0, 0, nil
    local function nextBytes(n)
      local out, need = {}, n
      while need > 0 do
        if not pieceData or piece >= #pieceData then
          pieceIndex = pieceIndex + 1
          pieceData = self.get(pieceIndex)
          if pieceIndex > 1 and fs.exists(pieceFile(pieceIndex - 1)) then fs.delete(pieceFile(pieceIndex - 1)) end
          piece = 0
          if not pieceData then return nil end
        end
        local take = math.min(need, #pieceData - piece)
        out[#out + 1] = pieceData:sub(piece + 1, piece + take)
        piece = piece + take
        need = need - take
      end
      return table.concat(out)
    end
    for _, f in ipairs(files) do
      local path = m.info.files and (target .. "/" .. table.concat(f.path, "/")) or target
      if fs.exists(path) then fs.delete(path) end
      local h = fs.open(path, "wb")
      if not h then return nil, "cannot write " .. path end
      local left = f.length
      while left > 0 do
        local chunk = nextBytes(math.min(left, pl))
        if not chunk then h.close() return nil, "a piece vanished while assembling" end
        h.write(chunk)
        left = left - #chunk
      end
      h.close()
    end
    if fs.exists(work) then fs.delete(work) end
    return target
  end

  self.resume()
  return self
end

return M
