-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Users, passwords, roles and soft file permissions.
--
-- HONEST LIMITS: a ComputerCraft computer is one Lua VM that anyone with a keyboard controls; any program can restore the
-- original `fs` functions or read the disk through a disk drive. These checks keep honest users from making mistakes and
-- keep other players from casually wandering around a shared computer. They are not a security boundary against someone
-- who can run arbitrary code or break the computer.
--
-- Processes that were not started from a login session (daemons, boot scripts) are the "system": nothing is checked for them.
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local kernel = require("tsr.kernel")

local M = {}

M.dbPath = "/etc/tsr/users.db"
M.iterations = 200
M.MIN_PASSWORD = 4
M.ROOT = "root"      -- pseudo-user used by sudo / elevated sections: unrestricted

--- Files and folders that hold secrets: ordinary users can neither read nor write them.
M.SECRET_PATHS = { "/etc/tsr/net", "/etc/tsr/ssh", "/etc/tsr/sshd.cfg", "/var/lib/tsr/random.seed", "/etc/tsr/webgw.cfg", "/etc/tsr/rsh.allow", "/etc/tsr/fleet.allow", "/etc/tsr/rscreen.allow",
                   "/etc/tsr/kiosk.cfg", "/var/lib/tsr/pkg/txn.json" }

local db = nil
local sessions = {}      -- pid -> user name
local elevated = 0       -- >0 while this module does its own I/O (bypasses the guard)

---------------------------------------------------------------------------------------------------------------------
-- Database
---------------------------------------------------------------------------------------------------------------------

local function raw(fn, ...)
  elevated = elevated + 1
  local res = table.pack(pcall(fn, ...))
  elevated = elevated - 1
  if not res[1] then error(res[2], 0) end
  return table.unpack(res, 2, res.n)
end

function M.load()
  db = raw(vfs.readTable, M.dbPath) or { users = {} }
  db.users = db.users or {}
  return db
end

local function data()
  return db or M.load()
end

local function save()
  local ok, err = raw(vfs.writeTable, M.dbPath, db)
  if not ok then return nil, err end
  return true
end

--- Forget in-memory state (tests, and after the database file changed on disk).
function M.reset()
  db, sessions, elevated = nil, {}, 0
end

local function randomHex(n)
  local out = {}
  local seed = (os.epoch and os.epoch("utc") or 0) + os.getComputerID() * 7919 + os.clock() * 1e6
  math.randomseed(seed % 2147483647)
  for i = 1, n do out[i] = string.format("%02x", math.random(0, 255)) end
  return table.concat(out)
end

local function digest(password, salt)
  local h = hash.sha256(salt .. password)
  for _ = 1, M.iterations do h = hash.sha256(h .. salt .. password) end
  return h
end

local function sameString(a, b)
  if #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do if a:byte(i) ~= b:byte(i) then diff = diff + 1 end end
  return diff == 0
end

local function validName(name)
  return type(name) == "string" and #name <= 16 and name:match("^[a-z][a-z0-9_%-]*$") ~= nil and name ~= M.ROOT
end

function M.hasUsers()
  return next(data().users) ~= nil
end

function M.exists(name) return data().users[name] ~= nil end

--- Public view of a user (never includes the password hash).
function M.get(name)
  local u = data().users[name]
  if not u then return nil end
  return { name = name, role = u.role, home = u.home, created = u.created, locked = u.locked or false }
end

