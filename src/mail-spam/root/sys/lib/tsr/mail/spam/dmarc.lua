-- SPDX-License-Identifier: AGPL-3.0-or-later
-- DMARC (RFC 7489), the part that matters for a receiver: the domain owner publishes in DNS (_dmarc.domain TXT "v=DMARC1; p=reject; ...") what to do with mail that
-- claims to be from the domain but neither SPF nor DKIM vouches for *that* domain ("alignment"). The "organizational domain" is taken to be the last two labels of a
-- name, which is right for the names players choose (mail.example.lan -> example.lan) without a public-suffix list.
--   local r = dmarc.check(mail, "example.lan", { result = "pass", domain = "example.lan" }, { result = "none" })
-- Returns { result = "pass" | "fail" | "none" | "temperror", policy = "none" | "quarantine" | "reject", apply = bool, reason = "...", record = "..." }.
local crypto = require("tsr.crypto")

local M = {}

function M.orgDomain(domain)
  domain = tostring(domain):lower():gsub("%.$", "")
  local labels = {}
  for l in domain:gmatch("[^.]+") do labels[#labels + 1] = l end
  if #labels <= 2 then return domain end
  return labels[#labels - 1] .. "." .. labels[#labels]
end

local function aligned(a, b, strict)
  if not a or not b then return false end
  a, b = a:lower(), b:lower()
  if strict then return a == b end
  return M.orgDomain(a) == M.orgDomain(b)
end

local function parseTags(text)
  local tags = {}
  for k, v in text:gsub("%s+", ""):gmatch("([%a]+)=([^;]*)") do tags[k:lower()] = v end
  return tags
end

local function findPolicy(mail, name)
  local txts, why = mail:dnsTxt("_dmarc." .. name)
  if not txts then return nil, why end
  for _, t in ipairs(txts) do
    if t:lower():gsub("%s", ""):match("^v=dmarc1;") or t:lower():gsub("%s", "") == "v=dmarc1" then return t end
  end
  return false
end

--- fromDomain: the domain of the From header. spf = { result, domain } (domain that was checked), dkim = { result, domain } (domain of the deciding signature).
function M.check(mail, fromDomain, spf, dkim)
  fromDomain = tostring(fromDomain or ""):lower()
  if fromDomain == "" then return { result = "none", policy = "none", apply = false, reason = "no From domain" } end
  local record, why = findPolicy(mail, fromDomain)
  local sub = false
  if record == nil then return { result = "temperror", policy = "none", apply = false, reason = "DMARC lookup failed: " .. tostring(why) } end
  if record == false then
    local org = M.orgDomain(fromDomain)
    if org ~= fromDomain then
      record, why = findPolicy(mail, org)
      sub = true
      if record == nil then return { result = "temperror", policy = "none", apply = false, reason = "DMARC lookup failed: " .. tostring(why) } end
    end
    if not record then return { result = "none", policy = "none", apply = false, reason = "the domain publishes no DMARC policy" } end
  end
  local tags = parseTags(record)
  local policy = (sub and tags.sp or tags.p or "none"):lower()
  if policy ~= "none" and policy ~= "quarantine" and policy ~= "reject" then policy = "none" end
  local spfOk = spf and spf.result == "pass" and aligned(spf.domain, fromDomain, tags.aspf == "s")
  local dkimOk = dkim and dkim.result == "pass" and aligned(dkim.domain, fromDomain, tags.adkim == "s")
  if spfOk or dkimOk then
    return { result = "pass", policy = policy, apply = false, reason = spfOk and "SPF aligned" or "DKIM aligned", record = record }
  end
  local apply = policy ~= "none"
  local pct = tonumber(tags.pct)
  if apply and pct and pct < 100 then apply = crypto.rand.bytes(1):byte() * 100 / 256 < pct end
  return { result = "fail", policy = policy, apply = apply, reason = "neither SPF nor DKIM is aligned with " .. fromDomain, record = record }
end

return M
