-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Snapshots: remember what a folder looked like, compare later, restore. File contents are stored once by SHA-256 in
-- /var/snapshots/blobs, so many snapshots of mostly unchanged files cost little. A snapshot is a manifest
-- /var/snapshots/<name>.json listing every file with its checksum.
--   snap create <name> [folder]       snap list       snap diff <name> [other]       snap restore <name> [folder] [--prune]
--   snap delete <name>                snap export <name> <dir>   snap import <dir> <name>
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")

local M = {}

M.DIR = "/var/snapshots"
M.SKIP = { "/rom", "/var/snapshots", "/var/trash", "/tmp", "/var/cache" }

local function manifestPath(name) return M.DIR .. "/" .. name .. ".json" end
local function blobPath(sha) return M.DIR .. "/blobs/" .. sha end

local function validName(name) return type(name) == "string" and name:match("^[%w_%-%.]+$") ~= nil end

local function skipped(path)
  for _, s in ipairs(M.SKIP) do
    if path == s or path:sub(1, #s + 1) == s .. "/" then return true end
  end
  return false
end

local function readAll(path)
  local h = fs.open(path, "rb")
  if not h then return nil end
  local s = h.readAll() or ""
  h.close()
  return s
end

--- Walk a folder: returns files = { [absolute path] = true } (skipped places excluded).
local function walk(root, out, depth)
  depth = depth or 0
  out = out or {}
  if depth > 24 then return out end
  for _, name in ipairs(fs.list(root)) do
    local full = vfs.join(root, name)
    if not skipped(full) then
      if fs.isDir(full) then walk(full, out, depth + 1) else out[full] = true end
    end
  end
  return out
end

--- Take a snapshot of `root` (default /etc/tsr). opts.progress(path) is called per file, opts.sleep yields between files.
--- Returns { files = n, bytes = n, new = n (blobs that were not stored yet) } or nil + reason.
function M.create(name, root, opts)
  opts = opts or {}
  root = vfs.normalize(root or "/etc/tsr")
  if not validName(name) then return nil, "snapshot names use letters, digits, - _ ." end
  if fs.exists(manifestPath(name)) then return nil, "a snapshot called " .. name .. " already exists" end
  if not fs.isDir(root) then return nil, "not a folder: " .. root end
  local files = walk(root)
  local paths = {}
  for p in pairs(files) do paths[#paths + 1] = p end
  table.sort(paths)
  local manifest = { name = name, root = root, created = os.epoch and os.epoch("utc") or 0, files = {} }
  local bytes, fresh = 0, 0
  for _, p in ipairs(paths) do
    local data = readAll(p)
    if data then
      local sha = hash.sha256(data)
      if not fs.exists(blobPath(sha)) then
        vfs.writeFile(blobPath(sha), data, true)
        fresh = fresh + 1
      end
      manifest.files[p:sub(#root + (root == "/" and 1 or 2))] = { sha = sha, size = #data }
      bytes = bytes + #data
      if opts.progress then opts.progress(p) end
      if opts.sleep then opts.sleep() end
    end
  end
  vfs.writeJSON(manifestPath(name), manifest)
  return { files = #paths, bytes = bytes, new = fresh }
end

function M.load(name)
  return vfs.readJSON(manifestPath(name))
end

--- All snapshots, oldest first: { name, root, created, files }.
function M.list()
  local out = {}
  if not fs.isDir(M.DIR) then return out end
  for _, f in ipairs(fs.list(M.DIR)) do
    local name = f:match("^(.+)%.json$")
    if name then
      local m = M.load(name)
      if m then
        local n = 0
        for _ in pairs(m.files) do n = n + 1 end
        out[#out + 1] = { name = name, root = m.root, created = m.created or 0, files = n }
      end
    end
  end
  table.sort(out, function(a, b) return a.created < b.created end)
  return out
end

--- Current state of `root` as a manifest-like table (hashes computed now).
local function live(root)
  local m = { root = root, files = {} }
  for p in pairs(walk(root)) do
    local data = readAll(p)
    if data then m.files[p:sub(#root + (root == "/" and 1 or 2))] = { sha = hash.sha256(data), size = #data } end
  end
  return m
end

--- Differences from snapshot `name` to `other` (another snapshot's name) or to the live folder (default).
--- Returns { added = {...}, removed = {...}, changed = {...} } (relative paths, sorted) or nil + reason.
function M.diff(name, other)
  local a = M.load(name)
  if not a then return nil, "no such snapshot: " .. tostring(name) end
  local b
  if other then
    b = M.load(other)
    if not b then return nil, "no such snapshot: " .. tostring(other) end
  else
    b = live(a.root)
  end
  local d = { added = {}, removed = {}, changed = {} }
  for p, f in pairs(b.files) do
    if not a.files[p] then d.added[#d.added + 1] = p elseif a.files[p].sha ~= f.sha then d.changed[#d.changed + 1] = p end
  end
  for p in pairs(a.files) do
    if not b.files[p] then d.removed[#d.removed + 1] = p end
  end
  table.sort(d.added) table.sort(d.removed) table.sort(d.changed)
  return d
end

--- Put snapshot `name` back into `root` (default: where it was taken). Missing blobs are reported. opts.prune deletes files
--- that were not in the snapshot; opts.only restricts to relative paths in that list. Returns { restored = n, pruned = n } or nil + reason.
function M.restore(name, root, opts)
  opts = opts or {}
  local m = M.load(name)
  if not m then return nil, "no such snapshot: " .. tostring(name) end
  root = vfs.normalize(root or m.root)
  local only
  if opts.only then only = {} for _, p in ipairs(opts.only) do only[p] = true end end
  -- read and verify every file first so a damaged snapshot changes nothing
  local contents = {}
  for p, f in pairs(m.files) do
    if not only or only[p] then
      local data = fs.exists(blobPath(f.sha)) and readAll(blobPath(f.sha))
      if not data then return nil, "the snapshot is damaged: missing data for " .. p end
      if hash.sha256(data) ~= f.sha then return nil, "the snapshot is damaged: " .. p .. " fails its checksum" end
      contents[p] = data
    end
  end
  local restored, pruned = 0, 0
  for p, data in pairs(contents) do
    do
      local target = vfs.join(root, p)
      local current = fs.exists(target) and not fs.isDir(target) and readAll(target)
      if current ~= data then
        vfs.writeFile(target, data, true)
        restored = restored + 1
      end
    end
  end
  if opts.prune then
    for p in pairs(walk(root)) do
      local rel = p:sub(#root + (root == "/" and 1 or 2))
      if not m.files[rel] and (not only or only[rel]) then fs.delete(p) pruned = pruned + 1 end
    end
  end
  return { restored = restored, pruned = pruned }
end

--- Remove blobs that no snapshot refers to. Returns how many were deleted.
function M.gc()
  local used = {}
  for _, s in ipairs(M.list()) do
    local m = M.load(s.name)
    for _, f in pairs(m.files) do used[f.sha] = true end
  end
  local n = 0
  if fs.isDir(M.DIR .. "/blobs") then
    for _, sha in ipairs(fs.list(M.DIR .. "/blobs")) do
      if not used[sha] then fs.delete(blobPath(sha)) n = n + 1 end
    end
  end
  return n
end

function M.delete(name)
  if not fs.exists(manifestPath(name)) then return nil, "no such snapshot: " .. tostring(name) end
  fs.delete(manifestPath(name))
  return M.gc()
end

--- Copy a snapshot (manifest and its blobs) to `dir`, for example a floppy disk. Returns the number of files written.
function M.export(name, dir)
  local m = M.load(name)
  if not m then return nil, "no such snapshot: " .. tostring(name) end
  dir = vfs.normalize(dir)
  local n = 0
  for _, f in pairs(m.files) do
    local dest = dir .. "/blobs/" .. f.sha
    if not fs.exists(dest) then
      local data = readAll(blobPath(f.sha))
      if not data then return nil, "missing data for a file; the snapshot is damaged" end
      local ok, err = vfs.writeFile(dest, data, true)
      if ok == false then return nil, tostring(err) end
      n = n + 1
    end
  end
  vfs.writeJSON(dir .. "/" .. name .. ".json", m)
  return n + 1
end

--- Bring a snapshot in from `dir` under `name`. Returns the number of blobs copied.
function M.import(dir, name, as)
  dir = vfs.normalize(dir)
  local m = vfs.readJSON(dir .. "/" .. name .. ".json")
  if not m then return nil, "no snapshot " .. name .. " in " .. dir end
  as = as or name
  if fs.exists(manifestPath(as)) then return nil, "a snapshot called " .. as .. " already exists" end
  local n = 0
  for _, f in pairs(m.files) do
    if not fs.exists(blobPath(f.sha)) then
      local data = readAll(dir .. "/blobs/" .. f.sha)
      if not data or hash.sha256(data) ~= f.sha then return nil, "the exported data is missing or damaged" end
      vfs.writeFile(blobPath(f.sha), data, true)
      n = n + 1
    end
  end
  m.name = as
  vfs.writeJSON(manifestPath(as), m)
  return n
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

function M.run(args, io)
  io = io or defaultIO()
  local cmd = args[1] or "list"
  local function resolve(p) return p and ((rawget(_G, "shell") and shell.resolve(p)) or p) end
  if cmd == "list" then
    local list = M.list()
    if #list == 0 then io.say("No snapshots. Create one: snap create <name> [folder]") end
    for _, s in ipairs(list) do io.say(("%-16s %-18s %d files"):format(s.name, s.root, s.files)) end
    return true
  elseif cmd == "create" then
    if not args[2] then io.err("usage: snap create <name> [folder]") return false end
    local r, err = M.create(args[2], resolve(args[3]), { sleep = function() if rawget(_G, "sleep") then sleep(0) end end })
    if not r then io.err(err) return false end
    io.say(("Snapshot %s: %d files, %d bytes (%d new)."):format(args[2], r.files, r.bytes, r.new))
    return true
  elseif cmd == "diff" then
    local d, err = M.diff(args[2] or "", args[3])
    if not d then io.err(err) return false end
    for _, p in ipairs(d.added) do io.say("+ " .. p) end
    for _, p in ipairs(d.removed) do io.say("- " .. p) end
    for _, p in ipairs(d.changed) do io.say("~ " .. p) end
    if #d.added + #d.removed + #d.changed == 0 then io.say("No differences.") end
    return true
  elseif cmd == "restore" then
    local prune, root = false, nil
    for i = 3, #args do if args[i] == "--prune" then prune = true else root = resolve(args[i]) end end
    local r, err = M.restore(args[2] or "", root, { prune = prune })
    if not r then io.err(err) return false end
    io.say(("Restored %d files%s."):format(r.restored, prune and (", removed " .. r.pruned .. " extra") or ""))
    return true
  elseif cmd == "delete" then
    local n, err = M.delete(args[2] or "")
    if not n then io.err(err) return false end
    io.say("Deleted (" .. n .. " unused data files removed).")
    return true
  elseif cmd == "export" then
    if not args[2] or not args[3] then io.err("usage: snap export <name> <folder>") return false end
    local n, err = M.export(args[2], resolve(args[3]))
    if not n then io.err(err) return false end
    io.say(n .. " files written.")
    return true
  elseif cmd == "import" then
    if not args[2] or not args[3] then io.err("usage: snap import <folder> <name>") return false end
    local n, err = M.import(resolve(args[2]), args[3])
    if not n then io.err(err) return false end
    io.say("Imported (" .. n .. " data files copied).")
    return true
  end
  io.err("usage: snap list | create | diff | restore | delete | export | import")
  return false
end

function M.main(args) return M.run(args) end

return M