function M.list()
  local out = {}
  for name in pairs(data().users) do out[#out + 1] = M.get(name) end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- Create a user. opts: role ("admin" | "user" | "guest", default "user"), home (default /home/<name>).
function M.addUser(name, password, opts)
  opts = opts or {}
  if not validName(name) then return nil, "user names are 1-16 characters: lowercase letters, digits, - and _, starting with a letter" end
  if data().users[name] then return nil, "user " .. name .. " already exists" end
  if type(password) ~= "string" or #password < M.MIN_PASSWORD then
    return nil, "password must be at least " .. M.MIN_PASSWORD .. " characters"
  end
  local role = opts.role or "user"
  if not M.ROLES[role] then return nil, "unknown role " .. tostring(role) end
  local salt = randomHex(8)
  data().users[name] = {
    salt = salt, hash = digest(password, salt), role = role, home = opts.home or ("/home/" .. name),
    created = os.epoch and os.epoch("utc") or 0,
  }
  local ok, err = save()
  if not ok then data().users[name] = nil return nil, err end
  raw(function()
    local home = data().users[name].home
    if not fs.exists(home) then fs.makeDir(home) end
  end)
  return true
end

function M.removeUser(name)
  local u = data().users[name]
  if not u then return nil, "no such user: " .. tostring(name) end
  if u.role == "admin" then
    local admins = 0
    for _, other in pairs(data().users) do if other.role == "admin" then admins = admins + 1 end end
    if admins <= 1 then return nil, "cannot remove the last administrator" end
  end
  data().users[name] = nil
  return save()
end

function M.setPassword(name, password)
  local u = data().users[name]
  if not u then return nil, "no such user: " .. tostring(name) end
  if type(password) ~= "string" or #password < M.MIN_PASSWORD then
    return nil, "password must be at least " .. M.MIN_PASSWORD .. " characters"
  end
  u.salt = randomHex(8)
  u.hash = digest(password, u.salt)
  u.failures = nil
  return save()
end

function M.setRole(name, role)
  local u = data().users[name]
  if not u then return nil, "no such user: " .. tostring(name) end
  if not M.ROLES[role] then return nil, "unknown role " .. tostring(role) end
  if u.role == "admin" and role ~= "admin" then
    local admins = 0
    for _, other in pairs(data().users) do if other.role == "admin" then admins = admins + 1 end end
    if admins <= 1 then return nil, "cannot demote the last administrator" end
  end
  u.role = role
  return save()
end

function M.setLocked(name, locked)
  local u = data().users[name]
  if not u then return nil, "no such user: " .. tostring(name) end
  u.locked = locked and true or nil
  return save()
end

--- Check a password. Returns the user (public view), or nil + reason. Counts failures so callers can slow down.
function M.verify(name, password)
  local u = data().users[name]
  if not u then
    digest(tostring(password), "0000000000000000")   -- same cost as a real check: do not reveal which names exist
    return nil, "bad"
  end
  if u.locked then return nil, "locked" end
  if sameString(digest(tostring(password), u.salt), u.hash) then
    if u.failures then u.failures = nil save() end
    return M.get(name)
  end
  u.failures = (u.failures or 0) + 1
  save()
  return nil, "bad", u.failures
end

---------------------------------------------------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------------------------------------------------

--- Make `name` the user of process `pid` (default: the running one) and everything it starts.
function M.setSessionUser(name, pid)
  pid = pid or kernel.current() or 0
  sessions[pid] = name
end

--- The user a process runs as: its own session, else its nearest ancestor's, else nil (system).
function M.userOf(pid)
  pid = pid or kernel.current() or 0
  local hops = 0
  while pid and hops < 32 do
    if sessions[pid] ~= nil then return sessions[pid] end
    local p = kernel.get(pid)
    pid = p and p.parent
    hops = hops + 1
  end
  return nil
end

function M.current() return M.userOf() end

function M.endSession(pid) sessions[pid or kernel.current() or 0] = nil end

--- Run fn as another user (nil = system) and restore afterwards.
function M.asUser(name, fn, ...)
  local pid = kernel.current() or 0
  local saved = sessions[pid]
  sessions[pid] = name or M.ROOT
  local res = table.pack(pcall(fn, ...))
  sessions[pid] = saved
  if not res[1] then error(res[2], 0) end
  return table.unpack(res, 2, res.n)
end

---------------------------------------------------------------------------------------------------------------------
-- Permissions
---------------------------------------------------------------------------------------------------------------------

--- Actions a role may do. "*" allows everything. Lookup also accepts a trailing wildcard ("pkg.*").
M.ROLES = {
  admin = { ["*"] = true },
  user = { ["app.run"] = true, ["net.use"] = true, ["svc.view"] = true, ["fs.home"] = true },
  guest = { ["app.run"] = true },
}

function M.can(name, action)
  if name == nil or name == M.ROOT then return true end
  local u = data().users[name]
  if not u then return false end
  local role = M.ROLES[u.role] or {}
  if role["*"] or role[action] then return true end
  local prefix = action:match("^(.-)%.[^%.]*$")
  while prefix do
    if role[prefix .. ".*"] then return true end
    prefix = prefix:match("^(.-)%.[^%.]*$")
  end
  return false
end

local function norm(path) return "/" .. fs.combine(path, "") end

local function under(path, dir) return path == dir or path:sub(1, #dir + 1) == dir .. "/" end

--- May `name` read ("r") or write ("w") `path`? Rules for non-administrators:
---  * the user database is off limits, other users' home directories are private,
---  * writes go to the user's own home and /tmp only (guests: /tmp only).
function M.pathAllowed(name, path, mode)
  if elevated > 0 or name == nil or name == M.ROOT then return true end
  path = norm(path)
  local u = data().users[name]
  if not u then return false end
  if u.role == "admin" then return true end
  if path == M.dbPath or under(path, M.dbPath .. ".tsr-tmp") then return false end
  for _, secret in ipairs(M.SECRET_PATHS) do
    if under(path, secret) then return false end      -- pairing keys, gateway tokens... administrators only
  end
  if under(path, "/home") and path ~= "/home" then
    if not under(path, u.home) then return false end
    return mode == "r" or u.role ~= "guest"
  end
  if mode == "r" then return true end
  if under(path, "/tmp") then return true end
  if u.role ~= "guest" and under(path, u.home) then return true end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- File system guard
---------------------------------------------------------------------------------------------------------------------

M.guard = { installed = false, saved = {} }

local function denied(path)
  error("Access denied: " .. tostring(path), 3)
end

--- Wrap fs so that processes with a session user obey pathAllowed. Safe to call twice.
function M.guard.install()
  if M.guard.installed then return end
  local saved = {}
  for _, name in ipairs({ "open", "delete", "move", "copy", "makeDir" }) do saved[name] = fs[name] end
  M.guard.saved = saved

  local function allow(path, mode)
    local user = M.userOf()
    if user == nil then return true end
    return M.pathAllowed(user, path, mode)
  end

  function fs.open(path, mode)
    local m = (mode or "r"):sub(1, 1) == "r" and "r" or "w"
    if not allow(path, m) then denied(path) end
    return saved.open(path, mode)
  end
  function fs.delete(path)
    if not allow(path, "w") then denied(path) end
    return saved.delete(path)
  end
  function fs.makeDir(path)
    if not allow(path, "w") then denied(path) end
    return saved.makeDir(path)
  end
  function fs.move(from, to)
    if not allow(from, "w") then denied(from) end
    if not allow(to, "w") then denied(to) end
    return saved.move(from, to)
  end
  function fs.copy(from, to)
    if not allow(from, "r") then denied(from) end
    if not allow(to, "w") then denied(to) end
    return saved.copy(from, to)
  end
  M.guard.installed = true
end

function M.guard.uninstall()
  if not M.guard.installed then return end
  for name, fn in pairs(M.guard.saved) do fs[name] = fn end
  M.guard.installed = false
end

return M
