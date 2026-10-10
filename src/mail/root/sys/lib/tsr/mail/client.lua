-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A mail program's engine: one account on a mail server, a local copy of the mail (folders in the user's home), fetching by POP3 and sending by SMTP
-- (submission port 587 with the account's login). It talks to servers only over the network, so it works for ordinary users and for mail servers anywhere.
--   local c = client.open({ home = "/home/alice/.mail", stack = stack, account = { address = "alice@example.lan", server = "10.0.0.1", user = "alice", pass = "..." } })
--   local n = c:fetch()           local list = c:list("INBOX")           c:send({ to = "bob@other.lan", subject = "Hi", body = "..." })
local msg = require("tsr.mail.message")
local storeMod = require("tsr.mail.store")
local pop3 = require("tsr.mail.pop3")
local smtp = require("tsr.mail.smtp")
local vfs = require("tsr.vfs")

local M = {}
local Client = {}
Client.__index = Client

local MAILBOX = "me"

M.ACCOUNT_FIELDS = { "address", "name", "server", "user", "pass", "smtp", "pop3port", "smtpport", "tls", "tlsname", "leave" }

--- The account file of a home folder, as a table (empty when there is none).
function M.loadAccount(home)
  local text = vfs.readFile(home .. "/account.lua")
  if not text then return {} end
  local chunk = load(text, "=account.lua", "t", {})
  if not chunk then return {} end
  local ok, value = pcall(chunk)
  return ok and type(value) == "table" and value or {}
end

function M.saveAccount(home, account)
  vfs.mkdirp(home)
  local keys = {}
  for k in pairs(account) do keys[#keys + 1] = k end
  table.sort(keys)
  local lines = { "-- Mail account (edit with: mail account set key=value)", "return {" }
  for _, k in ipairs(keys) do
    local v = account[k]
    lines[#lines + 1] = ("  %s = %s,"):format(k, type(v) == "string" and ("%q"):format(v) or tostring(v))
  end
  lines[#lines + 1] = "}"
  return vfs.writeFile(home .. "/account.lua", table.concat(lines, "\n") .. "\n")
end

--- opts: home (folder for the local mail), stack, account (table; default: read from home), tlsStore (trust store for TLS).
function M.open(opts)
  local home = opts.home
  local self = setmetatable({ home = home, stack = opts.stack, account = opts.account or M.loadAccount(home), tlsStore = opts.tlsStore, readPassword = opts.readPassword }, Client)
  vfs.mkdirp(home)
  self.store = storeMod.new({ root = home .. "/folders", users = home .. "/users.db", iterations = 1 })
  if not self.store:exists(MAILBOX) then
    self.store:addUser(MAILBOX, "local-copy-" .. tostring(os.clock()), { quota = 4000000 })
  end
  self.seenPath = home .. "/seen.db"
  return self
end

function Client:mailbox() return MAILBOX end

local function secret(self)
  local a = self.account
  if a.pass and a.pass ~= "" then return a.pass end
  if self.readPassword then return self.readPassword("Password for " .. tostring(a.user or a.address) .. ": ") end
  return nil
end

local function tlsMode(self, default)
  local t = self.account.tls
  if t == "none" or t == false then return nil end
  return t or default
end

---------------------------------------------------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------------------------------------------------

--- Download new mail by POP3 into the local INBOX. Returns the number of new messages, or nil + reason.
function Client:fetch()
  local a = self.account
  if not a.server then return nil, "no mail server is set (mail account set server=<address>)" end
  local pw = secret(self)
  if not pw then return nil, "no password" end
  local seenAll = vfs.readTable(self.seenPath) or {}
  local key = tostring(a.user) .. "@" .. tostring(a.server)
  local seen = seenAll[key] or {}
  local list, err = pop3.fetch(self.stack, a.server, { user = a.user or a.address, pass = pw, port = a.pop3port, tls = tlsMode(self, "opportunistic"), store = self.tlsStore, tlsName = a.tlsname,
    skip = seen, delete = a.leave == false })
  if not list then return nil, err end
  local n = 0
  for _, item in ipairs(list) do
    local uid, why = self.store:deliver(MAILBOX, item.raw, "INBOX", "")
    if not uid then return nil, "cannot store the message: " .. tostring(why) end
    seen[item.uid] = true
    n = n + 1
  end
  seenAll[key] = seen
  vfs.writeTable(self.seenPath, seenAll)
  return n
end

---------------------------------------------------------------------------------------------------------------------
-- Folders
---------------------------------------------------------------------------------------------------------------------

function Client:folders() return self.store:folders(MAILBOX) end

function Client:list(folder)
  local okL, items = pcall(self.store.list, self.store, MAILBOX, folder or "INBOX")
  if not okL then return {} end         -- not a valid folder name
  for i, m in ipairs(items) do m.n = i end
  return items
end

local function entry(self, folder, n)
  local items = self:list(folder)
  return items[tonumber(n)]
end

--- The raw message with number n of a folder (marks it as read).
function Client:read(folder, n)
  local e = entry(self, folder or "INBOX", n)
  if not e then return nil, "no such message" end
  local raw = self.store:get(MAILBOX, folder or "INBOX", e.uid)
  if not raw then return nil, "the message is gone" end
  if not e.flags:find("S", 1, true) then self.store:setFlags(MAILBOX, folder or "INBOX", e.uid, "S") end
  return raw, e
end

function Client:move(folder, n, target)
  local e = entry(self, folder, n)
  if not e then return nil, "no such message" end
  local okM, uid, err = pcall(self.store.move, self.store, MAILBOX, folder, e.uid, target)
  if not okM then return nil, "bad folder name" end
  return uid, err
end

--- Move to Trash; from Trash the message is deleted for good.
function Client:delete(folder, n)
  folder = folder or "INBOX"
  local e = entry(self, folder, n)
  if not e then return nil, "no such message" end
  if folder == "Trash" then
    self.store:setFlags(MAILBOX, folder, e.uid, "D")
    self.store:expunge(MAILBOX, folder)
    return true
  end
  return self.store:move(MAILBOX, folder, e.uid, "Trash")
end

---------------------------------------------------------------------------------------------------------------------
-- Writing
---------------------------------------------------------------------------------------------------------------------

--- A reply to a message: { to, cc, subject, body, headers } ready for send(). all = reply to everybody.
function Client:replyTo(raw, all)
  local m = msg.parse(raw)
  local from = m:from()
  local replyTo = msg.parseAddress(m:header("reply-to") or "") or from
  local subject = m:subject()
  if not subject:lower():match("^re:") then subject = "Re: " .. subject end
  local quoted = {}
  for line in (m:text() .. "\n"):gmatch("(.-)\n") do quoted[#quoted + 1] = "> " .. line end
  while #quoted > 0 and quoted[#quoted] == "> " do quoted[#quoted] = nil end
  local out = { to = replyTo and replyTo.addr or "", subject = subject,
    body = ("On %s, %s wrote:\n%s\n"):format(m:header("date") or "?", from and (from.name ~= "" and from.name or from.addr) or "someone", table.concat(quoted, "\n")), headers = {} }
  local mid = m:header("message-id")
  if mid then
    out.headers["In-Reply-To"] = mid
    out.headers["References"] = ((m:header("references") or "") .. " " .. mid):gsub("^%s+", "")
  end
  if all then
    local cc = {}
    local me = (self.account.address or ""):lower()
    for _, field in ipairs({ "to", "cc" }) do
      for _, a in ipairs(m:addresses(field)) do if a.addr ~= me and a.addr ~= out.to then cc[#cc + 1] = a.addr end end
    end
    if #cc > 0 then out.cc = cc end
  end
  return out
end

--- Send a message. m: to (text or list), cc, subject, body, attachments = { { name, data, type } }, headers. Returns true, or nil + reason.
function Client:send(m)
  local a = self.account
  if not a.address then return nil, "no sender address is set (mail account set address=you@domain)" end
  local server = a.smtp or a.server
  if not server then return nil, "no mail server is set" end
  local rcpts = {}
  local function collect(v)
    if not v then return end
    local text = type(v) == "table" and table.concat(v, ", ") or v
    for _, addr in ipairs(msg.parseAddressList(text)) do rcpts[#rcpts + 1] = addr.addr end
  end
  collect(m.to) collect(m.cc) collect(m.bcc)
  if #rcpts == 0 then return nil, "no recipient" end
  local from = a.name and a.name ~= "" and msg.formatAddress({ name = a.name, addr = a.address }) or a.address
  local host = a.address:match("@(.+)$")
  local raw = msg.build({ from = from, to = m.to, cc = m.cc, subject = m.subject, body = m.body, attachments = m.attachments, headers = m.headers, host = host })
  local pw = secret(self)
  if not pw then return nil, "no password" end
  local res = smtp.deliver(self.stack, server, { from = a.address, rcpts = rcpts, data = raw, helo = host or "localhost", port = a.smtpport or 587,
    tls = tlsMode(self, "opportunistic"), store = self.tlsStore, tlsName = a.tlsname, auth = { user = a.user or a.address, pass = pw } })
  if not res.ok then
    local why = res.error or "refused"
    for r, rej in pairs(res.rejected or {}) do why = why .. ("; %s: %s %s"):format(r, tostring(rej.code), tostring(rej.text)) end
    return nil, why
  end
  self.store:deliver(MAILBOX, raw, "Sent", "S")
  return true, #res.accepted
end

--- Save attachment number i of a message to path.
function Client:saveAttachment(raw, i, path)
  local att = msg.parse(raw):attachments()[tonumber(i)]
  if not att then return nil, "no such attachment" end
  local ok, err = vfs.writeFile(vfs.normalize(path or att.name or ("attachment" .. i)), att.data, true)
  if not ok then return nil, err end
  return att
end

return M
