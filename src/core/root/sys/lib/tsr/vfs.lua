-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Virtual file system layer:
--   * path helpers
--   * crash-safe ("atomic") file writes + recovery of interrupted writes (computers can be chunk-unloaded mid-write)
--   * a mount table, so parts of the tree can be served by providers (RAM disks, remote FS, /dev ...). Calling
--     vfs.install() patches the global `fs` API in place so EVERY program, including stock CraftOS ones, sees mounts.
local M = {}

-- Capture the real fs functions exactly once, even if this module is reloaded.
local raw = rawget(fs, "__tsr_raw")
if not raw then
  raw = {}
  for k, v in pairs(fs) do raw[k] = v end
end
M.raw = raw

---------------------------------------------------------------------------------------------------------------------
-- Paths
---------------------------------------------------------------------------------------------------------------------

--- Normalise to an absolute path without "." / ".." / duplicate slashes ("/" for the root).
function M.normalize(path)
  return "/" .. raw.combine("", path)
end

function M.join(...)
  local p = ""
  for _, part in ipairs({ ... }) do p = p .. "/" .. part end
  return M.normalize(p)
end

function M.dirname(path)
  path = M.normalize(path)
  if path == "/" then return "/" end
  local d = path:match("^(.*)/[^/]*$")
  return d == "" and "/" or d
end

function M.basename(path)
  return raw.getName(path)
end

function M.mkdirp(path)
  path = M.normalize(path)
  if path ~= "/" and not M.fs.exists(path) then
    M.mkdirp(M.dirname(path))
    M.fs.makeDir(path)
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Mounts
---------------------------------------------------------------------------------------------------------------------

local mounts = {} -- array of { prefix = "/mnt/x", provider = p }, kept sorted by prefix length (longest first)

