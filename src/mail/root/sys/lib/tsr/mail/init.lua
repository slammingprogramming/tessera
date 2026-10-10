-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The mail system of one computer: which domains it serves, where mail for them goes (mailboxes, aliases, lists), the queue of mail waiting to be
-- delivered to other servers with retries and bounce messages, and the chain of filters (anti-spam, anti-virus) that every incoming message passes.
--
--   local mail = require("tsr.mail").new(stack, {
--     hostname = "mail.example.lan", domains = { "example.lan" },
--     aliases = { postmaster = "alice", ["team@example.lan"] = { "alice", "bob", "carol@other.lan" } },
--     relayNetworks = { "10.0.0.0/8" },          -- computers here may send mail to anywhere without logging in
--     maxSize = 1048576, retryDelays = { 300, 900, 3600, 14400 }, maxAge = 432000,
--   })
local B = require("tsr.inet.bytes")
local msg = require("tsr.mail.message")
local storeMod = require("tsr.mail.store")
local smtp = require("tsr.mail.smtp")
local vfs = require("tsr.vfs")

local M = {}
local Mail = {}
Mail.__index = Mail

M.QUEUE = "/var/spool/mail/queue"
M.CONFIG = "/etc/tsr/mail/mail.lua"

function M.new(stack, cfg, store)
  cfg = cfg or {}
  local self = setmetatable({
    stack = stack, cfg = cfg, store = store or storeMod.new({ root = cfg.root, users = cfg.users }), hostname = cfg.hostname or "localhost",
    domains = {}, relayNets = {}, queueDir = cfg.queueDir or M.QUEUE, maxSize = cfg.maxSize or 1048576, maxRecipients = cfg.maxRecipients or 50,
    retryDelays = cfg.retryDelays or { 300, 900, 3600, 14400, 43200 }, maxAge = cfg.maxAge or 432000, filters = {}, stats = { received = 0, delivered = 0, queued = 0, bounced = 0, rejected = 0, spam = 0, relayed = 0, deferred = 0 },
    log = {}, resolveMx = cfg.resolveMx, aliases = cfg.aliases or {}, tlsStore = cfg.tlsStore,
  }, Mail)
  self:setRouting(cfg.domains, cfg.relayNetworks, cfg.aliases)
  return self
end

