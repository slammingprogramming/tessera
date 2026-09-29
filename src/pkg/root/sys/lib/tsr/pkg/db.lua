-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Installed-package database (/var/lib/tsr/pkg/db.json): what is installed, which files each package owns, and why.
--   record = { version, reason = "manual"|"auto", files = {{path, sha256, size}}, requires, provides, lazy, time }
local vfs = require("tsr.vfs")

local M = {}

M.path = "/var/lib/tsr/pkg/db.json"

local cache

local function load()
  if cache then return cache end
  cache = vfs.readJSON(M.path)
  if type(cache) ~= "table" or type(cache.packages) ~= "table" then
    cache = { format = 1, packages = {} }
  end
  return cache
end

--- Drop the in-memory copy (tests, or after another process changed the file).
function M.reload() cache = nil end

function M.get(name) return load().packages[name] end

function M.set(name, record)
  load().packages[name] = record
end

function M.remove(name) load().packages[name] = nil end

function M.save()
  local ok, err = vfs.writeJSON(M.path, load())
  if not ok then return false, err end
  return true
end

--- Sorted array of installed package names.
function M.names()
  local out = {}
  for name in pairs(load().packages) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- Which package owns `path`? Returns name, fileRecord.
function M.owner(path)
  for name, rec in pairs(load().packages) do
    for _, f in ipairs(rec.files or {}) do
      if f.path == path then return name, f end
    end
  end
  return nil
end

--- Installed packages that list `name` in their requires (reverse dependencies).
function M.dependents(name)
  local out = {}
  for other, rec in pairs(load().packages) do
    if other ~= name and rec.requires and rec.requires[name] ~= nil then out[#out + 1] = other end
  end
  table.sort(out)
  return out
end

--- Installed package providing the virtual name `virt`, if any.
function M.provider(virt)
  for name, rec in pairs(load().packages) do
    for _, p in ipairs(rec.provides or {}) do
      if p == virt then return name end
    end
  end
  return nil
end

return M
