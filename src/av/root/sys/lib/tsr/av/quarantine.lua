-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The quarantine: a folder where files that were found to be malware are put aside. A quarantined file cannot run (it is renamed to <id>.q) and is kept with a
-- note of where it came from and why it was moved, so that it can be restored if the scanner was wrong.
local vfs = require("tsr.vfs")
local hash = require("tsr.hash")

local M = {}

M.DIR = "/var/lib/tsr/av/quarantine"

local function now() return os.epoch and os.epoch("utc") / 1000 or os.clock() end

--- Move a file into quarantine. result: the scan result (for the notes). Returns the id, or nil + reason.
function M.add(path, result)
  path = vfs.normalize(path)
  local data = vfs.readFile(path, true)
  if not data then return nil, "cannot read " .. path end
  local id = hash.sha256(data):sub(1, 12)
  vfs.mkdirp(M.DIR)
  local okW, err = vfs.writeFile(M.DIR .. "/" .. id .. ".q", data, true)
  if not okW then return nil, tostring(err) end
  local ids = {}
  for _, f in ipairs(result and result.findings or {}) do ids[#ids + 1] = f.id end
  local meta = { id = id, path = path, sha256 = hash.sha256(data), size = #data, time = now(), score = result and result.score, findings = ids, verdict = result and result.verdict }
  vfs.writeFile(M.DIR .. "/" .. id .. ".json", textutils.serializeJSON(meta))
  local okD = pcall(vfs.fs.delete, path)
  if not okD then return nil, "stored a copy, but could not remove " .. path end
  return id
end

function M.list()
  local out = {}
  if not vfs.fs.exists(M.DIR) then return out end
  for _, n in ipairs(vfs.fs.list(M.DIR)) do
    local id = n:match("^(%w+)%.json$")
    if id then
      local t = vfs.readJSON(M.DIR .. "/" .. n)
      if t then out[#out + 1] = t end
    end
  end
  table.sort(out, function(a, b) return (a.time or 0) < (b.time or 0) end)
  return out
end

local function find(id)
  for _, m in ipairs(M.list()) do if m.id == id or m.id:sub(1, #id) == id then return m end end
end

--- Put a file back (to its old place unless dest is given). The file is not scanned again, so only do this for files you know are safe.
function M.restore(id, dest)
  local m = find(id)
  if not m then return nil, "no such item in the quarantine" end
  local data = vfs.readFile(M.DIR .. "/" .. m.id .. ".q", true)
  if not data then return nil, "the quarantined file is missing" end
  dest = vfs.normalize(dest or m.path)
  if vfs.fs.exists(dest) then return nil, dest .. " exists already" end
  local okW, err = vfs.writeFile(dest, data, true)
  if not okW then return nil, tostring(err) end
  vfs.fs.delete(M.DIR .. "/" .. m.id .. ".q")
  vfs.fs.delete(M.DIR .. "/" .. m.id .. ".json")
  return dest
end

function M.delete(id)
  local m = find(id)
  if not m then return nil, "no such item in the quarantine" end
  vfs.fs.delete(M.DIR .. "/" .. m.id .. ".q")
  vfs.fs.delete(M.DIR .. "/" .. m.id .. ".json")
  return true
end

--- Remove items older than `days`.
function M.purge(days)
  local n, limit = 0, now() - days * 86400
  for _, m in ipairs(M.list()) do
    if (m.time or 0) < limit then M.delete(m.id) n = n + 1 end
  end
  return n
end

return M
