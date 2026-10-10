-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Anti-spam for the mail server: puts the checks together and hangs them on the mail system.
--   1. connection level: greylisting (mail.policy.rcpt), blocklists
--   2. identity: SPF, DKIM, DMARC -> an Authentication-Results header, and a reject when the domain's own DMARC policy says so
--   3. content: rules (each adds or removes points), the learning filter (bayes), blocklists of senders -> X-Spam-Status header; spam goes to the Spam folder,
--      very high scores are refused at the SMTP level
--   4. outgoing: DKIM signing of the mail users send
-- Mail from trusted networks (relayNetworks) and from users who logged in is never judged.
--   local S = spam.install(mail, { greylist = { delay = 300 }, dnsbl = { "bl.example.lan" }, spamAt = 5, rejectAt = 12, bayes = "/var/lib/tsr/mail/bayes.lua",
--                                  dkim = { ["example.lan"] = { selector = "mail1", seed = <32 bytes> } }, allow = { "friend@x.lan" }, deny = { "spammer.lan" } })
local msg = require("tsr.mail.message")
local spf = require("tsr.mail.spam.spf")
local dkim = require("tsr.mail.spam.dkim")
local dmarc = require("tsr.mail.spam.dmarc")
local dnsbl = require("tsr.mail.spam.dnsbl")
local bayes = require("tsr.mail.spam.bayes")
local greylist = require("tsr.mail.spam.greylist")
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")

local M = {}
local Spam = {}
Spam.__index = Spam

M.SPAM_AT = 5
M.REJECT_AT = 12

---------------------------------------------------------------------------------------------------------------------
-- Rules: name, points, test(c) -> true / false. c = { m (message), subject, text, from, raw, results, hits }
---------------------------------------------------------------------------------------------------------------------

local BAD_WORDS = {
  "free money", "you have won", "you won", "winner", "lottery", "prize", "click here", "act now", "limited time", "100% free", "guaranteed", "wire transfer",
  "bitcoin", "verify your account", "your account has been", "password expires", "dear customer", "dear friend", "unsubscribe", "viagra", "cheap pills", "no obligation",
  "free op", "free ops", "free admin", "free diamonds", "free netherite", "free ranks", "free rank", "free hacks", "hack client", "server hack", "duplicate items", "dupe glitch",
  "claim your", "send your password", "gift card", "make money fast", "work from home",
}

local DANGEROUS_EXT = { exe = true, scr = true, bat = true, cmd = true, com = true, pif = true, vbs = true, js = true, jar = true, lnk = true, msi = true }
local SCRIPT_EXT = { lua = true, sh = true }

local function letters(s) return (s:gsub("[^%a]", "")) end

local function domainOf(addr) return addr and addr.domain or "" end

