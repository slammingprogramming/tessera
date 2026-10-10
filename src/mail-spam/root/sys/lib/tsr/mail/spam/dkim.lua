-- SPDX-License-Identifier: AGPL-3.0-or-later
-- DKIM (RFC 6376) with Ed25519 (RFC 8463): a server signs the headers and body of the mail it sends with a key only it holds, and publishes the public key in DNS
-- (selector._domainkey.domain, TXT "v=DKIM1; k=ed25519; p=<base64>"). The receiver checks the signature, so forged "From" domains and mail altered on the way show up.
-- Only the algorithm a=ed25519-sha256 and the canonicalisation relaxed/relaxed are produced; simple canonicalisation is understood when verifying; RSA signatures
-- are reported as "none" (the game has no RSA).
--   local signed = dkim.sign(raw, { domain = "example.lan", selector = "mail1", seed = secretKey32Bytes, now = 1234567890 })
--   local result, domain, why = dkim.verify(mail, signed)
local hash = require("tsr.hash")
local ed = require("tsr.crypto.ed25519")

local M = {}

M.DEFAULT_SIGNED = { "from", "to", "cc", "subject", "date", "message-id", "reply-to", "in-reply-to", "references", "mime-version", "content-type", "content-transfer-encoding" }

local function sha256raw(s) return hash.fromHex(hash.sha256(s)) end

