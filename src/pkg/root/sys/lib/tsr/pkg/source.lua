-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Package sources ("channels"). Every source exposes the same static layout:
--   registry/index.json                     { format, packages = { name = {version, type, description, size, provides} } }
--   registry/packages/<name>.json           { name, latest, versions = { ["1.0.0"] = manifest } }
--   blobs/<sha256>                          file payloads, content-addressed (verified after download)
-- Source types:
--   http      one or more mirror base URLs (GitHub Pages, ...)        { type="http", bases={...} }
--   dir       a directory with the layout above (disk, mount, offline import store)   { type="dir", path="..." }
--   pastebin  a "snapshot" paste mapping registry files to pastes     { type="pastebin", snapshot="<id>" }
--   lan       a paired computer running the pkg-mirror service         { type="lan", peer="<name>" }  (package pkg-mirror)
-- The built-in `offline` source is a `dir` at /var/cache/tsr/offline, filled by importing a bundle. It is always
-- consulted first, so pasting a bundle makes an HTTP-less install possible.
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local config = require("tsr.config")
local log = require("tsr.log").get("pkg.source")

local M = {}

M.cacheDir = "/var/cache/tsr"
M.offlineDir = M.cacheDir .. "/offline"

local fetchers = {}
M.fetchers = fetchers

---------------------------------------------------------------------------------------------------------------------
-- Fetchers: read(src, rel) -> data | nil, err
---------------------------------------------------------------------------------------------------------------------

local function httpGet(url)
  if not rawget(_G, "http") then return nil, "HTTP is disabled on this computer" end
  local okCheck, reason = http.checkURL(url)
  if not okCheck then return nil, "URL not allowed: " .. tostring(reason) end
  local h, err, errHandle = http.get({ url = url, binary = true, timeout = 20 })
  if not h then
    if errHandle then
      local code = errHandle.getResponseCode()
      errHandle.close()
      return nil, "HTTP " .. tostring(code)
    end
    return nil, tostring(err)
  end
  local code = h.getResponseCode()
  local body = h.readAll()
  h.close()
  if code ~= 200 then return nil, "HTTP " .. tostring(code) end
  return body or ""
end
M.httpGet = httpGet

fetchers.http = {
  read = function(src, rel)
    local lastErr = "no mirrors configured"
    for _, base in ipairs(src.bases or {}) do
      local body, err = httpGet(base:gsub("/+$", "") .. "/" .. rel)
      if body then return body end
      lastErr = err
      log.debug("%s: %s", base, tostring(err))
    end
    return nil, lastErr
  end,
}

fetchers.dir = {
  read = function(src, rel)
    local data = vfs.readFile(src.path .. "/" .. rel, true)
    if data == nil then return nil, "not found: " .. src.path .. "/" .. rel end
    return data
  end,
}

local function snapshot(src)
  if src._snap then return src._snap end
  local body, err = httpGet("https://pastebin.com/raw/" .. src.snapshot)
  if not body then return nil, err end
  local snap = textutils.unserializeJSON(body)
  if type(snap) ~= "table" then return nil, "bad pastebin snapshot" end
  src._snap = snap
  return snap
end

fetchers.pastebin = {
  read = function(src, rel)
    local snap, err = snapshot(src)
    if not snap then return nil, err end
    if rel == "registry/index.json" then return textutils.serializeJSON(snap.index or {}) end
    local key = rel:match("^registry/packages/(.+)%.json$")
    key = key and ("packages/" .. key) or rel:match("^blobs/(%x+)$")
    local id = key and snap.pastes and snap.pastes[key]
    if not id then return nil, "not in pastebin snapshot: " .. rel end
    return httpGet("https://pastebin.com/raw/" .. id)
  end,
}

---------------------------------------------------------------------------------------------------------------------
-- Sources list
---------------------------------------------------------------------------------------------------------------------

