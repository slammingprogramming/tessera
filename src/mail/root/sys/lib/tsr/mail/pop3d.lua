-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The POP3 server (RFC 1939, with CAPA from RFC 2449, STLS from RFC 2595 and UIDL/TOP): lets a user fetch the mail in the INBOX of their mailbox.
-- Like the SMTP server it is a Session state machine (easy to test line by line) with serve() for a socket.
--   AUTHORIZATION: USER / PASS (only on an encrypted connection unless allowPlainAuth), CAPA, STLS, QUIT
--   TRANSACTION:   STAT, LIST [n], RETR n, DELE n, NOOP, RSET, TOP n lines, UIDL [n], QUIT
--   UPDATE:        on QUIT the messages marked with DELE are removed (and only then)
-- One session per mailbox at a time (the maildrop lock of the RFC). Too many wrong passwords from one address lock it out for ten minutes, the same as for SMTP.
local msg = require("tsr.mail.message")
local socket = require("tsr.inet.socket")

local M = {}
local Session = {}
Session.__index = Session

M.LINE_TIMEOUT = 120
M.MAX_LINE = 512

function M.session(mail, ip, opts)
  opts = opts or {}
  return setmetatable({ mail = mail, ip = ip, secure = opts.secure or false, haveTls = opts.tls == true, state = "auth", errors = 0 }, Session)
end

function Session:greeting() return "+OK " .. self.mail.hostname .. " POP3 server ready" end

local function ok(text) return "+OK" .. (text and (" " .. text) or "") end

function Session:err(text)
  self.errors = self.errors + 1
  return "-ERR " .. text, self.errors >= (self.mail.cfg.maxErrors or 8) and "close" or nil
end

--- Replies with a body come back as: text, nil, body lines (the server dot-stuffs and ends them with ".").
local function multi(text, lines) return ok(text), nil, lines end

function Session:release()
  local locks = self.mail.pop3Locks
  if locks and self.user and locks[self.user] == self then locks[self.user] = nil end
end

local function message(self, n)
  n = tonumber(n)
  local m = n and self.drop[n]
  if not m then return nil, "no such message" end
  if m.deleted then return nil, "message " .. n .. " deleted" end
  return m
end

