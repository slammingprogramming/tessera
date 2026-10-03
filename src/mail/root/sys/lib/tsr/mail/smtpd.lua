-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The SMTP server (RFC 5321): receives mail from other servers (port 25) and from users' mail programs (port 587, which requires logging in).
-- Each connection is a Session, a small state machine that can be driven line by line (so it is easy to test); serve() puts it on a socket.
--
-- Rules it enforces:  no relaying for strangers (only logged-in users and the relayNetworks may send to other domains); a logged-in user may only send
-- as their own address; unknown local users are refused while the sender still waits (no bounces for mail we accepted by mistake: "backscatter");
-- size, recipient and error limits; loops are cut; login needs an encrypted connection unless allowPlainAuth is set; every message goes through the
-- filter chain (anti-spam, anti-virus) before it is stored.
local B = require("tsr.inet.bytes")
local hash = require("tsr.hash")
local msg = require("tsr.mail.message")
local socket = require("tsr.inet.socket")

local M = {}
local Session = {}
Session.__index = Session

M.LINE_TIMEOUT = 60
M.MAX_LINE = 1000

function M.session(mail, ip, opts)
  opts = opts or {}
  local self = setmetatable({
    mail = mail, ip = ip, kind = opts.kind or "mx", secure = opts.secure or false, state = "new", rcpts = {}, errors = 0, bytes = 0, data = {}, auth = nil,
    maxErrors = mail.cfg.maxErrors or 8, haveTls = opts.tls == true,
  }, Session)
  return self
end

function Session:greeting() return ("220 %s ESMTP Tessera ready"):format(self.mail.hostname) end

local function reply(code, text) return code .. " " .. text end

function Session:error(code, text)
  self.errors = self.errors + 1
  return reply(code, text), self.errors >= self.maxErrors and "close" or nil
end

function Session:reset()
  self.sender, self.rcpts, self.data, self.bytes = nil, {}, {}, 0
  if self.state ~= "new" then self.state = "greeted" end
end

local function parseArgs(text)
  local addr, rest = text:match("^<([^>]*)>%s*(.*)$")
  if not addr then addr, rest = text:match("^([^%s<>]+)%s*(.*)$") end
  local params = {}
  for k, v in (rest or ""):gmatch("(%w+)=(%S+)") do params[k:upper()] = v end
  return addr, params
end

