-- SPDX-License-Identifier: AGPL-3.0-or-later
-- filesync: keep a folder identical on several computers over wireless/wired modems (the planned "wireless file sync").
--   filesync serve <folder> [--writable] [--pair]      share a folder (read-only unless --writable)
--   filesync pull <id> <folder> [--delete] [--dry-run]  make <folder> match the server's folder
--   filesync push <id> <folder> [--delete] [--dry-run]  make the server's folder match <folder> (server must be --writable)
-- Files are compared by SHA-256 and transferred in small chunks; only changed files move. Requests are signed with a
-- shared passphrase (see tsrapps.secure), and the server never touches anything outside its folder.
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local cli = require("tsrapps.cli")
local secure = require("tsrapps.secure")

local M = {}

M.PROTOCOL = "tsr.filesync"
M.KEY_FILE = "/etc/tsr/filesync.key"
M.STATE_FILE = "/var/lib/tsr/filesync.json"
M.CHUNK = 8 * 1024
M.MAX_FILES = 400
M.SPEC = { writable = "bool", pair = "bool", delete = "bool", ["dry-run"] = "bool" }

---------------------------------------------------------------------------------------------------------------------
-- Paths and manifests
---------------------------------------------------------------------------------------------------------------------

--- A safe relative path inside the shared folder: no leading slash, no "..", no empty parts, no NULs.
function M.safe(path)
  if type(path) ~= "string" or path == "" or #path > 200 then return false end
  if path:sub(1, 1) == "/" or path:find("\0", 1, true) or path:find("\\", 1, true) then return false end
  for part in path:gmatch("[^/]+") do
    if part == ".." or part == "." then return false end
  end
  return not path:find("//", 1, true) and path:sub(-1) ~= "/"
end

local function sha(path)
  local h = fs.open(path, "rb")
  local data = h.readAll() or ""
  h.close()
  return hash.sha256(data), #data
end