local function sortMounts()
  table.sort(mounts, function(a, b) return #a.prefix > #b.prefix end)
end

--- Mount `provider` at `prefix`. Provider interface (paths are absolute inside the provider, "/" = its root):
---   exists(p) isDir(p) list(p)->names size(p) open(p, mode)->handle|nil,err makeDir(p) delete(p)
---   optional: move(a,b) isReadOnly(p) getFreeSpace() getCapacity()
function M.mount(prefix, provider)
  prefix = M.normalize(prefix)
  if prefix == "/" then error("cannot mount over /", 2) end
  M.unmount(prefix)
  mounts[#mounts + 1] = { prefix = prefix, provider = provider }
  sortMounts()
end

function M.unmount(prefix)
  prefix = M.normalize(prefix)
  for i, m in ipairs(mounts) do
    if m.prefix == prefix then table.remove(mounts, i) return true end
  end
  return false
end

function M.mounts()
  local out = {}
  for _, m in ipairs(mounts) do out[#out + 1] = m.prefix end
  return out
end

--- Find the provider for `path`: returns provider, path-inside-provider or nil (real filesystem).
local function resolve(path)
  for _, m in ipairs(mounts) do
    local pre = m.prefix
    if path == pre then return m.provider, "/", m end
    if path:sub(1, #pre + 1) == pre .. "/" then return m.provider, path:sub(#pre + 1), m end
  end
  return nil
end

---------------------------------------------------------------------------------------------------------------------
-- Routed fs API
---------------------------------------------------------------------------------------------------------------------

local R = {} -- routed functions, same names as the fs API

local function norm(p) return M.normalize(p) end

function R.exists(path)
  path = norm(path)
  local p, sub = resolve(path)
  if p then return p.exists(sub) end
  if raw.exists(path) then return true end
  for _, m in ipairs(mounts) do
    if M.dirname(m.prefix) == path or m.prefix:sub(1, #path + 1) == path .. "/" then return true end
  end
  return false
end

function R.isDir(path)
  path = norm(path)
  local p, sub = resolve(path)
  if p then return p.isDir(sub) end
  if raw.isDir(path) then return true end
  for _, m in ipairs(mounts) do
    if m.prefix:sub(1, #path + 1) == path .. "/" or path == "/" then return true end
  end
  return false
end

function R.list(path)
  path = norm(path)
  local p, sub = resolve(path)
  if p then
    local names = p.list(sub)
    table.sort(names)
    return names
  end
  local names, seen = {}, {}
  if raw.exists(path) and raw.isDir(path) then
    for _, n in ipairs(raw.list(path)) do names[#names + 1] = n seen[n] = true end
  end
  for _, m in ipairs(mounts) do
    local parent = M.dirname(m.prefix)
    if parent == path then
      local n = raw.getName(m.prefix)
      if not seen[n] then names[#names + 1] = n seen[n] = true end
    elseif path == "/" or m.prefix:sub(1, #path + 1) == path .. "/" then
      -- mount deeper below `path`: expose the first path component
      local rest = path == "/" and m.prefix:sub(2) or m.prefix:sub(#path + 2)
      local first = rest:match("^([^/]+)")
      if first and not seen[first] then names[#names + 1] = first seen[first] = true end
    end
  end
  if #names == 0 and not R.exists(path) then error("/" .. raw.combine("", path) .. ": Not a directory", 2) end
  table.sort(names)
  return names
end

function R.getSize(path)
  path = norm(path)
  local p, sub = resolve(path)
  if p then return p.size(sub) end
  return raw.getSize(path)
end

function R.isReadOnly(path)
  path = norm(path)
  local p, sub = resolve(path)
  if p then return p.isReadOnly and p.isReadOnly(sub) or false end
  return raw.isReadOnly(path)
end

function R.getFreeSpace(path)
  path = norm(path)
  local p = resolve(path)
  if p then return p.getFreeSpace and p.getFreeSpace() or 0 end
  return raw.getFreeSpace(path)
end

function R.getCapacity(path)
  path = norm(path)
  local p = resolve(path)
  if p then return p.getCapacity and p.getCapacity() or 0 end
  return raw.getCapacity(path)
end

function R.makeDir(path)
  path = norm(path)
  local p, sub = resolve(path)
  if p then return p.makeDir(sub) end
  return raw.makeDir(path)
end

function R.delete(path)
  path = norm(path)
  local p, sub = resolve(path)
  if p then return p.delete(sub) end
  return raw.delete(path)
end

function R.open(path, mode)
  path = norm(path)
  local p, sub = resolve(path)
  if p then return p.open(sub, mode) end
  return raw.open(path, mode)
end

local function readAllFrom(path)
  local h, err = R.open(path, "rb")
  if not h then error(err or (path .. ": No such file"), 0) end
  local data = h.readAll() or ""
  h.close()
  return data
end

local function copyTree(a, b)
  if R.isDir(a) then
    if not R.exists(b) then R.makeDir(b) end
    for _, n in ipairs(R.list(a)) do copyTree(a .. "/" .. n, b .. "/" .. n) end
  else
    local data = readAllFrom(a)
    local h, err = R.open(b, "wb")
    if not h then error(err or (b .. ": Cannot write"), 0) end
    h.write(data)
    h.close()
  end
end

function R.copy(a, b)
  a, b = norm(a), norm(b)
  local pa, pb = resolve(a), resolve(b)
  if not pa and not pb then return raw.copy(a, b) end
  if not R.exists(a) then error(a .. ": No such file", 2) end
  if R.exists(b) then error(b .. ": File exists", 2) end
  copyTree(a, b)
end

function R.move(a, b)
  a, b = norm(a), norm(b)
  local pa, subA = resolve(a)
  local pb, subB = resolve(b)
  if not pa and not pb then return raw.move(a, b) end
  if pa and pa == pb and pa.move then return pa.move(subA, subB) end
  R.copy(a, b)
  R.delete(a)
end

function R.attributes(path)
  path = norm(path)
  local p, sub = resolve(path)
  if p then
    if not p.exists(sub) then error(path .. ": No such file", 2) end
    return { size = p.size(sub), isDir = p.isDir(sub), isReadOnly = p.isReadOnly and p.isReadOnly(sub) or false,
             created = 0, modified = 0, modification = 0 }
  end
  return raw.attributes(path)
end

M.fs = setmetatable({}, { __index = function(_, k)
  return R[k] or raw[k]
end })

--- Patch the global fs table so all code sees mounts. Idempotent. Only function names in R are replaced.
function M.install()
  if rawget(fs, "__tsr_raw") then return end
  rawset(fs, "__tsr_raw", raw)
  for name, fn in pairs(R) do
    if raw[name] then fs[name] = fn end
  end
end

function M.uninstall()
  if not rawget(fs, "__tsr_raw") then return end
  for name in pairs(R) do
    if raw[name] then fs[name] = raw[name] end
  end
  rawset(fs, "__tsr_raw", nil)
end

---------------------------------------------------------------------------------------------------------------------
-- Whole-file helpers (mount-aware) + atomic writes
---------------------------------------------------------------------------------------------------------------------

function M.readFile(path, binary)
  local h = M.fs.open(path, binary and "rb" or "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s or ""
end

--- Crash-safe write. Sequence: write path.tsr-tmp -> rename to path.tsr-new (marks "complete") -> move the old file
--- to path.tsr-old -> rename new to path -> delete old. M.recover() finishes or rolls back an interrupted sequence.
function M.writeFile(path, data, binary)
  path = M.normalize(path)
  M.mkdirp(M.dirname(path))
  local tmp, new, old = path .. ".tsr-tmp", path .. ".tsr-new", path .. ".tsr-old"
  local h, err = M.fs.open(tmp, binary and "wb" or "w")
  if not h then return false, err end
  h.write(data)
  h.close()
  if M.fs.exists(new) then M.fs.delete(new) end
  M.fs.move(tmp, new)
  if M.fs.exists(old) then M.fs.delete(old) end
  if M.fs.exists(path) then M.fs.move(path, old) end
  M.fs.move(new, path)
  if M.fs.exists(old) then M.fs.delete(old) end
  return true
end

--- Repair interrupted atomic writes under `dir` (default "/"). Returns the number of repairs made.
function M.recover(dir, depth)
  dir = M.normalize(dir or "/")
  depth = depth or 0
  if depth > 12 or dir == "/rom" or not M.fs.isDir(dir) then return 0 end
  local fixed = 0
  for _, name in ipairs(M.fs.list(dir)) do
    local p = M.join(dir, name)
    if M.fs.isDir(p) then
      if name ~= "rom" or dir ~= "/" then fixed = fixed + M.recover(p, depth + 1) end
    elseif name:sub(-8) == ".tsr-tmp" then
      M.fs.delete(p) fixed = fixed + 1                      -- partial write: discard
    elseif name:sub(-8) == ".tsr-new" then
      local target = p:sub(1, -9)
      if M.fs.exists(target) then M.fs.delete(target) end
      M.fs.move(p, target)                                  -- complete write: finish it
      if M.fs.exists(target .. ".tsr-old") then M.fs.delete(target .. ".tsr-old") end
      fixed = fixed + 1
    elseif name:sub(-8) == ".tsr-old" then
      local target = p:sub(1, -9)
      if M.fs.exists(target) then M.fs.delete(p) else M.fs.move(p, target) end
      fixed = fixed + 1
    end
  end
  return fixed
end

function M.readTable(path)
  local s = M.readFile(path)
  if not s then return nil end
  return textutils.unserialize(s)
end

function M.writeTable(path, t)
  return M.writeFile(path, textutils.serialize(t))
end

function M.readJSON(path)
  local s = M.readFile(path)
  if not s then return nil end
  return textutils.unserializeJSON(s)
end

function M.writeJSON(path, t)
  return M.writeFile(path, textutils.serializeJSON(t))
end

---------------------------------------------------------------------------------------------------------------------
-- RAM file system provider
---------------------------------------------------------------------------------------------------------------------

--- A volatile in-memory provider, e.g. vfs.mount("/tmp", vfs.ramfs(64 * 1024)).
function M.ramfs(capacity)
  capacity = capacity or 256 * 1024
  local root = { dir = true, kids = {} }
  local used = 0
  local P = {}

  local function walk(path, create)
    local node = root
    for part in path:gmatch("[^/]+") do
      if not node.dir then return nil end
      local nxt = node.kids[part]
      if not nxt then
        if not create then return nil end
        nxt = { dir = true, kids = {} }
        node.kids[part] = nxt
      end
      node = nxt
    end
    return node
  end

  local function parentOf(path)
    local dir, name = path:match("^(.*)/([^/]+)$")
    return walk(dir or "", false), name
  end

  function P.exists(p) return walk(p) ~= nil end
  function P.isDir(p) local n = walk(p) return n ~= nil and n.dir == true end
  function P.list(p)
    local n = walk(p)
    if not n or not n.dir then error(p .. ": Not a directory", 0) end
    local out = {}
    for k in pairs(n.kids) do out[#out + 1] = k end
    return out
  end
  function P.size(p)
    local n = walk(p)
    if not n then error(p .. ": No such file", 0) end
    return n.dir and 0 or #n.data
  end
  function P.makeDir(p)
    local n = walk(p)
    if n and not n.dir then error(p .. ": File exists", 0) end
    walk(p, true)
  end
  function P.delete(p)
    if p == "/" then error("Access denied", 0) end
    local parent, name = parentOf(p)
    local n = parent and parent.kids[name]
    if not n then return end
    local function total(x)
      if not x.dir then return #x.data end
      local s = 0
      for _, k in pairs(x.kids) do s = s + total(k) end
      return s
    end
    used = used - total(n)
    parent.kids[name] = nil
  end
  function P.move(a, b)
    local pa, na = parentOf(a)
    local pb, nb = parentOf(b)
    if not (pa and pa.kids[na]) then error(a .. ": No such file", 0) end
    if not pb then error(b .. ": No such directory", 0) end
    if pb.kids[nb] then error(b .. ": File exists", 0) end
    pb.kids[nb] = pa.kids[na]
    pa.kids[na] = nil
  end
  function P.getFreeSpace() return capacity - used end
  function P.getCapacity() return capacity end
  function P.isReadOnly() return false end

  function P.open(p, mode)
    local m = mode:sub(1, 1)
    local binary = mode:sub(2, 2) == "b"
    local node = walk(p)
    if node and node.dir then return nil, p .. ": Cannot read a directory" end
    if m == "r" then
      if not node then return nil, p .. ": No such file" end
      local data, pos = node.data, 1
      local h = {}
      function h.readAll()
        if pos > #data then return nil end
        local s = data:sub(pos)
        pos = #data + 1
        return s
      end
      function h.readLine(keep)
        if pos > #data then return nil end
        local nl = data:find("\n", pos, true)
        local line
        if nl then
          line = data:sub(pos, keep and nl or nl - 1)
          pos = nl + 1
        else
          line = data:sub(pos)
          pos = #data + 1
        end
        if not keep then line = line:gsub("\r$", "") end
        return line
      end
      function h.read(n)
        if pos > #data then return nil end
        if not n then
          local c = data:sub(pos, pos)
          pos = pos + 1
          return binary and c:byte() or c
        end
        local s = data:sub(pos, pos + n - 1)
        pos = pos + #s
        return s
      end
      function h.seek(whence, off)
        whence, off = whence or "cur", off or 0
        local base = whence == "set" and 0 or whence == "end" and #data or pos - 1
        pos = math.max(0, base + off) + 1
        return pos - 1
      end
      function h.close() end
      return h
    elseif m == "w" or m == "a" then
      local parent, name = parentOf(p)
      if not parent or not parent.dir then return nil, p .. ": No such directory" end
      local buf = {}
      local closed = false
      local prior = ""
      if m == "a" and node then prior = node.data end
      local function commit()
        local s = prior .. table.concat(buf)
        local old = node and #node.data or 0
        if used - old + #s > capacity then return false end
        used = used - old + #s
        node = parent.kids[name] or { data = "" }
        node.data = s
        parent.kids[name] = node
        return true
      end
      -- create the file immediately (like a real fs) so it exists while open
      if not node then
        parent.kids[name] = { data = "" }
        node = parent.kids[name]
      elseif m == "w" then
        used = used - #node.data
        node.data = ""
        prior = ""
      end
      local h = {}
      function h.write(s) buf[#buf + 1] = tostring(s) end
      function h.writeLine(s) buf[#buf + 1] = tostring(s) .. "\n" end
      function h.flush()
        if not commit() then error("Out of space", 0) end
        prior = node.data
        buf = {}
      end
      function h.close()
        if closed then return end
        closed = true
        if not commit() then error("Out of space", 0) end
      end
      return h
    end
    return nil, "Unsupported mode"
  end

  return P
end

return M
