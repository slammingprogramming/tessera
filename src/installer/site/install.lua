-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Tessera bootstrap installer. Run with:   wget run https://OWNER.github.io/REPO/install.lua
-- (or `pastebin run <id>`, or from a disk / mounted mirror: install.lua /disk/mirror).
--
-- It installs just enough — `core` and `pkg` — to get a working package manager, by the first channel that works:
--   1. HTTP mirrors (GitHub Pages)     2. Pastebin snapshot     3. a mirror directory on a disk (path argument)
--   4. fully offline: drop a bundle file on this window (or  --bundle <file>) / paste TSR1 lines
-- Every payload is checked against its SHA-256 before being written. Everything else (the setup wizard, apps,
-- drivers) is then installed with the package manager itself.
--
-- Options:  <path>        mirror directory      --bundle <file>   offline bundle file
--           --yes         no questions          --no-reboot       do not offer a reboot
--@inline tsr.hash tsr.inflate tsr.bundle tsr.pkg.importer

local BASES = { "https://OWNER.github.io/REPO" }
local SNAPSHOT = "@PASTEBIN_SNAPSHOT@"
local SET = { "core", "pkg" }

local args = { ... }
local opts = { yes = false, reboot = true }
local dirArg, bundleFile
do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--yes" or a == "-y" then opts.yes = true
    elseif a == "--no-reboot" then opts.reboot = false
    elseif a == "--bundle" then i = i + 1 bundleFile = args[i]
    else dirArg = a end
    i = i + 1
  end
end

local hash = require("tsr.hash")

local function color(c) if term.isColor() then term.setTextColor(c) end end
local function say(c, s) color(c) print(s) color(colors.white) end
local function die(s) say(colors.red, "Install failed: " .. s) error("", 0) end

---------------------------------------------------------------------------------------------------------------------
-- Channels: each returns get(rel) -> data | nil, err   (rel like "registry/index.json" or "blobs/<sha>")
---------------------------------------------------------------------------------------------------------------------

local function httpGet(url)
  if not http then return nil, "HTTP is disabled" end
  local okCheck, why = http.checkURL(url)
  if not okCheck then return nil, tostring(why) end
  local h, err, eh = http.get({ url = url, binary = true, timeout = 20 })
  if not h then
    if eh then local c = eh.getResponseCode() eh.close() return nil, "HTTP " .. tostring(c) end
    return nil, tostring(err)
  end
  local code, body = h.getResponseCode(), h.readAll()
  h.close()
  if code ~= 200 then return nil, "HTTP " .. code end
  return body or ""
end

local function trySources()
  -- mirror directory given on the command line (disk drive, mounted folder)
  if dirArg then
    if not fs.exists(dirArg .. "/registry/index.json") then die(dirArg .. " does not look like a Tessera mirror") end
    say(colors.lightGray, "channel: directory " .. dirArg)
    return function(rel)
      local h = fs.open(dirArg .. "/" .. rel, "rb")
      if not h then return nil, "missing " .. rel end
      local d = h.readAll()
      h.close()
      return d
    end, "dir"
  end
  -- bundle file
  if bundleFile then
    local h = fs.open(bundleFile, "rb")
    if not h then die("cannot read " .. bundleFile) end
    local data = h.readAll()
    h.close()
    local b, err = require("tsr.bundle").parse(data)
    if not b then die(tostring(err)) end
    return b, "bundle"
  end
  -- HTTP mirrors
  if http then
    for _, base in ipairs(BASES) do
      local url = base:gsub("/+$", "")
      local body = httpGet(url .. "/registry/index.json")
      if body then
        say(colors.lightGray, "channel: " .. url)
        return function(rel) return httpGet(url .. "/" .. rel) end, "http"
      end
    end
    -- pastebin snapshot
    if SNAPSHOT ~= "" and not SNAPSHOT:find("@", 1, true) then
      local body = httpGet("https://pastebin.com/raw/" .. SNAPSHOT)
      local snap = body and textutils.unserializeJSON(body)
      if snap then
        say(colors.lightGray, "channel: pastebin")
        return function(rel)
          if rel == "registry/index.json" then return textutils.serializeJSON(snap.index or {}) end
          local key = rel:match("^registry/packages/(.+)%.json$")
          key = key and ("packages/" .. key) or rel:match("^blobs/(%x+)$")
          local id = key and snap.pastes and snap.pastes[key]
          if not id then return nil, "not in snapshot" end
          return httpGet("https://pastebin.com/raw/" .. id)
        end, "pastebin"
      end
    end
  end
  -- offline: ask for a bundle
  say(colors.orange, "No network channel is reachable.")
  say(colors.white, "Continuing OFFLINE. You need a Tessera bundle (see the project page's bundle builder).")
  local b = require("tsr.pkg.importer").interactive({ prompt = "Offline install: provide the bundle" })
  if not b then die("no bundle provided") end
  return b, "bundle"