M.RULES = {
  { "MISSING_DATE", 1.0, function(c) return not c.m:header("date") end },
  { "MISSING_MESSAGE_ID", 1.0, function(c) return not c.m:header("message-id") end },
  { "NO_SUBJECT", 0.5, function(c) return c.subject:gsub("%s", "") == "" end },
  { "SUBJECT_SHOUTING", 1.5, function(c)
      local l = letters(c.subject)
      return #l >= 8 and select(2, l:gsub("%u", "")) / #l > 0.8
    end },
  { "SUBJECT_EXCLAIM", 1.0, function(c) return c.subject:find("!!", 1, true) ~= nil or select(2, c.subject:gsub("!", "")) >= 3 end },
  { "SUBJECT_DOLLARS", 0.7, function(c) return c.subject:find("%$%d") ~= nil end },
  { "BAD_WORDS", 1.2, function(c)
      local text = (c.subject .. " " .. c.text):lower()
      local n = 0
      for _, w in ipairs(BAD_WORDS) do if text:find(w, 1, true) then n = n + 1 end end
      if n == 0 then return false end
      return math.min(4.5, 1.2 * n)
    end },
  { "RAW_IP_LINK", 1.5, function(c) return c.text:find("https?://%d+%.%d+%.%d+%.%d+") ~= nil end },
  { "MANY_LINKS", 1.0, function(c) return select(2, c.text:gsub("https?://", "")) > 5 end },
  { "HTML_ONLY", 0.8, function(c) return c.htmlOnly end },
  { "REPLY_TO_DIFFERS", 1.0, function(c)
      local r = msg.parseAddress(c.m:header("reply-to") or "")
      return r and c.from and r.domain ~= c.from.domain
    end },
  { "FROM_NAME_FAKE_ADDRESS", 2.0, function(c)
      if not c.from or not c.from.name then return false end
      local inName = c.from.name:match("[%w._%-]+@[%w.%-]+")
      return inName ~= nil and inName:lower() ~= c.from.addr
    end },
  { "NO_TO_HEADER", 0.5, function(c) return not c.m:header("to") and not c.m:header("cc") end },
  { "DANGEROUS_ATTACHMENT", 3.0, function(c)
      for _, a in ipairs(c.attachments) do
        local ext = (a.name or ""):lower():match("%.(%w+)$")
        if ext and DANGEROUS_EXT[ext] then return true end
      end
      return false
    end },
  { "SCRIPT_ATTACHMENT", 1.0, function(c)
      for _, a in ipairs(c.attachments) do
        local ext = (a.name or ""):lower():match("%.(%w+)$")
        if ext and SCRIPT_EXT[ext] then return true end
      end
      return false
    end },
  { "DOUBLE_EXTENSION", 2.0, function(c)
      for _, a in ipairs(c.attachments) do
        if (a.name or ""):lower():match("%.%a%a%a?%.%a%a%a?$") and (a.name or ""):lower():match("%.(%w+)$") and DANGEROUS_EXT[(a.name or ""):lower():match("%.(%w+)$")] then return true end
      end
      return false
    end },
  { "SPF_FAIL", 3.0, function(c) return c.results.spf == "fail" end },
  { "SPF_SOFTFAIL", 1.5, function(c) return c.results.spf == "softfail" end },
  { "DKIM_FAIL", 2.0, function(c) return c.results.dkim == "fail" end },
  { "DKIM_PASS", -1.5, function(c) return c.results.dkim == "pass" end },
  { "SPF_PASS", -0.5, function(c) return c.results.spf == "pass" end },
  { "DMARC_FAIL", 2.0, function(c) return c.results.dmarc == "fail" end },
  { "DMARC_QUARANTINE", 4.0, function(c) return c.results.dmarcApply == "quarantine" end },
}

---------------------------------------------------------------------------------------------------------------------