local function split(text)
  local lines = {}
  for l in (text .. (text:sub(-2) == "\r\n" and "" or "\r\n")):gmatch("(.-)\r\n") do lines[#lines + 1] = l end
  return lines
end

function Session:login(user, pass)
  local mail = self.mail
  mail.authFailures = mail.authFailures or {}
  local rec = mail.authFailures[self.ip or "?"] or { n = 0, until_ = 0 }
  mail.authFailures[self.ip or "?"] = rec
  local now = mail.stack.clock()
  if now < rec.until_ then return "-ERR [SYS/TEMP] Too many failed logins; try again later", "close" end
  local name = mail.store:authenticate(user, pass)
  if not name then
    rec.n = rec.n + 1
    if rec.n >= 5 then rec.until_ = now + 600 rec.n = 0 end
    return self:err("[AUTH] Invalid user name or password")
  end
  rec.n = 0
  mail.pop3Locks = mail.pop3Locks or {}
  if mail.pop3Locks[name] then return "-ERR [IN-USE] The mailbox is in use by another session" end
  mail.pop3Locks[name] = self
  self.user = name
  self.state = "transaction"
  self.drop = {}
  for _, m in ipairs(mail.store:list(name, "INBOX")) do self.drop[#self.drop + 1] = { uid = m.uid, size = m.size, flags = m.flags } end
  local count, bytes = #self.drop, 0
  for _, m in ipairs(self.drop) do bytes = bytes + m.size end
  return ok(("%s has %d message%s (%d octets)"):format(name, count, count == 1 and "" or "s", bytes))
end

--- One command line. Returns the reply, an action ("close", "starttls") and, for multi-line replies, the list of body lines.
function Session:line(line)
  line = line:gsub("\r$", "")
  local cmd, arg = line:match("^(%a+)%s*(.*)$")
  cmd = cmd and cmd:upper() or ""
  local mail = self.mail
  if cmd == "CAPA" then
    local caps = { "TOP", "UIDL", "RESP-CODES", "PIPELINING", "USER", "IMPLEMENTATION Tessera" }
    if self.haveTls and not self.secure then caps[#caps + 1] = "STLS" end
    return multi("Capability list follows", caps)
  elseif cmd == "NOOP" then return ok()
  elseif cmd == "QUIT" then
    if self.state == "transaction" then
      local removed = 0
      for _, m in ipairs(self.drop) do
        if m.deleted then mail.store:setFlags(self.user, "INBOX", m.uid, "D") removed = removed + 1 end
      end
      if removed > 0 then mail.store:expunge(self.user, "INBOX") end
      self:release()
      self.state = "done"
      return ok(removed == 0 and "bye" or (removed .. " message(s) deleted; bye")), "close"
    end
    self.state = "done"
    return ok("bye"), "close"
  end
  if self.state == "auth" then
    if cmd == "STLS" then
      if not self.haveTls then return self:err("TLS is not available") end
      if self.secure then return self:err("TLS is already active") end
      return ok("Begin TLS negotiation"), "starttls"
    elseif cmd == "USER" then
      if not (self.secure or mail.cfg.allowPlainAuth) then return self:err("[AUTH] Encryption required to log in") end
      if arg == "" then return self:err("USER needs a name") end
      self.pendingUser = arg
      return ok("send PASS")
    elseif cmd == "PASS" then
      if not self.pendingUser then return self:err("send USER first") end
      local user = self.pendingUser
      self.pendingUser = nil
      return self:login(user, arg)
    end
    return self:err("not allowed before login")
  end
  -- TRANSACTION
  if cmd == "STAT" then
    local count, bytes = 0, 0
    for _, m in ipairs(self.drop) do if not m.deleted then count = count + 1 bytes = bytes + m.size end end
    return ok(count .. " " .. bytes)
  elseif cmd == "LIST" or cmd == "UIDL" then
    local function item(i, m) return cmd == "LIST" and (i .. " " .. m.size) or (i .. " " .. m.uid) end
    if arg ~= "" then
      local m, why = message(self, arg)
      if not m then return self:err(why) end
      return ok(item(tonumber(arg), m))
    end
    local lines = {}
    for i, m in ipairs(self.drop) do if not m.deleted then lines[#lines + 1] = item(i, m) end end
    return multi(#lines .. " messages", lines)
  elseif cmd == "RETR" or cmd == "TOP" then
    local n, count = arg:match("^(%d+)%s*(%d*)$")
    if not n then return self:err("syntax: " .. cmd .. " n" .. (cmd == "TOP" and " lines" or "")) end
    if cmd == "TOP" and count == "" then return self:err("syntax: TOP n lines") end
    local m, why = message(self, n)
    if not m then return self:err(why) end
    local raw = mail.store:get(self.user, "INBOX", m.uid)
    if not raw then return self:err("the message is gone") end
    local lines = split(raw)
    if cmd == "TOP" then
      local out, inBody, left = {}, false, tonumber(count)
      for _, l in ipairs(lines) do
        if inBody then
          if left <= 0 then break end
          left = left - 1
          out[#out + 1] = l
        else
          out[#out + 1] = l
          if l == "" then inBody = true end
        end
      end
      lines = out
    else
      if not m.seen then
        m.seen = true
        mail.store:setFlags(self.user, "INBOX", m.uid, "S")
      end
    end
    return multi(#raw .. " octets", lines)
  elseif cmd == "DELE" then
    local m, why = message(self, arg)
    if not m then return self:err(why) end
    m.deleted = true
    return ok("message " .. arg .. " deleted")
  elseif cmd == "RSET" then
    for _, m in ipairs(self.drop) do m.deleted = nil end
    return ok()
  end
  return self:err("unknown command")
end

--- Serve one connection.
function M.serve(mail, conn, opts)
  opts = opts or {}
  local ip = conn:getpeername()
  local session = M.session(mail, ip, { secure = opts.secure, tls = opts.creds ~= nil })
  local raw = conn
  conn:send(session:greeting() .. "\r\n")
  while true do
    local line, err = conn:receive("*l", M.LINE_TIMEOUT)
    if not line then
      if err == "timeout" then conn:send("-ERR timeout, closing connection\r\n") end
      break
    end
    if #line > M.MAX_LINE then
      conn:send("-ERR line too long\r\n")
    else
      local text, action, body = session:line(line)
      local out = text .. "\r\n"
      if body then
        local joined = table.concat(body, "\r\n")
        out = out .. (joined ~= "" and msg.dotStuff(joined) or "") .. ".\r\n"
      end
      conn:send(out)
      if action == "close" then break
      elseif action == "starttls" then
        local secure = require("tsr.inet.tls").server(raw, opts.creds)
        if not secure then break end
        conn = secure
        session.secure = true
      end
    end
  end
  session:release()
  conn:close()
end

--- Worker functions: listeners for POP3 (110) and, with TLS credentials, POP3S (995).
function M.workers(mail, n)
  local stack = mail.stack
  local tlsMod = mail.cfg.tls and require("tsr.inet.tls")
  local creds
  if tlsMod then
    local c, why = tlsMod.loadCredentials(mail.cfg.tls.name or mail.cfg.tls, mail.cfg.tls.dir)
    if not c then mail:note("TLS is configured but unusable: " .. tostring(why)) else creds = c end
  end
  local jobs = {}
  local function listener(port, secureFromStart)
    local l = socket.tcp(stack)
    l:bind(nil, port)
    local okL, err = l:listen(8)
    if not okL then mail:note("cannot listen on port " .. port .. ": " .. tostring(err)) return end
    mail.pop3Listeners = mail.pop3Listeners or {}
    mail.pop3Listeners[#mail.pop3Listeners + 1] = l
    for _ = 1, n or 2 do
      jobs[#jobs + 1] = function()
        while mail.pop3Running do
          local c = l:accept(1)
          if c then
            local conn = c
            if secureFromStart and creds then conn = tlsMod.server(c, creds) end
            if conn then pcall(M.serve, mail, conn, { secure = secureFromStart, creds = creds }) end
          end
        end
      end
    end
  end
  mail.pop3Running = true
  listener(mail.cfg.pop3Port or 110, false)
  if creds and mail.cfg.pop3s ~= false then listener(mail.cfg.pop3sPort or 995, true) end
  return jobs
end

function M.stop(mail)
  mail.pop3Running = false
  for _, l in ipairs(mail.pop3Listeners or {}) do l:close() end
end

return M