--- Which domains this server accepts mail for, which client networks may send anywhere, and the aliases (replaces the previous settings; the server calls it again
--- when the administrator changes them).
function Mail:setRouting(domains, relayNetworks, aliases)
  self.domains, self.relayNets = {}, {}
  for _, d in ipairs(domains or {}) do self.domains[d:lower()] = true end
  for _, n in ipairs(relayNetworks or {}) do
    local net, plen = B.cidr(n)
    if net then self.relayNets[#self.relayNets + 1] = { net, plen } end
  end
  if aliases then self.aliases = aliases end
end

function Mail:note(text)
  self.log[#self.log + 1] = ("%.0f %s"):format(self.stack.clock(), text)
  if #self.log > 200 then table.remove(self.log, 1) end
  if self.stack.logger then self.stack.logger("mail: " .. text) end
end

--- The time that queue ages and retries are counted in (seconds; wall-clock when the game offers it). cfg.now replaces it in tests.
function Mail:now()
  if self.cfg.now then return self.cfg.now() end
  return os.epoch and os.epoch("utc") / 1000 or self.stack.clock()
end

--- The record of failed logins for a client address (shared by SMTP and POP3). Records with nothing to remember are dropped now and then, so that addresses which
--- tried once do not accumulate for ever.
function Mail:failureRecord(ip)
  local t = self.authFailures
  if not t then t = {} self.authFailures = t self.authFailureCount = 0 end
  local key = ip or "?"
  local rec = t[key]
  if rec then return rec end
  self.authFailureCount = self.authFailureCount + 1
  if self.authFailureCount > 256 then
    local now = self.stack.clock()
    local n = 0
    for k, r in pairs(t) do
      if r.n == 0 and now >= r.until_ then t[k] = nil else n = n + 1 end
    end
    self.authFailureCount = n
  end
  rec = { n = 0, until_ = 0 }
  t[key] = rec
  return rec
end

function Mail:isLocalDomain(d) return self.domains[tostring(d):lower()] == true end

--- May this client address send mail to any domain without authenticating?
function Mail:mayRelay(ip)
  if not ip then return false end
  local n = type(ip) == "number" and ip or B.ip(ip)
  if not n then return false end
  for _, r in ipairs(self.relayNets) do if B.inNet(n, r[1], r[2]) then return true end end
  return B.isLoopback(n)
end

---------------------------------------------------------------------------------------------------------------------
-- Recipients
---------------------------------------------------------------------------------------------------------------------

--- Expand a recipient address into what it delivers to: { { mailbox = "alice" }, { remote = "carol@other.lan" } }, or nil + reason when it is unknown.
--- Handles local mailboxes, +tag addresses, aliases and lists (which may point to remote addresses), with a limit against loops.
function Mail:expand(addr, depth, seen)
  depth, seen = depth or 0, seen or {}
  local a = msg.parseAddress(addr)
  if not a then return nil, "bad address" end
  if depth > 8 then return nil, "alias loop" end
  if not self:isLocalDomain(a.domain) then return { { remote = a.addr } } end
  local localPart = a.localPart:lower():gsub("%+.*$", "")
  local full = localPart .. "@" .. a.domain
  if seen[full] then return {} end
  seen[full] = true
  local target = self.aliases[full] or self.aliases[localPart]
  if target then
    local out = {}
    if type(target) == "string" then target = { target } end
    for _, t in ipairs(target) do
      local item = t:find("@", 1, true) and t or (t .. "@" .. a.domain)
      local sub, why = self:expand(item, depth + 1, seen)
      if not sub then return nil, why end
      for _, s in ipairs(sub) do out[#out + 1] = s end
    end
    return out
  end
  if self.store:exists(localPart) then return { { mailbox = localPart } } end
  return nil, "no such user"
end

---------------------------------------------------------------------------------------------------------------------
-- Delivery
---------------------------------------------------------------------------------------------------------------------

--- Put a message into a local mailbox. folder defaults to INBOX (Spam for tagged mail). Returns true or nil + reason.
function Mail:deliverLocal(mailbox, raw, folder, sender, rcpt)
  local header = ("Return-Path: <%s>\r\nDelivered-To: %s\r\n"):format(sender or "", rcpt or mailbox)
  local uid, err = self.store:deliver(mailbox, header .. raw, folder or "INBOX", "")
  if not uid then return nil, err end
  self.stats.delivered = self.stats.delivered + 1
  return uid
end

---------------------------------------------------------------------------------------------------------------------
-- The queue
---------------------------------------------------------------------------------------------------------------------

local function qpaths(self, id) return self.queueDir .. "/" .. id .. ".eml", self.queueDir .. "/" .. id .. ".meta" end

--- Queue a message for delivery. rcpts: addresses (local and remote). Returns the queue id.
function Mail:enqueue(sender, rcpts, raw, opts)
  opts = opts or {}
  local id = require("tsr.crypto").toHex(require("tsr.crypto").rand.bytes(6))
  local eml, meta = qpaths(self, id)
  vfs.mkdirp(self.queueDir)
  local entries = {}
  for _, r in ipairs(rcpts) do entries[#entries + 1] = { addr = r, tries = 0 } end
  vfs.writeFile(eml, raw, true)
  vfs.writeTable(meta, { id = id, sender = sender or "", rcpts = entries, created = self:now(), next = 0, tries = 0, bounce = opts.bounce })
  self.stats.queued = self.stats.queued + 1
  return id
end

--- The entries of a queue folder, oldest first (also used by mailctl, which has no running server object).
function M.queueList(dir)
  local out = {}
  if vfs.fs.exists(dir) then
    for _, n in ipairs(vfs.fs.list(dir)) do
      local id = n:match("^(%w+)%.meta$")
      if id then
        local m = vfs.readTable(dir .. "/" .. id .. ".meta")
        if m then out[#out + 1] = m end
      end
    end
  end
  table.sort(out, function(a, b) return a.created < b.created end)
  return out
end

function Mail:queueList() return M.queueList(self.queueDir) end

function Mail:queueRemove(id)
  local eml, meta = qpaths(self, id)
  if vfs.fs.exists(eml) then vfs.fs.delete(eml) end
  if vfs.fs.exists(meta) then vfs.fs.delete(meta) end
end

--- Find the servers for a domain: the MX records in preference order, or the domain itself when it has none. mail.resolveMx(domain) can replace the lookup.
--- DNS questions the anti-spam checks ask. Each returns a list, or nil + reason when the server could not be asked (a temporary error).
--- An unknown name is an empty list. cfg.dnsTxt / cfg.dnsA / cfg.dnsMx replace the real lookups (tests, or a fixed table on a small LAN).
local function dnsRecords(self, name, qtype, pick)
  local ok, dns = pcall(require, "tsr.inet.dns.client")
  if not ok then return nil, "no DNS client installed" end
  local r, why = dns.lookup(self.stack, name, qtype, {})
  if not r then return nil, why end
  if r.rcode ~= 0 then return {} end
  local out = {}
  for _, rr in ipairs(r.answers) do
    local v = pick(rr)
    if v ~= nil then out[#out + 1] = v end
  end
  return out
end

function Mail:dnsTxt(name)
  if self.cfg.dnsTxt then return self.cfg.dnsTxt(name) end
  return dnsRecords(self, name, "TXT", function(rr) if rr.type == 16 then return table.concat(rr.data) end end)
end

function Mail:dnsA(name)
  if self.cfg.dnsA then return self.cfg.dnsA(name) end
  return dnsRecords(self, name, "A", function(rr) if rr.type == 1 then return type(rr.data) == "number" and B.ipStr(rr.data) or rr.data end end)
end

--- MX records as { { preference, exchange } } sorted by preference.
function Mail:dnsMx(name)
  if self.cfg.dnsMx then return self.cfg.dnsMx(name) end
  local list, why = dnsRecords(self, name, "MX", function(rr) if rr.type == 15 then return rr.data end end)
  if not list then return nil, why end
  table.sort(list, function(a, b) return a.preference < b.preference end)
  return list
end

function Mail:mxHosts(domain)
  if self.resolveMx then return self.resolveMx(domain) end
  local okD, dns = pcall(require, "tsr.inet.dns.client")
  local hosts = {}
  if okD then
    local r = dns.lookup(self.stack, domain, "MX", {})
    if r and r.rcode == 0 then
      local list = {}
      for _, rr in ipairs(r.answers) do if rr.type == 15 then list[#list + 1] = rr.data end end
      table.sort(list, function(a, b) return a.preference < b.preference end)
      for _, x in ipairs(list) do hosts[#hosts + 1] = x.exchange end
    elseif r and r.rcode == 3 then
      return nil, "the domain " .. domain .. " does not exist"
    end
  end
  if #hosts == 0 then hosts[1] = domain end
  return hosts
end

local function bounceText(self, meta, failures, raw)
  local lines = { "This is the mail system at " .. self.hostname .. ".", "", "I'm sorry to have to inform you that your message could not be delivered to one or more recipients.", "" }
  for _, f in ipairs(failures) do lines[#lines + 1] = ("<%s>: %s"):format(f.addr, f.reason) end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "--- the beginning of your message ---"
  local head = raw:sub(1, 1500)
  lines[#lines + 1] = head
  return table.concat(lines, "\r\n")
end

--- Tell the sender that delivery failed. Bounces of bounces are dropped.
function Mail:bounce(meta, failures, raw)
  self.stats.bounced = self.stats.bounced + #failures
  if meta.sender == "" or meta.sender == nil or meta.bounce then return end
  local text = msg.build({ from = "Mail Delivery System <mailer-daemon@" .. self.hostname .. ">", to = meta.sender, subject = "Undelivered Mail Returned to Sender", body = bounceText(self, meta, failures, raw),
    host = self.hostname, headers = { ["Auto-Submitted"] = "auto-replied" } })
  local rcpts = { meta.sender }
  local expanded, why = self:expand(meta.sender)
  if expanded then
    local id = self:enqueue("", rcpts, text, { bounce = true })
    return id
  end
end

--- Try to deliver one queue entry. Returns "done", "retry" or "failed".
function Mail:processEntry(meta)
  local eml = qpaths(self, meta.id)
  local raw = vfs.readFile(eml, true)
  if not raw then self:queueRemove(meta.id) return "done" end
  local now = self:now()
  local failures, pending = {}, {}
  -- group by destination: local mailboxes first, then each remote domain
  local byDomain = {}
  for _, r in ipairs(meta.rcpts) do
    local a = msg.parseAddress(r.addr)
    if not a then failures[#failures + 1] = { addr = r.addr, reason = "bad address" }
    elseif self:isLocalDomain(a.domain) then
      local dest, why = self:expand(r.addr)
      if not dest then failures[#failures + 1] = { addr = r.addr, reason = tostring(why) }
      else
        -- Every member of an alias or list is delivered on its own: one that fails does not stop the others, and what already arrived is remembered (r.delivered)
        -- so that a retry does not deliver it a second time.
        local delivered = r.delivered or {}
        local tempFail
        for _, d in ipairs(dest) do
          if d.mailbox then
            if not delivered[d.mailbox] then
              local ok, err = self:deliverLocal(d.mailbox, raw, nil, meta.sender, r.addr)
              if ok then delivered[d.mailbox] = true
              elseif err == "quota" then
                failures[#failures + 1] = { addr = #dest > 1 and (d.mailbox .. " (" .. r.addr .. ")") or r.addr, reason = "mailbox full" }
                delivered[d.mailbox] = true            -- a permanent failure: do not try this member again
              else tempFail = tempFail or tostring(err) end
            end
          elseif not r.remoteDone then
            -- an alias pointing to a remote address: relay it
            local ra = msg.parseAddress(d.remote)
            byDomain[ra.domain] = byDomain[ra.domain] or {}
            table.insert(byDomain[ra.domain], d.remote)
          end
        end
        if tempFail then
          pending[#pending + 1] = { addr = r.addr, tries = (r.tries or 0) + 1, last = tempFail, delivered = delivered, remoteDone = true }
        end
      end
    else
      byDomain[a.domain] = byDomain[a.domain] or {}
      table.insert(byDomain[a.domain], r.addr)
    end
  end
  for domain, addrs in pairs(byDomain) do
    local hosts, why = self:mxHosts(domain)
    if not hosts then
      for _, a in ipairs(addrs) do failures[#failures + 1] = { addr = a, reason = tostring(why) } end
    else
      local remaining = addrs
      local lastErr
      for _, host in ipairs(hosts) do
        local res = smtp.deliver(self.stack, host, { from = meta.sender, rcpts = remaining, data = raw, helo = self.hostname, port = self.cfg.smtpPort or 25, tls = self.cfg.outboundTls or "opportunistic",
          store = self.tlsStore, timeout = self.cfg.smtpTimeout })
        if res.ok or #res.accepted > 0 then
          self.stats.relayed = self.stats.relayed + #res.accepted
          local still = {}
          for _, a in ipairs(remaining) do
            local rej = res.rejected[a]
            if rej then
              if rej.permanent then failures[#failures + 1] = { addr = a, reason = ("%s %s"):format(tostring(rej.code), rej.text) } else still[#still + 1] = a lastErr = rej.text end
            end
          end
          remaining = still
          if #remaining == 0 then break end
        elseif res.error and not res.tempfail then
          -- a permanent refusal by the server: all remaining recipients fail
          for _, a in ipairs(remaining) do
            local rej = res.rejected[a]
            failures[#failures + 1] = { addr = a, reason = rej and ("%s %s"):format(tostring(rej.code), rej.text) or res.error }
          end
          remaining = {}
          break
        else
          lastErr = res.error
          -- the server's own words say more than "no recipient was accepted"
          for _, rej in pairs(res.rejected) do lastErr = ("%s %s"):format(tostring(rej.code), tostring(rej.text)) break end
          local allPermanent = next(res.rejected) ~= nil
          for a, rej in pairs(res.rejected) do if not rej.permanent then allPermanent = false end end
          if allPermanent then
            for _, a in ipairs(remaining) do local rej = res.rejected[a] failures[#failures + 1] = { addr = a, reason = ("%s %s"):format(tostring(rej.code), rej.text) } end
            remaining = {}
            break
          end
        end
      end
      for _, a in ipairs(remaining) do pending[#pending + 1] = { addr = a, tries = 1, last = tostring(lastErr) } end
    end
  end
  -- carry over the retry counts of recipients that stay in the queue
  for _, p in ipairs(pending) do
    for _, old in ipairs(meta.rcpts) do if old.addr == p.addr then p.tries = (old.tries or 0) + 1 end end
  end
  if #failures > 0 then self:bounce(meta, failures, raw) end
  if #pending == 0 then self:queueRemove(meta.id) return "done" end
  -- too old: give up
  if now - meta.created > self.maxAge then
    local gaveUp = {}
    for _, p in ipairs(pending) do gaveUp[#gaveUp + 1] = { addr = p.addr, reason = "delivery gave up after " .. math.floor((now - meta.created) / 3600) .. " hours: " .. tostring(p.last) } end
    self:bounce(meta, gaveUp, raw)
    self:queueRemove(meta.id)
    return "failed"
  end
  local tries = 0
  for _, p in ipairs(pending) do tries = math.max(tries, p.tries) end
  meta.rcpts = pending
  meta.tries = tries
  meta.next = now + (self.retryDelays[math.min(tries, #self.retryDelays)] or self.retryDelays[#self.retryDelays])
  meta.last = pending[1].last
  local _, metaPath = qpaths(self, meta.id)
  vfs.writeTable(metaPath, meta)
  self.stats.deferred = self.stats.deferred + 1
  return "retry"
end

--- Deliver everything in the queue that is due (all of it with force). Returns counts.
function Mail:processQueue(force)
  local now = self:now()
  local n = { done = 0, retry = 0, failed = 0 }
  for _, meta in ipairs(self:queueList()) do
    if force or (meta.next or 0) <= now then
      local r = self:processEntry(meta)
      n[r] = n[r] + 1
    end
  end
  return n
end

--- The queue worker: delivers due mail every few seconds, forever.
function Mail:queueWorker(interval)
  self.running = true
  while self.running do
    local ok, err = pcall(self.processQueue, self)
    if not ok then self:note("queue error: " .. tostring(err)) end
    self.stack.wait(function() return not self.running end, interval or 10)
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Filters
---------------------------------------------------------------------------------------------------------------------

--- Add a filter to the incoming chain: fn(ctx) returns nil to pass, or a verdict { "reject", code, text } / { "spam", reason }. Lower order runs first.
--- ctx: ip, helo, sender, rcpts, raw, message (parsed), authUser, add (list of header lines to add), results (table for notes like spf = "pass").
function Mail:addFilter(name, fn, order)
  for i, f in ipairs(self.filters) do if f.name == name then table.remove(self.filters, i) break end end
  self.filters[#self.filters + 1] = { name = name, fn = fn, order = order or 100 }
  table.sort(self.filters, function(a, b) return a.order < b.order end)
end

--- Filters for mail that users send: fn(ctx) with ctx = { session, user, sender, rcpts, raw }; may return { "reject", code, text }.
function Mail:addOutboundFilter(name, fn)
  self.outboundFilters = self.outboundFilters or {}
  for i, f in ipairs(self.outboundFilters) do if f.name == name then table.remove(self.outboundFilters, i) break end end
  self.outboundFilters[#self.outboundFilters + 1] = { name = name, fn = fn }
end

function Mail:runOutboundFilters(session, raw)
  for _, f in ipairs(self.outboundFilters or {}) do
    local ok, verdict = pcall(f.fn, { session = session, user = session.auth, sender = session.sender, rcpts = session.rcpts, raw = raw, ip = session.ip })
    if not ok then self:note("outbound filter " .. f.name .. " failed: " .. tostring(verdict))
    elseif verdict and verdict[1] == "reject" then return verdict end
  end
  return nil
end

--- Run the filters. Returns verdict: { "accept" }, { "spam", reason, score }, or { "reject", code, text }.
function Mail:runFilters(ctx)
  ctx.add = ctx.add or {}
  ctx.results = ctx.results or {}
  ctx.message = ctx.message or msg.parse(ctx.raw)
  local spam
  for _, f in ipairs(self.filters) do
    local ok, verdict = pcall(f.fn, ctx)
    if not ok then self:note("filter " .. f.name .. " failed: " .. tostring(verdict))
    elseif verdict then
      if verdict[1] == "reject" then return verdict end
      if verdict[1] == "spam" then spam = spam or verdict end
    end
  end
  return spam or { "accept" }
end

return M