--- Split a message into its header block and body. Returns a list of header fields { name, raw } (raw keeps folding, no trailing CRLF) and the body.
local function split(raw)
  local headEnd = raw:find("\r\n\r\n", 1, true)
  local head, body
  if headEnd then head, body = raw:sub(1, headEnd + 1), raw:sub(headEnd + 4) else head, body = raw .. "\r\n", "" end
  local fields = {}
  for line in head:gmatch("(.-)\r\n") do
    if line:match("^[ \t]") and #fields > 0 then fields[#fields].raw = fields[#fields].raw .. "\r\n" .. line
    else
      local name = line:match("^([^:%s]+)%s*:")
      if name then fields[#fields + 1] = { name = name:lower(), raw = line } end
    end
  end
  return fields, body
end

local function relaxedHeader(field)
  local name, value = field.raw:match("^([^:]+):(.*)$")
  value = (value or ""):gsub("\r\n", ""):gsub("[ \t]+", " "):gsub("^ ", ""):gsub(" $", "")
  return name:lower():gsub("[ \t]+$", "") .. ":" .. value
end

local function simpleHeader(field) return field.raw end

local function relaxedBody(body)
  local lines = {}
  for line in (body .. (body:sub(-2) == "\r\n" and "" or "\r\n")):gmatch("(.-)\r\n") do
    lines[#lines + 1] = (line:gsub("[ \t]+", " "):gsub(" $", ""))
  end
  while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
  if #lines == 0 then return "" end
  return table.concat(lines, "\r\n") .. "\r\n"
end

local function simpleBody(body)
  local text = body
  while text:sub(-4) == "\r\n\r\n" do text = text:sub(1, -3) end
  if text == "" or text == "\r\n" then return "\r\n" end
  if text:sub(-2) ~= "\r\n" then text = text .. "\r\n" end
  return text
end

local function parseTags(value)
  local tags = {}
  for k, v in value:gsub("[ \t\r\n]+", ""):gmatch("([%a%d_]+)=([^;]*)") do tags[k] = v end
  return tags
end

--- The headers named in h=, taken from the bottom up (a name listed twice takes the next one up), in the order of the list.
local function selectHeaders(fields, names)
  local used, out = {}, {}
  for _, name in ipairs(names) do
    name = name:lower()
    for i = #fields, 1, -1 do
      if fields[i].name == name and not used[i] then used[i] = true out[#out + 1] = fields[i] break end
    end
  end
  return out
end

--- Fold the signature header at about 76 columns after a ";" (folding does not change the signed value: relaxed canonicalisation removes it).
local function foldSignature(value)
  local items = {}
  for tag in value:gmatch("[^;]+") do items[#items + 1] = (tag:gsub("^%s+", "")) end
  local out, line = {}, "DKIM-Signature: " .. items[1]
  for i = 2, #items do
    line = line .. ";"
    if #line + 1 + #items[i] > 76 then out[#out + 1] = line line = "\t" .. items[i]
    else line = line .. " " .. items[i] end
  end
  out[#out + 1] = line
  return table.concat(out, "\r\n")
end

--- The TXT record (without quotes) for the public key that belongs to seed.
function M.dnsRecord(seed)
  return "v=DKIM1; k=ed25519; p=" .. hash.base64Encode(ed.publicKey(seed))
end

--- Add a DKIM-Signature header. opts: domain, selector, seed (32 bytes), headers (names to sign, default M.DEFAULT_SIGNED), now (seconds), expires (seconds from now).
function M.sign(raw, opts)
  local fields, body = split(raw)
  local names = {}
  local want = opts.headers or M.DEFAULT_SIGNED
  local present = {}
  for _, f in ipairs(fields) do present[f.name] = (present[f.name] or 0) + 1 end
  for _, n in ipairs(want) do
    local count = present[n:lower()] or 0
    for _ = 1, count do names[#names + 1] = n:lower() end
    present[n:lower()] = nil
  end
  local hasFrom = false
  for _, n in ipairs(names) do if n == "from" then hasFrom = true end end
  if not hasFrom then return nil, "a message without a From header cannot be signed" end
  local bh = hash.base64Encode(sha256raw(relaxedBody(body)))
  local tags = ("v=1; a=ed25519-sha256; c=relaxed/relaxed; d=%s; s=%s; t=%.0f;"):format(opts.domain, opts.selector, opts.now or 0)
  if opts.expires then tags = tags .. (" x=%.0f;"):format((opts.now or 0) + opts.expires) end
  tags = tags .. " h=" .. table.concat(names, ":") .. "; bh=" .. bh .. "; b="
  local data = {}
  for _, f in ipairs(selectHeaders(fields, names)) do data[#data + 1] = relaxedHeader(f) .. "\r\n" end
  data[#data + 1] = relaxedHeader({ raw = "DKIM-Signature: " .. tags })
  local digest = sha256raw(table.concat(data))
  local sig = ed.sign(opts.seed, digest)
  local header = foldSignature(tags .. hash.base64Encode(sig))
  return header .. "\r\n" .. raw
end

local function verifyOne(mail, fields, body, sigField)
  local value = sigField.raw:match("^[^:]+:(.*)$")
  local tags = parseTags(value)
  if tags.v ~= "1" then return "permerror", nil, "unknown DKIM version" end
  local algo = (tags.a or ""):lower()
  if algo ~= "ed25519-sha256" then return "none", tags.d, "unsupported algorithm " .. algo end
  if not (tags.d and tags.s and tags.h and tags.bh and tags.b) then return "permerror", tags.d, "a required tag is missing" end
  if not (tags.h:lower():find("from", 1, true)) then return "permerror", tags.d, "From is not signed" end
  local now = mail:now()
  if tags.x and tonumber(tags.x) and now > tonumber(tags.x) then return "fail", tags.d, "the signature has expired" end
  local canon = (tags.c or "simple/simple"):lower()
  local hc, bc = canon:match("^(%a+)/?(%a*)$")
  bc = bc ~= "" and bc or "simple"
  local headerCanon = hc == "relaxed" and relaxedHeader or simpleHeader
  local bodyCanon = bc == "relaxed" and relaxedBody or simpleBody
  local canonBody = bodyCanon(body)
  if tags.l and tonumber(tags.l) then canonBody = canonBody:sub(1, tonumber(tags.l)) end
  local bh = hash.base64Encode(sha256raw(canonBody))
  if bh ~= tags.bh then return "fail", tags.d, "the body hash does not match: the message was changed" end
  local txts, why = mail:dnsTxt(tags.s .. "._domainkey." .. tags.d)
  if not txts then return "temperror", tags.d, "key lookup failed: " .. tostring(why) end
  local key
  for _, t in ipairs(txts) do
    local k = parseTags(t)
    if k.p and (k.v == nil or k.v == "DKIM1") and (k.k or "rsa") == "ed25519" then key = hash.base64Decode(k.p) break end
  end
  if not key or #key ~= 32 then return "permerror", tags.d, "no usable Ed25519 key published at " .. tags.s .. "._domainkey." .. tags.d end
  local names = {}
  for n in tags.h:gmatch("[^:]+") do names[#names + 1] = n end
  local data = {}
  for _, f in ipairs(selectHeaders(fields, names)) do
    if f ~= sigField then data[#data + 1] = headerCanon(f) .. "\r\n" end
  end
  -- the signature header itself, with an empty b=
  local stripped = sigField.raw:gsub("(;[ \t\r\n]*b[ \t\r\n]*=)[^;]*", "%1")
  if not stripped:find("b=", 1, true) then stripped = sigField.raw:gsub("(%s)b[ \t\r\n]*=[^;]*", "%1b=") end
  data[#data + 1] = headerCanon({ raw = stripped })
  local digest = sha256raw(table.concat(data))
  local sig = hash.base64Decode(tags.b)
  if not sig or #sig ~= 64 then return "fail", tags.d, "the signature is not valid base64 of 64 bytes" end
  if ed.verify(key, digest, sig) then return "pass", tags.d, "signature verified (" .. tags.s .. "._domainkey." .. tags.d .. ")" end
  return "fail", tags.d, "the signature does not match"
end

--- Verify the DKIM-Signature headers of a message. Returns result ("pass" if any signature is good, "fail", "none" without signature,
--- "temperror", "permerror"), the signing domain of the deciding signature, and a reason. All = list of every outcome { result, domain, why }.
function M.verify(mail, raw)
  local fields, body = split(raw)
  local all = {}
  for _, f in ipairs(fields) do
    if f.name == "dkim-signature" then
      local r, d, w = verifyOne(mail, fields, body, f)
      all[#all + 1] = { result = r, domain = d, why = w }
      if r == "pass" then return "pass", d, w, all end
      if #all >= 2 then break end            -- each check is an Ed25519 verification and a DNS lookup: do not let one message ask for dozens
    end
  end
  if #all == 0 then return "none", nil, "no DKIM signature", all end
  local pick = all[1]
  for _, a in ipairs(all) do if a.result == "fail" then pick = a break end end
  return pick.result, pick.domain, pick.why, all
end

return M
