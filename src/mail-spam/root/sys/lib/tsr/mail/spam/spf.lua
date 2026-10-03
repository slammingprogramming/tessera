-- SPDX-License-Identifier: AGPL-3.0-or-later
-- SPF (RFC 7208): which servers may send mail for a domain. The policy is a TXT record "v=spf1 ..." on the domain. Supported: all, ip4, a, mx, include,
-- redirect, exists and the qualifiers + - ~ ?; the macros %{i} %{s} %{l} %{o} %{d} %{h} (no transformers); the limit of 10 DNS-querying terms. ip6 and ptr are
-- parsed and ignored (the game's network is IPv4).
--   local result, why = spf.check(mail, "10.0.0.5", "mail.example.lan", "alice@example.lan")
-- result: "pass", "fail", "softfail", "neutral", "none", "temperror", "permerror".
local B = require("tsr.inet.bytes")

local M = {}

M.MAX_LOOKUPS = 10

local QUAL = { ["+"] = "pass", ["-"] = "fail", ["~"] = "softfail", ["?"] = "neutral" }

local function expand(spec, ctx)
  return (spec:gsub("%%{(%a)[^}]*}", function(c)
    c = c:lower()
    if c == "i" then return B.ipStr(ctx.ip) end
    if c == "s" then return ctx.sender end
    if c == "l" then return ctx.local_ end
    if c == "o" then return ctx.senderDomain end
    if c == "d" then return ctx.domain end
    if c == "h" then return ctx.helo end
    return ""
  end):gsub("%%%%", "%%"):gsub("%%_", " "):gsub("%%%-", "%%20"))
end

local function parseCidr(spec, default)
  local ip, bits = spec:match("^([^/]+)/(%d+)$")
  if ip then return ip, tonumber(bits) end
  return spec, default
end

local function findRecord(mail, domain)
  local txts, why = mail:dnsTxt(domain)
  if not txts then return nil, "temperror", why end
  local found
  for _, t in ipairs(txts) do
    local lower = t:lower()
    if lower == "v=spf1" or lower:match("^v=spf1%s") then
      if found then return nil, "permerror", "more than one SPF record" end
      found = t
    end
  end
  if not found then return nil, "none" end
  return found
end

local function matchAddresses(ctx, addrs, bits)
  for _, a in ipairs(addrs) do
    local n = B.ip(a)
    if n and B.inNet(ctx.ip, n, bits or 32) then return true end
  end
  return false
end

local check

--- Evaluate the policy of one domain. Returns a result and a reason; "match" is a pseudo result for "this mechanism matched" in include.
local function evaluate(mail, ctx, domain, depth)
  if depth > 10 then return "permerror", "too many nested includes" end
  local record, res, why = findRecord(mail, domain)
  if not record then return res, why end
  ctx.domain = domain
  local terms = {}
  for t in record:gmatch("%S+") do terms[#terms + 1] = t end
  local redirect
  for i = 2, #terms do
    local term = terms[i]
    local qual, body = term:match("^([%+%-~%?]?)(.+)$")
    local result = QUAL[qual] or "pass"
    local lname = body:lower():match("^(%a[%a%d]*)")
    local value = body:match("^%a[%a%d]*[:=](.*)$")
    local cidrOnly = body:match("^%a[%a%d]*(/%d+)$")
    local function count()
      ctx.lookups = ctx.lookups + 1
      return ctx.lookups <= M.MAX_LOOKUPS
    end
    if lname == "all" then return result, "all"
    elseif lname == "ip4" then
      local ip, bits = parseCidr(value or "", 32)
      local n = B.ip(ip)
      if not n then return "permerror", "bad ip4 term " .. term end
      if B.inNet(ctx.ip, n, bits) then return result, "ip4:" .. value end
    elseif lname == "ip6" or lname == "ptr" then
      -- not used in this game
    elseif lname == "a" or lname == "mx" then
      if not count() then return "permerror", "too many DNS lookups" end
      local target, bits = domain, 32
      if value then target, bits = parseCidr(expand(value, ctx), 32)
      elseif cidrOnly then bits = tonumber(cidrOnly:sub(2)) end
      local addrs
      if lname == "a" then
        local why2
        addrs, why2 = mail:dnsA(target)
        if not addrs then return "temperror", why2 end
      else
        local mx, why2 = mail:dnsMx(target)
        if not mx then return "temperror", why2 end
        addrs = {}
        for k, m in ipairs(mx) do
          if k > 10 then break end
          local a = mail:dnsA(m.exchange)
          for _, x in ipairs(a or {}) do addrs[#addrs + 1] = x end
        end
      end
      if matchAddresses(ctx, addrs, bits) then return result, lname end
    elseif lname == "include" then
      if not count() then return "permerror", "too many DNS lookups" end
      local sub, subWhy = evaluate(mail, ctx, expand(value or "", ctx), depth + 1)
      ctx.domain = domain
      if sub == "pass" then return result, "include:" .. tostring(value) end
      if sub == "temperror" or sub == "permerror" then return sub, subWhy end
      if sub == "none" then return "permerror", "include of a domain without an SPF record" end
    elseif lname == "exists" then
      if not count() then return "permerror", "too many DNS lookups" end
      local addrs, why2 = mail:dnsA(expand(value or "", ctx))
      if not addrs then return "temperror", why2 end
      if #addrs > 0 then return result, "exists" end
    elseif lname == "redirect" and term:find("=", 1, true) then
      redirect = expand(value or "", ctx)
    elseif lname == "exp" then
      -- explanation strings are not used
    else
      return "permerror", "unknown term " .. term
    end
  end
  if redirect then
    if not (ctx.lookups < M.MAX_LOOKUPS) then return "permerror", "too many DNS lookups" end
    ctx.lookups = ctx.lookups + 1
    local sub, subWhy = evaluate(mail, ctx, redirect, depth + 1)
    if sub == "none" then return "permerror", "redirect to a domain without an SPF record" end
    return sub, subWhy
  end
  return "neutral", "no mechanism matched"
end

--- Check one connection. sender is the envelope sender ("" for a bounce: the HELO name is checked instead).
function M.check(mail, ip, helo, sender)
  local n = type(ip) == "number" and ip or B.ip(ip)
  if not n then return "permerror", "bad client address" end
  local domain, localPart = nil, "postmaster"
  sender = sender or ""
  if sender == "" then
    domain = helo or ""
    sender = "postmaster@" .. domain
  else
    localPart, domain = sender:match("^(.-)@([^@]+)$")
    if not domain then domain, localPart = helo or "", "postmaster" sender = localPart .. "@" .. domain end
  end
  if domain == "" then return "none", "no domain to check" end
  local ctx = { ip = n, helo = helo or "", sender = sender, local_ = localPart, senderDomain = domain, domain = domain, lookups = 0 }
  local result, why = evaluate(mail, ctx, domain, 0)
  return result, why
end

return M
