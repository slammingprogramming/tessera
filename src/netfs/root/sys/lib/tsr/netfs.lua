-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Network file sharing.
--   Server: export folders to paired computers      netfs.serve(node, exports)   (the netfsd service does this from /etc/tsr/netfs.exports)
--   Client: mount a remote export as a directory    netfs.mount(node, "peer", "export", "/mnt/peer")
--
-- exports = { name = { path = "/srv/data", readonly = true, peers = { "alpha" } } }   (peers: nil = every paired computer)
-- Files travel in 8 KB chunks. A file opened for reading is fetched completely first; one opened for writing is sent
-- when it is closed. Paths cannot escape the exported folder.
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")

local M = {}

M.CHUNK = 8192
M.EXPORTS_PATH = "/etc/tsr/netfs.exports"

---------------------------------------------------------------------------------------------------------------------
-- Server
---------------------------------------------------------------------------------------------------------------------

--- Map a client path to a real path inside the export, or nil + error when it would leave the export.
local function jail(export, path)
  if type(path) ~= "string" then return nil, "bad path" end
  -- resolve "." and ".." ourselves: ".." at the top stays at the top, so no path can climb out of the export
  local parts = {}
  for part in path:gsub("\\", "/"):gmatch("[^/]+") do
    if part == ".." then parts[#parts] = nil
    elseif part ~= "." then parts[#parts + 1] = part end
  end
  local root = vfs.normalize(export.path)
  local rel = table.concat(parts, "/")
  if rel == "" then return root end
  if root == "/" then return "/" .. rel end
  return root .. "/" .. rel
end

local function check(export, peerName)
  if not export.peers then return true end
  for _, p in ipairs(export.peers) do if p == peerName then return true end end
  return false
end

function M.loadExports()
  return vfs.readTable(M.EXPORTS_PATH) or {}
end

--- Register the "fs" service on `node`. `exports` may be a table or a function returning one (re-read on each call).
function M.serve(node, exports)
  node:serve("fs", function(from, method, a)
    local list = type(exports) == "function" and exports() or exports
    local peer = node:peer(from)
    local export = type(a) == "table" and list[a.export]
    if not export then error("no such export", 0) end
    if not check(export, peer and peer.name) then error("not allowed", 0) end
    local path, why = jail(export, a.path)
    if not path then error(why, 0) end
    local writable = not export.readonly

    if method == "stat" then
      return { exists = fs.exists(path), isDir = fs.isDir(path), size = (fs.exists(path) and not fs.isDir(path)) and fs.getSize(path) or 0,
               readonly = not writable }
    elseif method == "list" then
      if not fs.isDir(path) then error("Not a directory", 0) end
      return fs.list(path)
    elseif method == "read" then
      if not fs.exists(path) or fs.isDir(path) then error("No such file", 0) end
      local h = fs.open(path, "rb")
      h.seek("set", a.offset or 0)
      local data = h.read(math.min(a.length or M.CHUNK, M.CHUNK)) or ""
      h.close()
      return { data = hash.base64Encode(data), eof = (a.offset or 0) + #data >= fs.getSize(path) }
    end

    if not writable then error("read-only export", 0) end
    if method == "write" then
      if fs.isDir(path) then error("Is a directory", 0) end
      local data = hash.base64Decode(a.data or "")
      if not data then error("bad data", 0) end
      if a.truncate then
        local h = fs.open(path, "wb")
        if not h then error("cannot write", 0) end
        h.write(data)
        h.close()
      else
        local h = fs.open(path, "ab")
        if not h then error("cannot write", 0) end
        h.write(data)
        h.close()
      end
      return true
    elseif method == "makeDir" then fs.makeDir(path) return true
    elseif method == "delete" then
      if path == vfs.normalize(export.path) then error("cannot delete the export root", 0) end
      fs.delete(path)
      return true
    elseif method == "move" then
      local to, why2 = jail(export, a.to)
      if not to then error(why2, 0) end
      fs.move(path, to)
      return true
    end
    error("unknown method " .. tostring(method), 0)
  end)
end

---------------------------------------------------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------------------------------------------------

--- A vfs provider that forwards to `peer`'s export. opts: timeout (seconds per call), encrypt.
function M.provider(node, peer, exportName, opts)
  opts = opts or {}
  local P = {}
  local callOpts = { timeout = opts.timeout or 5, encrypt = opts.encrypt }

  local function call(method, path, extra)
    local args = { export = exportName, path = path }
    if extra then for k, v in pairs(extra) do args[k] = v end end
    local res, err = node:call(peer, "fs", method, args, callOpts)
    if res == nil then error(tostring(err), 0) end
    return res
  end

  local readonly
  local function stat(p) return call("stat", p) end
  function P.exists(p) return stat(p).exists end
  function P.isDir(p) return stat(p).isDir end
  function P.list(p) return call("list", p) end
  function P.size(p)
    local s = stat(p)
    if not s.exists then error(p .. ": No such file", 0) end
    return s.size
  end
  function P.makeDir(p) call("makeDir", p) end
  function P.delete(p) call("delete", p) end
  function P.move(a, b) call("move", a, { to = b }) end
  function P.isReadOnly(p) return stat(p or "/").readonly end
  function P.getFreeSpace() return 0 end
  function P.getCapacity() return 0 end

  local function download(p)
    local s = stat(p)
    if not s.exists then return nil, p .. ": No such file" end
    if s.isDir then return nil, p .. ": Cannot read a directory" end
    local parts, offset = {}, 0
    while true do
      local r = call("read", p, { offset = offset, length = M.CHUNK })
      local chunk = hash.base64Decode(r.data) or ""
      parts[#parts + 1] = chunk
      offset = offset + #chunk
      if r.eof or #chunk == 0 then break end
    end
    return table.concat(parts)
  end

  local function upload(p, data, append)
    if #data == 0 then
      call("write", p, { data = "", truncate = not append })
      return
    end
    local first = true
    for from = 1, #data, M.CHUNK do
      call("write", p, { data = hash.base64Encode(data:sub(from, from + M.CHUNK - 1)), truncate = first and not append })
      first = false
    end
  end

  -- A scratch RAM disk turns whole files into ordinary handles (readLine, seek, binary reads...).
  function P.open(p, mode)
    local m = mode:sub(1, 1)
    local scratch = vfs.ramfs(64 * 1024 * 1024)
    if m == "r" then
      local data, err = download(p)
      if not data then return nil, err end
      local w = scratch.open("/f", "wb")
      w.write(data)
      w.close()
      return scratch.open("/f", mode)
    end
    local handle = scratch.open("/f", mode:sub(2, 2) == "b" and "wb" or "w")
    local closed = false
    local wrapper = {}
    function wrapper.write(s) handle.write(s) end
    function wrapper.writeLine(s) handle.writeLine(s) end
    function wrapper.flush() end
    function wrapper.close()
      if closed then return end
      closed = true
      handle.close()
      local r = scratch.open("/f", "rb")
      local data = r.readAll() or ""
      r.close()
      upload(p, data, m == "a")
    end
    return wrapper
  end

  return P
end

--- Mount peer's export at `mountpoint` of the local file system.
function M.mount(node, peer, exportName, mountpoint, opts)
  local p = M.provider(node, peer, exportName, opts)
  local ok, err = pcall(function() return p.isDir("/") end)
  if not ok then return nil, tostring(err) end
  vfs.mount(mountpoint, p)
  return true
end

function M.unmount(mountpoint) return vfs.unmount(mountpoint) end

---------------------------------------------------------------------------------------------------------------------
-- Command line and service
---------------------------------------------------------------------------------------------------------------------

M.MOUNTS_PATH = "/etc/tsr/netfs.mounts"

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  return io
end

--- netfs export <name> <path> [--rw] [--peers a,b] | unexport <name> | exports | mount <peer> <export> <dir> | umount <dir> | mounts
function M.run(args, io, node)
  io = io or defaultIO()
  node = node or require("tsr.net").default()
  local cmd = args[1]

  if cmd == "export" then
    local name, path = args[2], args[3]
    if not name or not path or not fs.isDir(path) then io.err("usage: netfs export <name> <existing folder> [--rw] [--peers a,b]") return false end
    local export = { path = vfs.normalize(path), readonly = true }
    local i = 4
    while args[i] do
      if args[i] == "--rw" then export.readonly = false
      elseif args[i] == "--peers" then
        export.peers = {}
        for p in (args[i + 1] or ""):gmatch("[^,]+") do export.peers[#export.peers + 1] = p end
        i = i + 1
      end
      i = i + 1
    end
    local all = M.loadExports()
    all[name] = export
    vfs.writeTable(M.EXPORTS_PATH, all)
    io.say("Exporting " .. export.path .. " as '" .. name .. "'" .. (export.readonly and " (read-only)" or " (read-write)") .. ".")
    return true

  elseif cmd == "unexport" then
    local all = M.loadExports()
    if not args[2] or not all[args[2]] then io.err("no such export") return false end
    all[args[2]] = nil
    vfs.writeTable(M.EXPORTS_PATH, all)
    io.say("Removed.")
    return true

  elseif cmd == "exports" then
    local names = {}
    for n in pairs(M.loadExports()) do names[#names + 1] = n end
    table.sort(names)
    if #names == 0 then io.say("Nothing is exported.") end
    local all = M.loadExports()
    for _, n in ipairs(names) do
      local e = all[n]
      io.say(("%-12s %s %s%s"):format(n, e.path, e.readonly and "ro" or "rw", e.peers and (" for " .. table.concat(e.peers, ",")) or ""))
    end
    return true

  elseif cmd == "mount" then
    local peer, export, dir = args[2], args[3], args[4]
    if not (peer and export and dir) then io.err("usage: netfs mount <peer> <export> <directory>") return false end
    local ok, err = M.mount(node, tonumber(peer) or peer, export, dir)
    if not ok then io.err("cannot mount: " .. tostring(err)) return false end
    local list = vfs.readTable(M.MOUNTS_PATH) or {}
    local kept = {}
    for _, m in ipairs(list) do if m.dir ~= vfs.normalize(dir) then kept[#kept + 1] = m end end
    kept[#kept + 1] = { peer = tonumber(peer) or peer, export = export, dir = vfs.normalize(dir) }
    vfs.writeTable(M.MOUNTS_PATH, kept)
    io.say("Mounted " .. peer .. ":" .. export .. " at " .. dir .. " (it is remounted at boot).")
    return true

  elseif cmd == "umount" then
    if not args[2] then io.err("usage: netfs umount <directory>") return false end
    local dir = vfs.normalize(args[2])
    M.unmount(dir)
    local kept = {}
    for _, m in ipairs(vfs.readTable(M.MOUNTS_PATH) or {}) do if m.dir ~= dir then kept[#kept + 1] = m end end
    vfs.writeTable(M.MOUNTS_PATH, kept)
    io.say("Unmounted " .. dir .. ".")
    return true

  elseif cmd == "mounts" then
    local list = vfs.readTable(M.MOUNTS_PATH) or {}
    if #list == 0 then io.say("No saved mounts.") end
    for _, m in ipairs(list) do io.say(m.dir .. "  <-  " .. tostring(m.peer) .. ":" .. m.export) end
    return true
  end
  io.err("usage: netfs export|unexport|exports|mount|umount|mounts")
  return false
end

function M.main(args) return M.run(args) end

--- The netfsd service: offer the configured exports and (re)mount saved mounts, retrying while peers are unreachable.
function M.daemon()
  local node = require("tsr.net").default()
  M.serve(node, M.loadExports)
  while true do
    for _, m in ipairs(vfs.readTable(M.MOUNTS_PATH) or {}) do
      local already = false
      for _, mp in ipairs(vfs.mounts()) do if mp == m.dir then already = true end end
      if not already then pcall(M.mount, node, m.peer, m.export, m.dir) end
    end
    sleep(30)
  end
end

return M
