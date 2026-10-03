-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Mailboxes on disk: one folder per mailbox under the store root (/var/mail), subfolders INBOX, Sent, Drafts, Trash, Spam and your own, one file per message
-- (<uid>.eml), plus an index per folder with the flags and the numbers that listings need. Messages never change once stored; deleting is a flag until expunge.
-- Also here: the accounts (name, password hash, quota) in /etc/tsr/mail/users.lua.
local msg = require("tsr.mail.message")
local vfs = require("tsr.vfs")
local crypto = require("tsr.crypto")

local M = {}
local Store = {}
Store.__index = Store

M.ROOT = "/var/mail"
M.USERS = "/etc/tsr/mail/users.db"
M.DEFAULT_QUOTA = 262144
M.FOLDERS = { "INBOX", "Sent", "Drafts", "Trash", "Spam" }
M.FLAGS = { S = "Seen", R = "Answered", F = "Flagged", D = "Deleted" }

--- root: where mailboxes live (default M.ROOT), users: path of the accounts file (default M.USERS), iterations: password hashing work.
function M.new(opts)
  opts = opts or {}
  return setmetatable({ root = opts.root or M.ROOT, usersPath = opts.users or M.USERS, iterations = opts.iterations or 256, cache = {}, stamps = {} }, Store)
end

---------------------------------------------------------------------------------------------------------------------
-- Accounts
---------------------------------------------------------------------------------------------------------------------

local function hashPassword(password, salt, iterations)
  return salt .. "$" .. iterations .. "$" .. crypto.toHex(crypto.kdf.pbkdf2(password, salt, iterations, 32))
end

function Store:users() return vfs.readTable(self.usersPath) or {} end

function Store:saveUsers(t) return vfs.writeTable(self.usersPath, t) end

local function validName(name) return type(name) == "string" and name:match("^[%w][%w._%-]*$") and #name <= 32 end

function Store:addUser(name, password, opts)
  opts = opts or {}
  name = tostring(name):lower()
  if not validName(name) then return nil, "a mailbox name has letters, digits, dots, dashes and underscores" end
  if #password < 6 then return nil, "the password needs at least 6 characters" end
  local users = self:users()
  if users[name] then return nil, "that mailbox exists already" end
  local salt = crypto.toHex(crypto.rand.bytes(8))
  users[name] = { hash = hashPassword(password, salt, self.iterations), quota = opts.quota or M.DEFAULT_QUOTA, admin = opts.admin or nil }
  self:saveUsers(users)
  self:ensure(name)
  return true
end

function Store:setPassword(name, password)
  local users = self:users()
  name = name:lower()
  if not users[name] then return nil, "no such mailbox" end
  if #password < 6 then return nil, "the password needs at least 6 characters" end
  local salt = crypto.toHex(crypto.rand.bytes(8))
  users[name].hash = hashPassword(password, salt, self.iterations)
  self:saveUsers(users)
  return true
end

function Store:removeUser(name, keepMail)
  local users = self:users()
  name = name:lower()
  if not users[name] then return nil, "no such mailbox" end
  users[name] = nil
  self:saveUsers(users)
  if not keepMail and vfs.fs.exists(self.root .. "/" .. name) then vfs.fs.delete(self.root .. "/" .. name) end
  return true
end

function Store:exists(name) return self:users()[tostring(name):lower()] ~= nil end

function Store:setQuota(name, bytes)
  local users = self:users()
  name = name:lower()
  if not users[name] then return nil, "no such mailbox" end
  users[name].quota = bytes
  self:saveUsers(users)
  return true
end

--- Check a password. Returns the account name or nil.
function Store:authenticate(name, password)
  name = tostring(name or ""):lower()
  local u = self:users()[name]
  if not u then
    -- keep the time constant-ish: hash anyway
    hashPassword(tostring(password), "0000000000000000", self.iterations)
    return nil
  end
  local salt, iter = u.hash:match("^(%x+)%$(%d+)%$")
  if not salt then return nil end
  local h = hashPassword(tostring(password), salt, tonumber(iter))
  if crypto.equal(h, u.hash) then return name end
  return nil
end

---------------------------------------------------------------------------------------------------------------------
-- Folders and messages
---------------------------------------------------------------------------------------------------------------------

function Store:dir(mailbox, folder) return self.root .. "/" .. mailbox .. "/" .. folder end

function Store:ensure(mailbox)
  for _, f in ipairs(M.FOLDERS) do
    local d = self:dir(mailbox, f)
    if not vfs.fs.exists(d) then vfs.mkdirp(d) end
  end
end