function Session:capabilities()
  local lines = { ("%s Hello %s"):format(self.mail.hostname, self.ip or "") , ("SIZE %d"):format(self.mail.maxSize), "8BITMIME", "ENHANCEDSTATUSCODES", "PIPELINING" }
  if self.haveTls and not self.secure then lines[#lines + 1] = "STARTTLS" end
  if (self.secure or self.mail.cfg.allowPlainAuth) and not self.auth then lines[#lines + 1] = "AUTH PLAIN LOGIN" end
  lines[#lines + 1] = "HELP"
  return lines
end

local function multi(code, lines)
  local out = {}
  for i, l in ipairs(lines) do out[#out + 1] = code .. (i < #lines and "-" or " ") .. l end
  return table.concat(out, "\r\n")
end

--- One command line. Returns the reply text and an optional action: "close", "starttls", "data" (the next lines are the message).
--- During AUTH LOGIN the session asks for more input: it returns the prompt and the action "auth".
function Session:line(line)
  line = line:gsub("\r$", "")
  if self.authStep then return self:authContinue(line) end
  local verb, arg = line:match("^(%a+)%s*(.*)$")
  verb = verb and verb:upper() or ""
  local mail = self.mail
  if verb == "EHLO" or verb == "HELO" then
    if arg == "" then return self:error(501, "5.5.4 Syntax: " .. verb .. " hostname") end
    self.helo = arg
    self:reset()
    self.state = "greeted"
    if verb == "EHLO" then return multi(250, self:capabilities()) end
    return reply(250, mail.hostname)
  elseif verb == "NOOP" then return reply(250, "2.0.0 Ok")
  elseif verb == "QUIT" then return reply(221, "2.0.0 Bye"), "close"
  elseif verb == "RSET" then self:reset() return reply(250, "2.0.0 Ok")
  elseif verb == "VRFY" then return reply(252, "2.5.2 Cannot verify user, but will accept the message")
  elseif verb == "EXPN" then return reply(502, "5.5.1 Command not implemented")
  elseif verb == "HELP" then return reply(214, "2.0.0 See the project documentation (docs/MAIL.md)")
  elseif verb == "STARTTLS" then
    if not self.haveTls then return self:error(502, "5.5.1 TLS is not available") end
    if self.secure then return self:error(503, "5.5.1 TLS is already active") end
    return reply(220, "2.0.0 Ready to start TLS"), "starttls"
  elseif verb == "AUTH" then
    return self:authStart(arg)
  elseif verb == "MAIL" then
    if self.state == "new" then return self:error(503, "5.5.1 Say EHLO first") end
    if self.sender ~= nil then return self:error(503, "5.5.1 A sender was given already") end
    if self.kind == "submission" and not self.auth then return self:error(530, "5.7.0 Authentication required") end
    local text = arg:match("^[Ff][Rr][Oo][Mm]:%s*(.*)$")
    if not text then return self:error(501, "5.5.4 Syntax: MAIL FROM:<address>") end
    local addr, params = parseArgs(text)
    if addr == nil then return self:error(501, "5.1.7 Bad sender address syntax") end
    local parsed = addr == "" and { addr = "", domain = "" } or msg.parseAddress(addr)
    if not parsed then return self:error(501, "5.1.7 Bad sender address syntax") end
    if params.SIZE and tonumber(params.SIZE) and tonumber(params.SIZE) > mail.maxSize then return self:error(552, "5.3.4 Message size exceeds the limit of " .. mail.maxSize .. " bytes") end
    if self.auth and parsed.addr ~= "" then
      -- a logged-in user may only send as themselves (or one of their aliases) on a domain we serve
      if mail:isLocalDomain(parsed.domain) then
        local dest = mail:expand(parsed.addr)
        local mine = false
        for _, d in ipairs(dest or {}) do if d.mailbox == self.auth then mine = true end end
        if not mine and parsed.localPart:lower() ~= self.auth then return self:error(553, "5.7.1 You may not send as " .. parsed.addr) end
      end
    end
    local hook = mail.policy and mail.policy.mailFrom
    if hook and not self.auth then
      local bad = hook(self, parsed)
      if bad then return self:error(bad[1], bad[2]) end
    end
    self.sender = parsed.addr
    self.sizeDeclared = tonumber(params.SIZE)
    self.state = "mail"
    return reply(250, "2.1.0 Ok")
  elseif verb == "RCPT" then
    if self.state ~= "mail" and self.state ~= "rcpt" then return self:error(503, "5.5.1 Need MAIL FROM first") end
    local text = arg:match("^[Tt][Oo]:%s*(.*)$")
    if not text then return self:error(501, "5.5.4 Syntax: RCPT TO:<address>") end
    local addr = parseArgs(text)
    local parsed = addr and msg.parseAddress(addr)
    if not parsed or parsed.addr == "" then return self:error(501, "5.1.3 Bad recipient address syntax") end
    if #self.rcpts >= mail.maxRecipients then return reply(452, "4.5.3 Too many recipients") end
    if mail:isLocalDomain(parsed.domain) then
      local dest, why = mail:expand(parsed.addr)
      if not dest then
        mail.stats.rejected = mail.stats.rejected + 1
        return self:error(550, "5.1.1 <" .. parsed.addr .. ">: Recipient address rejected: User unknown in local recipient table")
      end
      local hook = mail.policy and mail.policy.rcpt
      if hook and not self.auth and not mail:mayRelay(self.ip) then
        local bad = hook(self, parsed)
        if bad then return reply(bad[1], bad[2]) end
      end
    else
      if not (self.auth or mail:mayRelay(self.ip)) then
        mail.stats.rejected = mail.stats.rejected + 1
        return self:error(554, "5.7.1 <" .. parsed.addr .. ">: Relay access denied")
      end
    end
    self.rcpts[#self.rcpts + 1] = parsed.addr
    self.state = "rcpt"
    return reply(250, "2.1.5 Ok")
  elseif verb == "DATA" then
    if self.state ~= "rcpt" then return self:error(503, "5.5.1 Need RCPT TO first") end
    if arg ~= "" then return self:error(501, "5.5.4 DATA takes no arguments") end
    self.data, self.bytes = {}, 0
    return reply(354, "End data with <CR><LF>.<CR><LF>"), "data"
  elseif verb == "" then
    return self:error(500, "5.5.2 Error: bad syntax")
  end
  return self:error(502, "5.5.2 Error: command not recognized")
end

---------------------------------------------------------------------------------------------------------------------
-- AUTH
---------------------------------------------------------------------------------------------------------------------

function Session:authFinish(user, pass)
  local mail = self.mail
  self.authStep = nil
  mail.authFailures = mail.authFailures or {}
  local rec = mail.authFailures[self.ip or "?"] or { n = 0, until_ = 0 }
  mail.authFailures[self.ip or "?"] = rec
  local now = mail.stack.clock()
  if now < rec.until_ then return reply(421, "4.7.0 Too many failed logins; try again later"), "close" end
  local name = mail.store:authenticate(user, pass)
  if not name then
    rec.n = rec.n + 1
    if rec.n >= 5 then rec.until_ = now + 600 rec.n = 0 end
    return self:error(535, "5.7.8 Authentication credentials invalid")
  end
  rec.n = 0
  self.auth = name
  return reply(235, "2.7.0 Authentication successful")
end

function Session:authStart(arg)
  if self.state == "new" then return self:error(503, "5.5.1 Say EHLO first") end
  if self.auth then return self:error(503, "5.5.1 Already authenticated") end
  if not (self.secure or self.mail.cfg.allowPlainAuth) then return self:error(538, "5.7.11 Encryption required for authentication") end
  local mech, initial = arg:match("^(%a+)%s*(.*)$")
  mech = mech and mech:upper()
  if mech == "PLAIN" then
    self.authStep = "plain"
    if initial == "" then return reply(334, "") end
    return self:authContinue(initial)
  elseif mech == "LOGIN" then
    if initial ~= "" then self.authUser = hash.base64Decode(initial) self.authStep = "login-pass" return reply(334, "UGFzc3dvcmQ6") end
    self.authStep = "login-user"
    return reply(334, "VXNlcm5hbWU6")
  end
  return self:error(504, "5.5.4 Unrecognized authentication type")
end

function Session:authContinue(text)
  if text == "*" then self.authStep = nil return reply(501, "5.0.0 Authentication cancelled") end
  local decoded = hash.base64Decode(text)
  if not decoded then self.authStep = nil return self:error(501, "5.5.2 Cannot decode the response") end
  local step = self.authStep
  if step == "plain" then
    local z1 = decoded:find("\0", 1, true)
    local z2 = z1 and decoded:find("\0", z1 + 1, true)
    if not z2 then self.authStep = nil return self:error(501, "5.5.2 Bad PLAIN response") end
    return self:authFinish(decoded:sub(z1 + 1, z2 - 1), decoded:sub(z2 + 1))
  elseif step == "login-user" then
    self.authUser = decoded
    self.authStep = "login-pass"
    return reply(334, "UGFzc3dvcmQ6")
  elseif step == "login-pass" then
    return self:authFinish(self.authUser, decoded)
  end
  return self:error(503, "5.5.1 Unexpected authentication data")
end

---------------------------------------------------------------------------------------------------------------------
-- The message
---------------------------------------------------------------------------------------------------------------------

--- One line of the message in DATA mode. Returns nil while the message goes on, or the final reply when the end marker came.
function Session:dataLine(line)
  line = line:gsub("\r$", "")
  if line == "." then
    local text = table.concat(self.data, "\r\n") .. "\r\n"
    self.data = {}
    local r = self:finish(text)
    self:reset()
    return r
  end
  self.bytes = self.bytes + #line + 2
  if self.bytes > self.mail.maxSize then
    self.tooBig = true
    return nil
  end
  self.data[#self.data + 1] = line:sub(1, 2) == ".." and line:sub(2) or line
  return nil
end

function Session:finishTooBig()
  self.tooBig = false
  self.data = {}
  self:reset()
  return reply(552, "5.3.4 Message size exceeds the limit of " .. self.mail.maxSize .. " bytes")
end

local function receivedHeader(self, id)
  local date = msg.date()
  return ("Received: from %s ([%s]) by %s with %s%s id %s; %s"):format(self.helo or "unknown", self.ip or "?", self.mail.hostname, self.secure and "ESMTPS" or "ESMTP", self.auth and "A" or "", id, date)
end

--- Process a complete message. Returns the reply line.
function Session:finish(raw)
  local mail = self.mail
  raw = msg.normalize(raw)
  mail.stats.received = mail.stats.received + 1
  local id = require("tsr.crypto").toHex(require("tsr.crypto").rand.bytes(5))
  local parsed = msg.parse(raw)
  if #parsed:headerAll("received") > 30 then return reply(554, "5.4.6 Too many hops: mail loop detected") end
  local sender = self.sender or ""
  -- submission by a logged-in user (or a trusted network): fill in what is missing, sign it, queue it
  local relayClient = self.auth or mail:mayRelay(self.ip)
  local remoteTargets = false
  for _, r in ipairs(self.rcpts) do
    local a = msg.parseAddress(r)
    if a and not mail:isLocalDomain(a.domain) then remoteTargets = true end
  end
  if self.auth or (relayClient and remoteTargets) then
    local extra = {}
    if not parsed:header("message-id") then extra[#extra + 1] = "Message-ID: " .. msg.newId(mail.hostname) end
    if not parsed:header("date") then extra[#extra + 1] = "Date: " .. msg.date() end
    local out = raw
    if #extra > 0 then out = msg.prepend(out, extra) end
    out = msg.prepend(out, receivedHeader(self, id))
    if mail.signOutbound then
      local ok, signed = pcall(mail.signOutbound, mail, out, sender)
      if ok and signed then out = signed end
    end
    local verdict = mail:runOutboundFilters(self, out)
    if verdict and verdict[1] == "reject" then mail.stats.rejected = mail.stats.rejected + 1 return reply(verdict[2], verdict[3]) end
    local qid = mail:enqueue(sender, self.rcpts, out)
    -- deliver the local part right away; remote deliveries are attempted by the queue worker (and at once when the worker is told)
    if mail.cfg.deliverNow ~= false then mail:processQueue(true) end
    return reply(250, "2.0.0 Ok: queued as " .. qid)
  end
  -- mail from another server for our users
  local ctx = { ip = self.ip, helo = self.helo, sender = sender, rcpts = self.rcpts, raw = raw, message = parsed, authUser = self.auth, secure = self.secure, session = self }
  local verdict = mail:runFilters(ctx)
  if verdict[1] == "reject" then
    mail.stats.rejected = mail.stats.rejected + 1
    mail:note(("rejected mail from %s <%s>: %s %s"):format(tostring(self.ip), sender, tostring(verdict[2]), tostring(verdict[3])))
    return reply(verdict[2], verdict[3])
  end
  local lines = { receivedHeader(self, id) }
  for _, l in ipairs(ctx.add or {}) do lines[#lines + 1] = l end
  local spam = verdict[1] == "spam"
  if spam then
    lines[#lines + 1] = "X-Spam-Flag: YES"
    mail.stats.spam = mail.stats.spam + 1
  end
  local final = msg.prepend(raw, lines)
  local folder = spam and "Spam" or "INBOX"
  local failed
  for _, r in ipairs(self.rcpts) do
    local dest = mail:expand(r)
    for _, d in ipairs(dest or {}) do
      if d.mailbox then
        local uid, err = mail:deliverLocal(d.mailbox, final, folder, sender, r)
        if not uid then
          if err == "quota" then failed = reply(452, "4.2.2 Mailbox full") else failed = reply(451, "4.3.0 Local error in processing: " .. tostring(err)) end
        end
      elseif d.remote then
        mail:enqueue(sender, { d.remote }, final)
      end
    end
  end
  if failed then return failed end
  return reply(250, "2.0.0 Ok: queued as " .. id)
end

---------------------------------------------------------------------------------------------------------------------
-- On a socket
---------------------------------------------------------------------------------------------------------------------

--- Serve one connection. conn: a TCP socket (or a TLS session for the smtps port). opts: kind ("mx" | "submission"), secure, creds (TLS server credentials for STARTTLS).
function M.serve(mail, conn, opts)
  opts = opts or {}
  local ip = conn:getpeername()
  local session = M.session(mail, ip, { kind = opts.kind, secure = opts.secure, tls = opts.creds ~= nil })
  local raw = conn
  conn:send(session:greeting() .. "\r\n")
  while true do
    local line, err = conn:receive("*l", M.LINE_TIMEOUT)
    if not line then
      if err == "timeout" then conn:send("421 4.4.2 Timeout, closing connection\r\n") end
      break
    end
    if #line > M.MAX_LINE then
      conn:send("500 5.5.2 Line too long\r\n")
    else
      local text, action = session:line(line)
      conn:send(text .. "\r\n")
      if action == "close" then break
      elseif action == "starttls" then
        local tls = require("tsr.inet.tls")
        local secure = tls.server(raw, opts.creds)
        if not secure then return end
        conn = secure
        session.secure, session.helo, session.state = true, nil, "new"
        session:reset()
      elseif action == "data" then
        local failed
        while true do
          local l, e = conn:receive("*l", M.LINE_TIMEOUT)
          if not l then failed = true break end
          local final = session:dataLine(l)
          if final then conn:send(final .. "\r\n") break end
          if session.tooBig then
            -- swallow the rest of the message, then refuse it
            repeat local more = conn:receive("*l", M.LINE_TIMEOUT) until more == nil or more == "."
            conn:send(session:finishTooBig() .. "\r\n")
            break
          end
        end
        if failed then break end
      end
    end
  end
  conn:close()
end

--- Worker functions: listeners for the mx port (25), the submission port (587) and the secure submission port (465, TLS from the first byte).
function M.workers(mail, n)
  local stack = mail.stack
  local tlsMod = mail.cfg.tls and require("tsr.inet.tls")
  local creds
  if tlsMod then
    local c, why = tlsMod.loadCredentials(mail.cfg.tls.name or mail.cfg.tls, mail.cfg.tls.dir)
    if not c then mail:note("TLS is configured but unusable: " .. tostring(why)) else creds = c end
  end
  local jobs = {}
  local function listener(port, kind, secureFromStart)
    local l = socket.tcp(stack)
    l:bind(nil, port)
    local ok, err = l:listen(16)
    if not ok then mail:note("cannot listen on port " .. port .. ": " .. tostring(err)) return end
    mail.listeners = mail.listeners or {}
    mail.listeners[#mail.listeners + 1] = l
    for _ = 1, n or 3 do
      jobs[#jobs + 1] = function()
        while mail.running do
          local c = l:accept(1)
          if c then
            local conn = c
            if secureFromStart and creds then
              conn = tlsMod.server(c, creds)
            end
            if conn then pcall(M.serve, mail, conn, { kind = kind, secure = secureFromStart, creds = creds }) end
          end
        end
      end
    end
  end
  mail.running = true
  listener(mail.cfg.port or 25, "mx", false)
  if mail.cfg.submission ~= false then listener(mail.cfg.submissionPort or 587, "submission", false) end
  if creds and mail.cfg.smtps ~= false then listener(mail.cfg.smtpsPort or 465, "submission", true) end
  jobs[#jobs + 1] = function() mail:queueWorker(mail.cfg.queueInterval or 10) end
  return jobs
end

function M.stop(mail)
  mail.running = false
  for _, l in ipairs(mail.listeners or {}) do l:close() end
end

return M