local function listed(list, addr, domain, ip)
  for _, entry in ipairs(list or {}) do
    local e = tostring(entry):lower()
    if e == addr or e == domain or e == ip or domain:sub(-#e - 1) == "." .. e then return e end
  end
end

local function level(score)
  local n = math.max(0, math.min(20, math.floor(score)))
  return string.rep("*", n)
end

--- The administrator's lists: "allow" or "deny" (and which entry) for a message, or nil. Cheap, so it is asked first, before any DNS or signature work.
function Spam:listVerdict(ctx)
  local cfg = self.cfg
  local from = ctx.message:from()
  local addr, dom = from and from.addr or "", domainOf(from)
  local senderAddr = (ctx.sender or ""):lower()
  local senderDom = senderAddr:match("@([^@]+)$") or ""
  local ipStr = tostring(ctx.ip)
  if listed(cfg.allow, addr, dom, ipStr) or listed(cfg.allow, senderAddr, senderDom, ipStr) then return "allow" end
  local denied = listed(cfg.deny, addr, dom, ipStr) or listed(cfg.deny, senderAddr, senderDom, ipStr)
  if denied then return "deny", denied end
end

--- The filter for incoming mail from other servers.
function Spam:authFilter(ctx)
  local mail = self.mail
  if ctx.authUser or mail:mayRelay(ctx.ip) then ctx.results.trusted = true return nil end
  local cfg = self.cfg
  local which, entry = self:listVerdict(ctx)
  if which == "deny" then
    mail.stats.rejected = mail.stats.rejected + 1
    return { "reject", 550, "5.7.1 Mail from " .. entry .. " is not accepted here" }
  elseif which == "allow" then
    ctx.results.listed = "allow"
    return nil                                       -- no SPF/DKIM/DMARC work for senders the administrator vouches for
  end
  local res = ctx.results
  local senderDomain = (ctx.sender or ""):match("@([^@]+)$")
  local from = ctx.message:from()
  local fromDomain = domainOf(from)
  local parts = {}
  if cfg.spf ~= false then
    local r, why = spf.check(mail, ctx.ip, ctx.helo, ctx.sender)
    res.spf, res.spfWhy = r, why
    parts[#parts + 1] = ("spf=%s smtp.mailfrom=%s"):format(r, (ctx.sender ~= "" and ctx.sender) or ("postmaster@" .. tostring(ctx.helo)))
  end
  local dkimDomain
  if cfg.dkim_verify ~= false then
    local r, d, why = dkim.verify(mail, ctx.raw)
    res.dkim, res.dkimDomain, res.dkimWhy = r, d, why
    dkimDomain = d
    parts[#parts + 1] = r == "none" and "dkim=none" or ("dkim=%s header.d=%s"):format(r, tostring(d))
  end
  if cfg.dmarc ~= false and fromDomain ~= "" then
    local d = dmarc.check(mail, fromDomain, { result = res.spf, domain = senderDomain or ctx.helo }, { result = res.dkim, domain = dkimDomain })
    res.dmarc, res.dmarcWhy = d.result, d.reason
    if d.result == "fail" and d.apply then res.dmarcApply = d.policy end
    parts[#parts + 1] = ("dmarc=%s header.from=%s"):format(d.result, fromDomain)
    if d.result == "fail" and d.apply and d.policy == "reject" and cfg.dmarcReject ~= false then
      mail:note(("DMARC reject: %s claims %s"):format(tostring(ctx.ip), fromDomain))
      return { "reject", 550, "5.7.1 Rejected: the domain " .. fromDomain .. " asks that mail failing its SPF/DKIM checks is refused (DMARC)" }
    end
  end
  if #parts > 0 then ctx.add[#ctx.add + 1] = "Authentication-Results: " .. mail.hostname .. "; " .. table.concat(parts, "; ") end
  return nil
end

--- The scoring filter.
function Spam:scoreFilter(ctx)
  if ctx.results.trusted then return nil end
  local mail = self.mail
  local cfg = self.cfg
  local m = ctx.message
  local from = m:from()
  local ipStr = tostring(ctx.ip)
  local senderAddr = (ctx.sender or ""):lower()
  if ctx.results.listed == "allow" or self:listVerdict(ctx) == "allow" then
    ctx.add[#ctx.add + 1] = "X-Spam-Status: No, allowed by the administrator"
    return nil
  end
  local parts = m:parts()
  local c = { m = m, subject = m:subject(), text = m:text(), from = from, raw = ctx.raw, results = ctx.results, attachments = m:attachments(), htmlOnly = false }
  local hasPlain, hasHtml = false, false
  for _, p in ipairs(parts) do
    if p.type == "text/plain" then hasPlain = true elseif p.type == "text/html" then hasHtml = true end
  end
  c.htmlOnly = hasHtml and not hasPlain
  if c.htmlOnly then c.text = m:text() end
  local total, hits = 0, {}
  local function hit(name, points)
    total = total + points
    hits[#hits + 1] = ("%s=%.1f"):format(name, points)
  end
  for _, rule in ipairs(M.RULES) do
    local ok, r = pcall(rule[3], c)
    if ok and r then
      local points = type(r) == "number" and r or rule[2]
      if rule[2] < 0 then points = rule[2] end
      hit(rule[1], points)
    end
  end
  -- blocklists
  if cfg.dnsbl and #cfg.dnsbl > 0 and ctx.ip then
    for _, h in ipairs(dnsbl.check(mail, ctx.ip, cfg.dnsbl)) do hit("DNSBL_" .. h.zone:upper():gsub("[^%w]", "_"), h.score) end
  end
  if cfg.uribl and #cfg.uribl > 0 then
    for domain in c.text:gmatch("https?://([%w%.%-]+)") do
      for _, h in ipairs(dnsbl.checkDomain(mail, domain, cfg.uribl)) do hit("URIBL_" .. h.zone:upper():gsub("[^%w]", "_"), h.score) end
      break
    end
  end
  -- the learning filter
  if self.bayes then
    local p, why = self.bayes:classify(ctx.raw)
    ctx.results.bayes = p
    if p then
      if p >= 0.95 then hit("BAYES_SPAM", 5.0)
      elseif p >= 0.8 then hit("BAYES_LIKELY_SPAM", 2.5)
      elseif p <= 0.05 then hit("BAYES_HAM", -2.5)
      elseif p <= 0.2 then hit("BAYES_PROBABLY_HAM", -1.0) end
    end
  end
  total = math.floor(total * 10 + 0.5) / 10
  ctx.results.score = total
  local at = cfg.spamAt or M.SPAM_AT
  local verdict = total >= at and "Yes" or "No"
  ctx.add[#ctx.add + 1] = ("X-Spam-Status: %s, score=%.1f required=%.1f tests=%s"):format(verdict, total, at, #hits > 0 and table.concat(hits, ",") or "none")
  if total > 0 then ctx.add[#ctx.add + 1] = "X-Spam-Level: " .. level(total) end
  if total >= (cfg.rejectAt or M.REJECT_AT) then
    mail:note(("rejected spam from %s <%s> (score %.1f: %s)"):format(ipStr, senderAddr, total, table.concat(hits, ",")))
    return { "reject", 554, ("5.7.1 Message rejected as spam (score %.1f)"):format(total) }
  end
  if total >= at then return { "spam", table.concat(hits, ","), total } end
  return nil
end

--- Teach the learning filter. raw: a whole message; isSpam: true / false.
function Spam:learn(raw, isSpam)
  if not self.bayes then return nil, "the learning filter is switched off" end
  self.bayes:train(raw, isSpam)
  return self.bayes:save()
end

function Spam:unlearn(raw, wasSpam)
  if not self.bayes then return nil, "the learning filter is switched off" end
  self.bayes:untrain(raw, wasSpam)
  return self.bayes:save()
end

--- Judge a message the way the server would for a connection from ip (for the `mailctl spam test` command). Returns the verdict, and ctx with results and headers.
function Spam:test(raw, opts)
  opts = opts or {}
  local ctx = { ip = opts.ip or "192.0.2.1", helo = opts.helo or "unknown", sender = opts.sender or "", rcpts = {}, raw = msg.normalize(raw) }
  local m = msg.parse(ctx.raw)
  if not opts.sender then
    local f = m:from()
    ctx.sender = f and f.addr or ""
  end
  local verdict = self.mail:runFilters(ctx)
  return verdict, ctx
end

---------------------------------------------------------------------------------------------------------------------
-- DKIM keys
---------------------------------------------------------------------------------------------------------------------

--- Make a new signing key; the secret goes into path (base64, one line), and the DNS record to publish is returned.
function M.makeDkimKey(path)
  local seed = require("tsr.crypto").rand.bytes(32)
  vfs.mkdirp(path:match("^(.*)/[^/]*$") or "/")
  local ok, err = vfs.writeFile(path, hash.base64Encode(seed) .. "\n", false)
  if not ok then return nil, err end
  return dkim.dnsRecord(seed), seed
end

function M.loadDkimKey(path)
  local text = vfs.readFile(path, false)
  if not text then return nil, "no key at " .. path end
  local seed = hash.base64Decode((text:gsub("%s", "")))
  if not seed or #seed ~= 32 then return nil, "the key file is damaged" end
  return seed
end

---------------------------------------------------------------------------------------------------------------------

--- Hang the anti-spam checks on a mail system. Returns the control object (S.bayes, S.greylist, S:learn, S:test).
function M.install(mail, cfg)
  cfg = cfg or {}
  local self = setmetatable({ mail = mail, cfg = cfg }, Spam)
  if cfg.bayes ~= false then self.bayes = bayes.new(type(cfg.bayes) == "string" and cfg.bayes or nil, { maxTokens = cfg.bayesTokens }) end
  mail:addFilter("auth", function(ctx) return self:authFilter(ctx) end, 10)
  mail:addFilter("score", function(ctx) return self:scoreFilter(ctx) end, 50)
  if cfg.greylist then
    self.greylist = greylist.new(mail, type(cfg.greylist) == "table" and cfg.greylist or {})
    mail.policy = mail.policy or {}
    mail.policy.rcpt = self.greylist:hook()
  end
  -- outgoing signatures
  if cfg.dkim and next(cfg.dkim) then
    mail.signOutbound = function(m, raw, sender)
      local domain = (sender or ""):match("@([^@]+)$")
      if not domain then
        local f = msg.parse(raw):from()
        domain = f and f.domain
      end
      local key = domain and cfg.dkim[domain:lower()]
      if not key then return raw end
      local seed = key.seed or (key.keyFile and M.loadDkimKey(key.keyFile))
      if not seed then m:note("DKIM: no key for " .. domain) return raw end
      local signed = dkim.sign(raw, { domain = domain:lower(), selector = key.selector or "mail", seed = seed, now = math.floor(m:now()) })
      return signed or raw
    end
  end
  mail.spam = self
  return self
end

M.spf, M.dkim, M.dmarc, M.dnsbl, M.bayes, M.greylist = spf, dkim, dmarc, dnsbl, bayes, greylist

return M
