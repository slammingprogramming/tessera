-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Package sources ("channels"). Every source exposes the same static layout:
--   registry/index.json                     { format, packages = { name = {version, type, description, size, provides} } }
--   registry/packages/<name>.json           { name, latest, versions = { ["1.0.0"] = manifest } }
--   blobs/<sha256>                          file payloads, content-addressed (verified after download)
-- Source types:
--   http      one or more mirror base URLs (GitHub Pages, ...)        { type="http", bases={...} }
--   dir       a directory with the layout above (disk, mount, offline import store)   { type="dir", path="..." }
--   pastebin  a "snapshot" paste mapping registry files to pastes     { type="pastebin", snapshot="<id>" }  (see tsr.pkg.pasteref; long files span several pastes: "id1+id2")
-- Registries may be signed (see tsr.pkg.trust): registry/index.json.sig vouches for the index, and the index records the
-- SHA-256 of every package description ("docSha256"); registry/trust.json(.sig) carries signed key updates.
--   lan       a paired computer running the pkg-mirror service         { type="lan", peer="<name>" }  (package pkg-mirror)
-- The built-in `offline` source is a `dir` at /var/cache/tsr/offline, filled by importing a bundle. It is always
-- consulted first, so pasting a bundle makes an HTTP-less install possible.
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local config = require("tsr.config")
local trust = require("tsr.pkg.trust")
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

--- One raw paste (replaced in tests).
function M.pasteGet(id) return httpGet("https://pastebin.com/raw/" .. id) end

local function snapshot(src)
  if src._snap then return src._snap end
  local snap, err = require("tsr.pkg.pasteref").loadSnapshot(src.snapshot, function(id) return M.pasteGet(id) end)
  if not snap then return nil, err end
  src._snap = snap
  return snap
end