end

local source, kind = trySources()

--- uniform fetch, whatever the channel
local function get(rel)
  if kind == "bundle" then
    local sha = rel:match("^blobs/(%x+)$")
    if sha then return source.blobs[sha] end
    local name = rel:match("^registry/packages/(.+)%.json$")
    if name then return source.packages[name] and textutils.serializeJSON(source.packages[name]) end
    if rel == "registry/index.json" then return source.index and textutils.serializeJSON(source.index) end
    return nil
  end
  return source(rel)
end

---------------------------------------------------------------------------------------------------------------------
-- Plan: read manifests, verify every payload, check space
---------------------------------------------------------------------------------------------------------------------

say(colors.yellow, "Tessera installer")
local manifests, payloads, total = {}, {}, 0
for _, name in ipairs(SET) do
  local body, err = get("registry/packages/" .. name .. ".json")
  if not body then die("cannot read package '" .. name .. "': " .. tostring(err)) end
  local doc = textutils.unserializeJSON(body)
  local m = doc and doc.versions and doc.versions[doc.latest]
  if not m then die("package '" .. name .. "' has no usable version") end
  manifests[#manifests + 1] = m
  for _, f in ipairs(m.files or {}) do
    if f.path:sub(1, 1) ~= "/" or f.path:find("..", 1, true) or f.path:sub(1, 5) == "/rom/" then
      die("unsafe path in " .. name .. ": " .. f.path)
    end
    if not payloads[f.sha256] then
      write(("\rfetching %-24s"):format(fs.getName(f.path)))
      local data, gerr = get("blobs/" .. f.sha256)
      if not data then die("cannot fetch " .. f.path .. ": " .. tostring(gerr)) end
      if hash.sha256(data) ~= f.sha256 then die("checksum mismatch for " .. f.path) end
      payloads[f.sha256] = data
    end
    total = total + #payloads[f.sha256]
  end
end
print()

local function freeSpace()
  local f = fs.getFreeSpace("/")
  return type(f) == "number" and f or math.huge -- some mounts report "unlimited"; emulators report huge numbers
end
if total + 4096 > freeSpace() then
  die(("not enough space: need %d bytes, %.0f free"):format(total, freeSpace()))
end
print(("Tessera core + package manager: %d bytes, %.0f free."):format(total, freeSpace()))
if fs.exists("/sys/boot.lua") then
  say(colors.orange, "Tessera appears to be installed already; use `pkg upgrade` instead.")
  return
end
if not opts.yes then
  color(colors.yellow)
  write("Install to this computer? Existing /startup.lua is backed up. [y/N] ")
  color(colors.white)
  local a = read()
  if not a or a:lower():sub(1, 1) ~= "y" then return print("Cancelled.") end
end

---------------------------------------------------------------------------------------------------------------------
-- Write files (rolling back on error) and register them with the package database
---------------------------------------------------------------------------------------------------------------------

local written, backups = {}, {}
local function rollback()
  for _, p in ipairs(written) do if fs.exists(p) then fs.delete(p) end end
  for orig, saved in pairs(backups) do
    if fs.exists(saved) then fs.move(saved, orig) end
  end
end

local ok, err = pcall(function()
  for _, m in ipairs(manifests) do
    for _, f in ipairs(m.files) do
      if fs.exists(f.path) then
        local saved = "/etc/tsr/backup" .. f.path
        if fs.exists(saved) then fs.delete(saved) end
        fs.move(f.path, saved)
        backups[f.path] = saved
      end
      local h = fs.open(f.path, "wb")
      if not h then error("cannot write " .. f.path) end
      written[#written + 1] = f.path
      h.write(payloads[f.sha256])
      h.close()
    end
  end
end)
if not ok then
  rollback()
  die(tostring(err))
end

local ok2, err2 = pcall(function()
  local loader = dofile("/sys/lib/tsr/loader.lua")
  local db = loader.require("tsr.pkg.db")
  for _, m in ipairs(manifests) do
    local files = {}
    for _, f in ipairs(m.files) do files[#files + 1] = { path = f.path, sha256 = f.sha256, size = f.size } end
    db.set(m.name, { version = m.version, reason = "manual", files = files, requires = m.requires,
                     provides = m.provides, license = m.license, source = m.source, time = os.epoch("utc") })
  end
  assert(db.save())
  if kind == "bundle" then loader.require("tsr.pkg").importBundle(source) end
end)
if not ok2 then
  rollback()
  die("could not register packages: " .. tostring(err2))
end

say(colors.lime, "Installed Tessera core and the package manager.")
print("Next: reboot, then run `pkg install <name>` (try `pkg search`).")
if opts.reboot and not opts.yes then
  color(colors.yellow)
  write("Reboot now? [Y/n] ")
  color(colors.white)
  local a = read()
  if not a or a == "" or a:lower():sub(1, 1) == "y" then os.reboot() end
end
