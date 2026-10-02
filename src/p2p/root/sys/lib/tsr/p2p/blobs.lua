-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Package payloads for the swarm: any computer that has a package file can hand it to its neighbours, and the package manager's `p2p`
-- source (tsr.pkg.src_p2p) fetches payloads that way. Trust is not needed: a payload is named by its SHA-256, the package manifest
-- (which carries that hash) is covered by the registry signature, and the downloader verifies the hash. A seeder re-checks the hash
-- of a file before it sends it, so a modified file is never offered.
--   Seeded from:  the offline store and the mirror cache (whole blobs), and every file of an installed package (by the hash in
--                 the package database), so a computer that installed `ui-gui` can help another one install it.
local hash = require("tsr.hash")

local M = {}

M.CACHES = { "/var/cache/tsr/offline/blobs", "/var/cache/tsr/mirror/blobs" }
M.REFRESH = 300

local map, mapTime = nil, -math.huge

local function installedMap()
  local out = {}
  local ok, db = pcall(require, "tsr.pkg.db")
  if not ok then return out end
  for _, name in ipairs(db.names()) do
    local rec = db.get(name)
    for _, f in ipairs(rec and rec.files or {}) do
      if f.sha256 and not out[f.sha256] then out[f.sha256] = f.path end
    end
  end
  return out
end

--- Where is a file with this SHA-256? Returns a path or nil. (The seeder verifies the content before sending.)
function M.lookup(sha)
  if type(sha) ~= "string" or not sha:match("^%x+$") or #sha ~= 64 then return nil end
  for _, dir in ipairs(M.CACHES) do
    if fs.exists(dir .. "/" .. sha) then return dir .. "/" .. sha end
  end
  if not map or os.clock() - mapTime > M.REFRESH then map, mapTime = installedMap(), os.clock() end
  local path = map[sha]
  if path and fs.exists(path) and not fs.isDir(path) then return path end
  return nil
end

--- Forget the installed-file map (after installs or removals; tests).
function M.refresh() map = nil end

--- Let `swarm` serve package payloads.
function M.attach(swarm)
  swarm.blobLookup = M.lookup
end

return M