fetchers.pastebin = {
  read = function(src, rel)
    local snap, err = snapshot(src)
    if not snap then return nil, err end
    return require("tsr.pkg.pasteref").read(snap, rel, function(id) return M.pasteGet(id) end)
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

--- Raw text of a registry file for `src`: from the cache (unless `force`), else the source (then cached). Network failures fall back
--- to the cache so browsing works offline after `pkg update`.
local function getRaw(src, rel, force)
  local cp = cachePath(src, rel)
  if src.type ~= "dir" then
    if not force then
      local cached = vfs.readFile(cp, true)
      if cached then return cached end
    end
    local body, err = readRaw(src, rel)
    if body then
      vfs.writeFile(cp, body)
      return body
    end
    local cached = vfs.readFile(cp, true)
    if cached then return cached end
    return nil, err
  end
  return readRaw(src, rel)
end

local function parseDoc(body, name)
  local doc = textutils.unserializeJSON(body)
  if type(doc) ~= "table" then return nil, "bad JSON from " .. name end
  return doc
end

--- The registry index of `src`, signature-checked according to the policy in tsr.pkg.trust. Returns index, status or nil, err.
function M.getIndex(src, force)
  if src._index and not force then return src._index, src._indexStatus end
  local body, err = getRaw(src, "registry/index.json", force)
  if not body then return nil, err end
  local sigRaw
  if trust.policy() ~= "off" then
    sigRaw = getRaw(src, "registry/index.json.sig", force)
    -- a cached copy from before the registry was signed: refetch both together once
    if not sigRaw and not force and src.type ~= "dir" then
      body = getRaw(src, "registry/index.json", true) or body
      sigRaw = getRaw(src, "registry/index.json.sig", true)
    end
  end
  local ok, status = trust.verifyIndex(src.name, body, sigRaw)
  if not ok then
    log.warn("%s: %s", src.name, tostring(status))
    return nil, tostring(status)
  end
  local doc, perr = parseDoc(body, src.name)
  if not doc then return nil, perr end
  src._index, src._indexStatus = doc, status
  return doc, status
end

function M.getPackage(src, name, force)
  local body, err = getRaw(src, "registry/packages/" .. name .. ".json", force)
  if not body then return nil, err end
  if trust.policy() ~= "off" then
    local idx, ierr = M.getIndex(src)
    if not idx then return nil, ierr end
    local ok, why = trust.verifyDoc(idx.packages and idx.packages[name], body)
    if not ok then
      log.warn("%s/%s: %s", src.name, name, tostring(why))
      return nil, why
    end
  end
  return parseDoc(body, name)
end

--- First source that knows `name`. Returns package doc, source.
function M.findPackage(name, force)
  local problem
  for _, src in ipairs(M.list()) do
    local doc, err = M.getPackage(src, name, force)
    if doc then return doc, src end
    if err and tostring(err):find("signed", 1, true) then problem = src.name .. ": " .. tostring(err) end   -- a refusal, not just absence
  end
  return nil, problem or ("package not found: " .. name)
end

--- Refresh the cached index of every source. Returns { [sourceName] = true | errorString }.
function M.update()
  local res = {}
  for _, src in ipairs(M.list()) do
    local idx, err = M.getIndex(src, true)
    res[src.name] = idx and true or err
    if idx and src.type ~= "dir" then
      local raw = getRaw(src, "registry/trust.json", true)
      local sigRaw = raw and getRaw(src, "registry/trust.json.sig", true)
      if raw and sigRaw then
        local applied, terr = trust.applyUpdate(raw, sigRaw)
        if applied then log.info("trust update from %s: %d key(s) added, %d revoked", src.name, applied.added, applied.revoked)
        elseif not tostring(terr):find("not newer", 1, true) then log.warn("trust update from %s ignored: %s", src.name, tostring(terr)) end
      end
    end
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
        local available = src.name ~= "offline" or fs.exists(src.path .. "/registry/packages/" .. name .. ".json")
        if available and not out[name] then
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

--- Store a parsed bundle (tsr.bundle) in the offline source. A bundle that carries a signed index is checked like any registry:
--- when signatures are required it must be signed by a trusted key, must not be older than what is stored, and every package
--- description in it must match the signed index. Returns { packages = n, blobs = n } or nil, err.
function M.importBundle(b)
  local root = M.offlineDir
  local idxPath = root .. "/registry/index.json"
  local policy = trust.policy()
  local signed = b.indexRaw and b.indexSig
  if signed then
    local ok, status = trust.verifyIndex("offline-import", b.indexRaw, b.indexSig)
    if not ok then return nil, "bundle rejected: " .. tostring(status) end
    local index = b.index or {}
    for name, raw in pairs(b.packageRaw or {}) do
      local good, why = trust.verifyDoc(index.packages and index.packages[name], raw)
      if not good then return nil, "bundle rejected: " .. tostring(why) end
    end
    local old = vfs.readJSON(idxPath)
    if old and tonumber(old.serial) and tonumber(index.serial) and tonumber(index.serial) < tonumber(old.serial) then
      return nil, "bundle rejected: it is older than the registry data already stored"
    end
    vfs.writeFile(idxPath, b.indexRaw)
    vfs.writeFile(idxPath .. ".sig", b.indexSig)
  elseif policy == "require" then
    return nil, "bundle rejected: it is not signed (signatures are required; see `pkg trust`)"
  else
    local idx = vfs.readJSON(idxPath) or { format = 1, packages = {} }
    if b.index and b.index.packages then
      for name, entry in pairs(b.index.packages) do idx.packages[name] = entry end
    end
    idx.serial, idx.generated = nil, nil
    vfs.writeJSON(idxPath, idx)
    if fs.exists(idxPath .. ".sig") then fs.delete(idxPath .. ".sig") end
  end
  for name, doc in pairs(b.packages) do
    local raw = b.packageRaw and b.packageRaw[name]
    if raw then
      vfs.writeFile(root .. "/registry/packages/" .. name .. ".json", raw)
    else
      vfs.writeJSON(root .. "/registry/packages/" .. name .. ".json", doc)
    end
  end
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
