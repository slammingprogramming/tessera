-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Package mirror server. Caches registry documents and blobs read from this computer's own package sources (internet,
-- offline bundles, ...) and serves them to paired computers through the "pkgmirror" service. Clients use a `lan` source
-- (tsr.pkg.src_lan). Everything is verified by the client anyway (blobs by SHA-256); pair only with mirrors you trust, because
-- manifests are only as trustworthy as the computer that serves them.
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local source = require("tsr.pkg.source")

local M = {}

M.cacheDir = "/var/cache/tsr/mirror"
M.CHUNK = 16384
M.INDEX_MAX_AGE = 600        -- seconds before the index is fetched again from upstream

local function validRel(rel)
  if type(rel) ~= "string" then return false end
  if rel == "registry/index.json" then return true end
  if rel:match("^registry/packages/[%w_%-%.]+%.json$") then return true end
  if rel:match("^blobs/%x+$") and #rel == 6 + 64 then return true end
  return false
end
M.validRel = validRel

--- Test hook: function returning the list of upstream sources (default: this computer's configured sources).
M.upstreamList = nil

local function upstream(rel)
  local lastErr = "no upstream sources"
  for _, src in ipairs((M.upstreamList or source.list)()) do
    if src.type ~= "lan" then
      local data, err = source.read(src, rel)
      if data then return data end
      lastErr = err or lastErr
    end
  end
  return nil, lastErr
end

local function age(path)
  local ok, attrs = pcall(fs.attributes, path)
  if not ok or type(attrs) ~= "table" or not attrs.modified then return math.huge end
  return (os.epoch("utc") - attrs.modified) / 1000
end

--- The bytes for registry file `rel`: from the cache, else upstream (then cached). Returns data or nil + error.
function M.get(rel)
  if not validRel(rel) then return nil, "bad path" end
  local path = M.cacheDir .. "/" .. rel
  local cached = vfs.readFile(path, true)
  local isBlob = rel:sub(1, 6) == "blobs/"
  if cached and (isBlob or age(path) < M.INDEX_MAX_AGE) then return cached end
  local data, err = upstream(rel)
  if data then
    if isBlob and hash.sha256(data) ~= rel:sub(7) then return nil, "upstream blob failed verification" end
    vfs.writeFile(path, data, true)
    return data
  end
  if cached then return cached end             -- upstream unreachable: stale beats nothing
  return nil, err
end

--- Register the "pkgmirror" service on `node`.
function M.serve(node)
  node:serve("pkgmirror", function(from, method, a)
    if method ~= "read" or type(a) ~= "table" then error("unknown method", 0) end
    local data, err = M.get(a.rel)
    if not data then error(tostring(err), 0) end
    local offset = tonumber(a.offset) or 0
    local piece = data:sub(offset + 1, offset + M.CHUNK)
    return { data = hash.base64Encode(piece), eof = offset + #piece >= #data, size = #data }
  end, { async = true })
end

--- Download everything needed to install `names` (and their dependencies) into the cache, so clients can install while this
--- computer is offline. names nil = every package in the index. Returns counts and a list of problems.
function M.prefetch(names, log)
  log = log or function() end
  local indexData, err = M.get("registry/index.json")
  if not indexData then return nil, err end
  local index = textutils.unserializeJSON(indexData)
  local want, queue, problems, blobs, pkgs = {}, {}, {}, 0, 0
  if names and #names > 0 then
    for _, n in ipairs(names) do queue[#queue + 1] = n end
  else
    for n in pairs(index.packages or {}) do queue[#queue + 1] = n end
    table.sort(queue)
  end
  while #queue > 0 do
    local name = table.remove(queue, 1)
    if not want[name] then
      want[name] = true
      local doc, derr = M.get("registry/packages/" .. name .. ".json")
      if not doc then
        problems[#problems + 1] = name .. ": " .. tostring(derr)
      else
        pkgs = pkgs + 1
        doc = textutils.unserializeJSON(doc)
        local manifest = doc and doc.versions and doc.versions[doc.latest]
        if manifest then
          log("fetching " .. name .. " " .. tostring(doc.latest))
          for _, f in ipairs(manifest.files or {}) do
            local blob, berr = M.get("blobs/" .. f.sha256)
            if blob then blobs = blobs + 1 else problems[#problems + 1] = name .. " " .. f.path .. ": " .. tostring(berr) end
          end
          for dep in pairs(manifest.requires or {}) do queue[#queue + 1] = dep end
        end
      end
    end
  end
  return { packages = pkgs, blobs = blobs, problems = problems }
end

function M.clear()
  if fs.exists(M.cacheDir) then fs.delete(M.cacheDir) end
end

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  return io
end

--- pkgmirror status | find | prefetch [package...] | clear | add <peer> (adds a lan source for a paired mirror)
function M.run(args, io, node)
  io = io or defaultIO()
  local cmd = args[1] or "status"
  if cmd == "status" then
    local n, bytes = 0, 0
    local function walk(dir)
      if not fs.isDir(dir) then return end
      for _, f in ipairs(fs.list(dir)) do
        local p = dir .. "/" .. f
        if fs.isDir(p) then walk(p) else n = n + 1 bytes = bytes + fs.getSize(p) end
      end
    end
    walk(M.cacheDir)
    io.say(("cache: %d files, %.1f KB"):format(n, bytes / 1024))
    return true
  elseif cmd == "find" then
    node = node or require("tsr.net").default()
    local found = node:lookup("pkgmirror", 1)
    if #found == 0 then io.say("No package mirror answered.") end
    for _, f in ipairs(found) do
      local paired = node:peer(f.id) and " (paired)" or " (not paired: net pair first)"
      io.say(f.id .. "  " .. f.host .. paired)
    end
    return true
  elseif cmd == "prefetch" then
    local names = { table.unpack(args, 2) }
    local res, err = M.prefetch(#names > 0 and names or nil, function(t) io.say(t) end)
    if not res then io.err("prefetch failed: " .. tostring(err)) return false end
    io.say(("cached %d packages, %d files"):format(res.packages, res.blobs))
    for _, p in ipairs(res.problems) do io.err("problem: " .. p) end
    return #res.problems == 0
  elseif cmd == "clear" then
    M.clear()
    io.say("Cache cleared.")
    return true
  elseif cmd == "add" then
    local peer = args[2]
    if not peer then io.err("usage: pkgmirror add <paired computer name>") return false end
    local config = require("tsr.config")
    local list = config.get("pkg.sources", {})
    local copy = {}
    for _, s in ipairs(list) do if s.name ~= "lan-" .. peer then copy[#copy + 1] = s end end
    table.insert(copy, 1, { name = "lan-" .. peer, type = "lan", peer = peer })
    config.set("pkg.sources", copy, "system")
    io.say("Packages will now be fetched from " .. peer .. " first. Run `pkg update`.")
    return true
  end
  io.err("usage: pkgmirror status | find | add <peer> | prefetch [package...] | clear")
  return false
end

function M.main(args) return M.run(args) end

--- The pkgmirrord service.
function M.daemon()
  M.serve(require("tsr.net").default())
  while true do os.pullEvent("pkgmirror_never") end
end

return M