--- Configured sources in priority order, with the offline store first when it has content.
function M.list()
  local out = {}
  if fs.exists(M.offlineDir .. "/registry/index.json") then
    out[#out + 1] = { name = "offline", type = "dir", path = M.offlineDir }
  end
  for _, s in ipairs(config.get("pkg.sources", {})) do out[#out + 1] = s end
  return out
end

local function readRaw(src, rel)
  local f = fetchers[src.type]
  if not f and type(src.type) == "string" and src.type:match("^%w+$") then
    pcall(require, "tsr.pkg.src_" .. src.type)      -- source types provided by other packages (e.g. lan, from pkg-mirror)
    f = fetchers[src.type]
  end
  if not f then return nil, "unknown source type " .. tostring(src.type) end
  return f.read(src, rel)
end
M.read = readRaw

---------------------------------------------------------------------------------------------------------------------
-- Registry documents (cached under /var/cache/tsr/registry/<source>/ so browsing works offline after `pkg update`)
---------------------------------------------------------------------------------------------------------------------

local function cachePath(src, rel) return M.cacheDir .. "/registry/" .. src.name .. "/" .. rel:gsub("^registry/", "") end

local function getDoc(src, rel, force)
  local cp = cachePath(src, rel)
  if src.type ~= "dir" then
    if not force then
      local cached = vfs.readJSON(cp)
      if cached then return cached end
    end
    local body, err = readRaw(src, rel)
    if body then
      local doc = textutils.unserializeJSON(body)
      if type(doc) == "table" then
        vfs.writeFile(cp, body)
        return doc
      end
      return nil, "bad JSON from " .. src.name
    end
    local cached = vfs.readJSON(cp) -- network failed: fall back to whatever we had
    if cached then return cached end
    return nil, err
  end
  local body, err = readRaw(src, rel)
  if not body then return nil, err end
  local doc = textutils.unserializeJSON(body)
  if type(doc) ~= "table" then return nil, "bad JSON in " .. src.name end
  return doc
end

function M.getIndex(src, force) return getDoc(src, "registry/index.json", force) end

function M.getPackage(src, name, force)
  return getDoc(src, "registry/packages/" .. name .. ".json", force)
end

--- First source that knows `name`. Returns package doc, source.
function M.findPackage(name, force)
  for _, src in ipairs(M.list()) do
    local doc = M.getPackage(src, name, force)
    if doc then return doc, src end
  end
  return nil, "package not found: " .. name
end

--- Refresh the cached index of every source. Returns { [sourceName] = true | errorString }.
function M.update()
  local res = {}
  for _, src in ipairs(M.list()) do
    local idx, err = M.getIndex(src, true)
    res[src.name] = idx and true or err
  end
  return res
end

--- Merged view of all indexes: name -> entry (with .source). Earlier sources win.
function M.allPackages()
  local out = {}
  for _, src in ipairs(M.list()) do
    local idx = M.getIndex(src)
    if idx and idx.packages then
      for name, entry in pairs(idx.packages) do
        if not out[name] then
          local e = {}
          for k, v in pairs(entry) do e[k] = v end
          e.source = src.name
          out[name] = e
        end
      end
    end
  end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Blobs
---------------------------------------------------------------------------------------------------------------------

--- Fetch a payload by its SHA-256 from the first source that has it (offline store first). Verified.
function M.getBlob(sha, preferred)
  local order = {}
  local seen = {}
  local all = M.list()
  for _, src in ipairs(all) do
    if src.type == "dir" or (preferred and src.name == preferred) then order[#order + 1] = src seen[src] = true end
  end
  for _, src in ipairs(all) do
    if not seen[src] then order[#order + 1] = src end
  end
  local lastErr = "no sources"
  for _, src in ipairs(order) do
    local data, err = readRaw(src, "blobs/" .. sha)
    if data then
      if hash.sha256(data) == sha then return data, src.name end
      lastErr = "checksum mismatch from " .. src.name
      log.warn("blob %s from %s failed verification", sha:sub(1, 12), src.name)
    else
      lastErr = err
    end
  end
  return nil, lastErr
end

---------------------------------------------------------------------------------------------------------------------
-- Offline import
---------------------------------------------------------------------------------------------------------------------

--- Store a parsed bundle (tsr.bundle) in the offline source. Returns { packages = n, blobs = n }.
function M.importBundle(b)
  local root = M.offlineDir
  local idxPath = root .. "/registry/index.json"
  local idx = vfs.readJSON(idxPath) or { format = 1, packages = {} }
  if b.index and b.index.packages then
    for name, entry in pairs(b.index.packages) do idx.packages[name] = entry end
  end
  for name, doc in pairs(b.packages) do
    vfs.writeJSON(root .. "/registry/packages/" .. name .. ".json", doc)
    if not idx.packages[name] and doc.latest and doc.versions and doc.versions[doc.latest] then
      local m = doc.versions[doc.latest]
      idx.packages[name] = { version = m.version, type = m.type, description = m.description, size = m.size and m.size.installed }
    end
  end
  vfs.writeJSON(idxPath, idx)
  local nb = 0
  for sha, data in pairs(b.blobs) do
    vfs.writeFile(root .. "/blobs/" .. sha, data, true)
    nb = nb + 1
  end
  local np = 0
  for _ in pairs(b.packages) do np = np + 1 end
  return { packages = np, blobs = nb }
end

--- Delete the offline store and the metadata cache (frees space).
function M.clean(all)
  if fs.exists(M.offlineDir) then fs.delete(M.offlineDir) end
  if all and fs.exists(M.cacheDir) then fs.delete(M.cacheDir) end
end

return M