--- Files below `root`: array of { path (relative), size, sha256 } sorted by path. Returns nil + reason if too many.
function M.manifest(root)
  local out = {}
  local function walk(dir, prefix)
    for _, name in ipairs(fs.list(dir)) do
      local full = dir .. "/" .. name
      local rel = prefix .. name
      if fs.isDir(full) then
        walk(full, rel .. "/")
      else
        local digest, size = sha(full)
        out[#out + 1] = { path = rel, size = size, sha256 = digest }
      end
      if #out > M.MAX_FILES then return end
    end
  end
  if fs.isDir(root) then walk(root, "") end
  if #out > M.MAX_FILES then return nil, "more than " .. M.MAX_FILES .. " files; share a smaller folder" end
  table.sort(out, function(a, b) return a.path < b.path end)
  return out
end

--- What has to happen so that `dst` becomes identical to `src`? Returns { copy = {files}, remove = {paths} }.
function M.diff(src, dst)
  local have = {}
  for _, f in ipairs(dst) do have[f.path] = f end
  local plan = { copy = {}, remove = {} }
  local want = {}
  for _, f in ipairs(src) do
    want[f.path] = true
    if not have[f.path] or have[f.path].sha256 ~= f.sha256 then plan.copy[#plan.copy + 1] = f end
  end
  for _, f in ipairs(dst) do if not want[f.path] then plan.remove[#plan.remove + 1] = f.path end end
  return plan
end

---------------------------------------------------------------------------------------------------------------------
-- Server
---------------------------------------------------------------------------------------------------------------------

--- Handle one authenticated request against `cfg` = { root, writable }. Returns ok, data.
function M.dispatch(cfg, msg)
  local cmd, arg = msg.cmd, msg.arg
  if cmd == "list" then
    local m, err = M.manifest(cfg.root)
    if not m then return false, err end
    return true, { files = m, writable = cfg.writable and true or false }
  elseif cmd == "get" then
    if type(arg) ~= "table" or not M.safe(arg.path) then return false, "bad path" end
    local full = cfg.root .. "/" .. arg.path
    if not fs.exists(full) or fs.isDir(full) then return false, "no such file" end
    local h = fs.open(full, "rb")
    local data = h.readAll() or ""
    h.close()
    local offset = tonumber(arg.offset) or 0
    local chunk = data:sub(offset + 1, offset + M.CHUNK)
    return true, { chunk = chunk, eof = offset + #chunk >= #data, size = #data }
  elseif cmd == "put" then
    if not cfg.writable then return false, "this server is read-only" end
    if type(arg) ~= "table" or not M.safe(arg.path) or type(arg.chunk) ~= "string" then return false, "bad request" end
    local tmp = cfg.root .. "/" .. arg.path .. ".tsr-upload"
    local offset = tonumber(arg.offset) or 0
    if offset == 0 then
      vfs.mkdirp(vfs.dirname(tmp))
      local h = fs.open(tmp, "wb")
      h.write(arg.chunk)
      h.close()
    else
      if not fs.exists(tmp) then return false, "upload out of order" end
      local h = fs.open(tmp, "ab")
      h.write(arg.chunk)
      h.close()
    end
    if arg.eof then
      local target = cfg.root .. "/" .. arg.path
      if fs.exists(target) then fs.delete(target) end
      fs.move(tmp, target)
    end
    return true
  elseif cmd == "delete" then
    if not cfg.writable then return false, "this server is read-only" end
    if not M.safe(arg) then return false, "bad path" end
    local full = cfg.root .. "/" .. arg
    if fs.exists(full) and not fs.isDir(full) then fs.delete(full) end
    return true
  end
  return false, "unknown command"
end

--- Serve until `stop` (tests) — one message per iteration.
function M.serve(cfg, secret, net, io, opts)
  opts = opts or {}
  local state = secure.loadState(M.STATE_FILE)
  local handled = 0
  while true do
    local sender, raw = net.receive(opts.timeout or 5)
    if sender then
      local msg = secure.gate(secret, state, sender, raw)
      if msg then
        secure.saveState(M.STATE_FILE, state)
        local ok, data = M.dispatch(cfg, msg)
        net.send(sender, secure.reply(secret, msg, ok, data))
        handled = handled + 1
        if io and msg.cmd ~= "get" and msg.cmd ~= "list" then io.say(("#%d %s %s"):format(sender, msg.cmd, type(msg.arg) == "table" and tostring(msg.arg.path) or tostring(msg.arg or ""))) end
      end
    end
    if opts.rounds and handled >= opts.rounds then return handled end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------------------------------------------------

local function ensureDir(path)
  local dir = vfs.dirname(path)
  if not fs.exists(dir) then vfs.mkdirp(dir) end
end

--- Download one file into `root`. Returns true or false + reason.
local function fetch(secret, net, target, root, f)
  local offset, parts = 0, {}
  while true do
    local reply, err = secure.call(secret, net, target, "get", { path = f.path, offset = offset })
    if not reply then return false, err end
    parts[#parts + 1] = reply.chunk
    offset = offset + #reply.chunk
    if reply.eof or #reply.chunk == 0 then break end
  end
  local data = table.concat(parts)
  if hash.sha256(data) ~= f.sha256 then return false, "checksum mismatch for " .. f.path end
  ensureDir(root .. "/" .. f.path)
  local ok, err = vfs.writeFile(root .. "/" .. f.path, data, true)
  if not ok then return false, tostring(err) end
  return true
end

local function upload(secret, net, target, root, f)
  local h = fs.open(root .. "/" .. f.path, "rb")
  local data = h.readAll() or ""
  h.close()
  local offset = 0
  repeat
    local chunk = data:sub(offset + 1, offset + M.CHUNK)
    local eof = offset + #chunk >= #data
    local ok, err = secure.call(secret, net, target, "put", { path = f.path, offset = offset, chunk = chunk, eof = eof })
    if not ok then return false, err end
    offset = offset + #chunk
  until eof
  return true
end

--- Make `folder` match the server (direction "pull") or the server match `folder` ("push").
--- Returns { copied = n, removed = n, plan = plan } or nil + error.
function M.sync(direction, secret, net, target, folder, opts, io)
  opts = opts or {}
  local reply, err = secure.call(secret, net, target, "list")
  if not reply then return nil, err end
  local mine, merr = M.manifest(folder)
  if not mine then return nil, merr end
  local plan
  if direction == "pull" then plan = M.diff(reply.files, mine) else plan = M.diff(mine, reply.files) end
  if not opts.delete then plan.remove = {} end
  if direction == "push" and not reply.writable then return nil, "the server is read-only (start it with --writable)" end
  if opts.dryRun then return { copied = 0, removed = 0, plan = plan } end
  local copied, removed = 0, 0
  for i, f in ipairs(plan.copy) do
    if io then io.say(("%s %s (%d/%d)"):format(direction == "pull" and "<-" or "->", f.path, i, #plan.copy)) end
    local ok, e
    if direction == "pull" then ok, e = fetch(secret, net, target, folder, f) else ok, e = upload(secret, net, target, folder, f) end
    if not ok then return nil, e end
    copied = copied + 1
  end
  for _, path in ipairs(plan.remove) do
    if direction == "pull" then
      if M.safe(path) and fs.exists(folder .. "/" .. path) then fs.delete(folder .. "/" .. path) removed = removed + 1 end
    else
      local ok, e = secure.call(secret, net, target, "delete", path)
      if not ok then return nil, e end
      removed = removed + 1
    end
  end
  return { copied = copied, removed = removed, plan = plan }
end

function M.main(args, io, env)
  io = io or cli.io()
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  local cmd = pos[1]
  if cmd ~= "serve" and cmd ~= "pull" and cmd ~= "push" then
    io.say("usage: filesync serve <folder> [--writable] | pull <id> <folder> [--delete] [--dry-run] | push <id> <folder> ...")
    return false
  end
  local secret, err = secure.secret(io, M.KEY_FILE, opts.pair)
  if not secret then io.err(err) return false end
  local net = env and env.net
  if not net then
    local why
    net, why = secure.rednetNet(M.PROTOCOL)
    if not net then io.err(why) return false end
  end
  if cmd == "serve" then
    local folder = pos[2]
    if not (folder and fs.isDir(folder)) then io.err("usage: filesync serve <existing folder>") return false end
    io.say(("Sharing %s as computer %d (%s). Ctrl+T to stop."):format(folder, os.getComputerID(), opts.writable and "read/write" or "read-only"))
    M.serve({ root = folder:gsub("/$", ""), writable = opts.writable }, secret, net, io, env and env.serveOpts)
    return true
  end
  local target, folder = tonumber(pos[2]), pos[3]
  if not (target and folder) then io.err("usage: filesync " .. cmd .. " <computer id> <folder>") return false end
  if not fs.exists(folder) then vfs.mkdirp(folder) end
  local res, e = M.sync(cmd, secret, net, target, folder:gsub("/$", ""), { delete = opts.delete, dryRun = opts["dry-run"] }, io)
  if not res then io.err(e) return false end
  if opts["dry-run"] then
    io.say(("Would copy %d file(s)%s."):format(#res.plan.copy, opts.delete and (" and remove " .. #res.plan.remove) or ""))
  else
    io.say(("Done: %d copied, %d removed."):format(res.copied, res.removed))
  end
  return true
end

return M