function Store:folders(mailbox)
  local out = {}
  local base = self.root .. "/" .. mailbox
  if vfs.fs.exists(base) then
    for _, n in ipairs(vfs.fs.list(base)) do if vfs.fs.isDir(base .. "/" .. n) then out[#out + 1] = n end end
  end
  table.sort(out, function(a, b)
    if a == "INBOX" then return b ~= "INBOX" end
    if b == "INBOX" then return false end
    return a < b
  end)
  return out
end

function Store:createFolder(mailbox, folder)
  if not folder:match("^[%w][%w ._%-]*$") then return nil, "bad folder name" end
  local d = self:dir(mailbox, folder)
  if vfs.fs.exists(d) then return nil, "that folder exists already" end
  vfs.mkdirp(d)
  return true
end

function Store:deleteFolder(mailbox, folder)
  for _, f in ipairs(M.FOLDERS) do if f == folder then return nil, "the standard folders cannot be removed" end end
  local d = self:dir(mailbox, folder)
  if not vfs.fs.exists(d) then return nil, "no such folder" end
  vfs.fs.delete(d)
  self.cache[d] = nil
  return true
end

local function indexPath(dir) return dir .. "/.index" end

--- A fingerprint of the index file: when another process (the mail server, a mail program) changed it, the cached copy is stale and must be read again.
local function stampOf(dir)
  local okA, a = pcall(vfs.fs.attributes, indexPath(dir))
  if okA and type(a) == "table" then return tostring(a.modified) .. ":" .. tostring(a.size) end
  return "none"
end

local function loadIndex(self, dir)
  local c = self.cache[dir]
  if c and self.stamps[dir] == stampOf(dir) then return c end
  local idx = vfs.readTable(indexPath(dir))
  if not idx then
    idx = { next = 1, messages = {} }
    -- rebuild from the files (an index lost or never written)
    if vfs.fs.exists(dir) then
      for _, n in ipairs(vfs.fs.list(dir)) do
        local uid = tonumber(n:match("^(%d+)%.eml$"))
        if uid then
          local raw = vfs.readFile(dir .. "/" .. n, true) or ""
          local m = msg.parse(raw)
          idx.messages[#idx.messages + 1] = { uid = uid, flags = "", size = #raw, from = (m:header("from") or ""):sub(1, 80), subject = m:subject():sub(1, 100), date = m:header("date") or "" }
          if uid >= idx.next then idx.next = uid + 1 end
        end
      end
      table.sort(idx.messages, function(a, b) return a.uid < b.uid end)
    end
  end
  self.cache[dir] = idx
  self.stamps[dir] = stampOf(dir)
  return idx
end

local function saveIndex(self, dir)
  vfs.writeTable(indexPath(dir), self.cache[dir])
  self.stamps[dir] = stampOf(dir)
end

--- Bytes used by all messages of the mailbox.
function Store:usage(mailbox)
  local total = 0
  for _, f in ipairs(self:folders(mailbox)) do
    for _, m in ipairs(loadIndex(self, self:dir(mailbox, f)).messages) do total = total + m.size end
  end
  return total
end

--- Store a message. Returns its uid, or nil + reason ("quota" when the mailbox is full).
function Store:deliver(mailbox, raw, folder, flags)
  folder = folder or "INBOX"
  mailbox = mailbox:lower()
  local u = self:users()[mailbox]
  if not u then return nil, "no such mailbox" end
  self:ensure(mailbox)
  local dir = self:dir(mailbox, folder)
  if not vfs.fs.exists(dir) then vfs.mkdirp(dir) end
  if u.quota and self:usage(mailbox) + #raw > u.quota then return nil, "quota" end
  local idx = loadIndex(self, dir)
  local uid = idx.next
  idx.next = uid + 1
  local ok, err = vfs.writeFile(dir .. "/" .. uid .. ".eml", raw, true)
  if not ok then return nil, tostring(err) end
  local m = msg.parse(raw)
  idx.messages[#idx.messages + 1] = { uid = uid, flags = flags or "", size = #raw, from = (m:header("from") or ""):sub(1, 80), subject = m:subject():sub(1, 100), date = m:header("date") or "" }
  saveIndex(self, dir)
  return uid
end

--- The listing of a folder: { uid, flags, size, from, subject, date }.
function Store:list(mailbox, folder)
  local idx = loadIndex(self, self:dir(mailbox:lower(), folder or "INBOX"))
  local out = {}
  for i, m in ipairs(idx.messages) do out[i] = m end
  return out
end

function Store:get(mailbox, folder, uid)
  local dir = self:dir(mailbox:lower(), folder or "INBOX")
  return vfs.readFile(dir .. "/" .. uid .. ".eml", true)
end

local function find(idx, uid)
  for i, m in ipairs(idx.messages) do if m.uid == uid then return m, i end end
end

function Store:setFlags(mailbox, folder, uid, add, remove)
  local dir = self:dir(mailbox:lower(), folder or "INBOX")
  local idx = loadIndex(self, dir)
  local m = find(idx, uid)
  if not m then return nil, "no such message" end
  local set = {}
  for c in m.flags:gmatch(".") do set[c] = true end
  for c in (add or ""):gmatch(".") do set[c] = true end
  for c in (remove or ""):gmatch(".") do set[c] = nil end
  local out = {}
  for _, c in ipairs({ "S", "R", "F", "D" }) do if set[c] then out[#out + 1] = c end end
  m.flags = table.concat(out)
  saveIndex(self, dir)
  return true
end

--- Remove messages flagged deleted. Returns how many went.
function Store:expunge(mailbox, folder)
  local dir = self:dir(mailbox:lower(), folder or "INBOX")
  local idx = loadIndex(self, dir)
  local kept, n = {}, 0
  for _, m in ipairs(idx.messages) do
    if m.flags:find("D", 1, true) then vfs.fs.delete(dir .. "/" .. m.uid .. ".eml") n = n + 1 else kept[#kept + 1] = m end
  end
  idx.messages = kept
  saveIndex(self, dir)
  return n
end

function Store:delete(mailbox, folder, uid)
  local ok, err = self:setFlags(mailbox, folder, uid, "D")
  if not ok then return nil, err end
  return self:expunge(mailbox, folder) > 0
end

--- Move a message to another folder (new uid there). Returns the new uid.
function Store:move(mailbox, folder, uid, target)
  local raw = self:get(mailbox, folder, uid)
  if not raw then return nil, "no such message" end
  local idx = loadIndex(self, self:dir(mailbox:lower(), folder))
  local m = find(idx, uid)
  local newUid, err = self:deliver(mailbox, raw, target, m and m.flags:gsub("D", "") or "")
  if not newUid then return nil, err end
  self:delete(mailbox, folder, uid)
  return newUid
end

--- Forget cached indexes (after another process changed the files).
function Store:reload() self.cache, self.stamps = {}, {} end

return M
