-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Internet messages (RFC 5322) and MIME (RFC 2045-2049): headers (folding, encoded words), addresses, multipart bodies with attachments, base64 and
-- quoted-printable, building new messages. Messages are kept as text with CRLF line ends, exactly as they travel between mail servers.
local hash = require("tsr.hash")

local M = {}

M.CRLF = "\r\n"

local function crlf(s) return (s:gsub("\r?\n", "\r\n")) end
M.normalize = crlf

---------------------------------------------------------------------------------------------------------------------
-- Addresses
---------------------------------------------------------------------------------------------------------------------

--- "Alice Example <alice@example.lan>", "alice@example.lan", "<a@b>" -> { name, addr, localPart, domain } or nil.
function M.parseAddress(text)
  text = tostring(text or ""):gsub("%([^)]*%)", ""):gsub("^%s+", ""):gsub("%s+$", "")
  local name, addr = text:match('^"?(.-)"?%s*<([^<>]*)>$')
  if not addr then addr = text:match("^([^%s<>,;]+@[^%s<>,;]+)$") end
  if not addr then return nil end
  addr = addr:gsub("^%s+", ""):gsub("%s+$", "")
  local localPart, domain = addr:match("^(.+)@([^@]+)$")
  if not localPart then
    if addr == "" then return { name = name or "", addr = "", localPart = "", domain = "" } end      -- the null address <> of bounces
    return nil
  end
  return { name = (name or ""):gsub("^%s+", ""):gsub("%s+$", ""), addr = localPart .. "@" .. domain:lower(), localPart = localPart, domain = domain:lower() }
end

--- A header value with several addresses -> list of parsed addresses (commas inside quotes and angle brackets do not split).
function M.parseAddressList(text)
  local out = {}
  local depth, quote, cur = 0, false, {}
  local function flush()
    local item = table.concat(cur):gsub("^%s+", ""):gsub("%s+$", "")
    cur = {}
    if item ~= "" then local a = M.parseAddress(item) if a then out[#out + 1] = a end end
  end
  for ch in tostring(text or ""):gmatch(".") do
    if ch == '"' then quote = not quote cur[#cur + 1] = ch
    elseif quote then cur[#cur + 1] = ch
    elseif ch == "<" then depth = depth + 1 cur[#cur + 1] = ch
    elseif ch == ">" then depth = math.max(0, depth - 1) cur[#cur + 1] = ch
    elseif (ch == "," or ch == ";") and depth == 0 then flush()
    else cur[#cur + 1] = ch end
  end
  flush()
  return out
end

function M.formatAddress(a)
  if a.name and a.name ~= "" then
    local name = a.name:find('[%(%)<>@,;:\\".%[%]]') and ('"' .. a.name:gsub('(["\\])', "\\%1") .. '"') or a.name
    return name .. " <" .. a.addr .. ">"
  end
  return a.addr
end

---------------------------------------------------------------------------------------------------------------------
-- Encodings
---------------------------------------------------------------------------------------------------------------------

function M.qpDecode(s)
  s = s:gsub("=\r?\n", "")
  return (s:gsub("=(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function M.qpEncode(s)
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\r?\n") do
    local e = line:gsub("[^\32-\60\62-\126\9]", function(c) return ("=%02X"):format(c:byte()) end)
    -- soft line breaks at 75 characters
    while #e > 75 do
      local cut = 75
      if e:sub(cut - 1, cut - 1) == "=" then cut = cut - 2 elseif e:sub(cut, cut) == "=" then cut = cut - 1 end
      out[#out + 1] = e:sub(1, cut) .. "="
      e = e:sub(cut + 1)
    end
    out[#out + 1] = e
  end
  if out[#out] == "" then out[#out] = nil end
  return table.concat(out, "\r\n")
end

local function wrap76(b64)
  local lines = {}
  for i = 1, #b64, 76 do lines[#lines + 1] = b64:sub(i, i + 75) end
  return table.concat(lines, "\r\n")
end

--- Encoded words in headers (RFC 2047): =?UTF-8?B?...?= and =?...?Q?...?= are decoded to plain text (non-ASCII characters become "?").
function M.decodeWords(s)
  return (tostring(s):gsub("=%?[%w%-]+%?([BbQq])%?([^?]*)%?=", function(enc, data)
    local text
    if enc:lower() == "b" then text = hash.base64Decode(data) or "" else text = M.qpDecode(data:gsub("_", " ")) end
    return (text:gsub("[\128-\255]", "?"))
  end))
end

M.MAX_DEPTH = 8
M.MAX_PARTS = 200

function M.encodeWord(s)
  s = (tostring(s):gsub("[\r\n]+", " "))             -- a header value is one line: line breaks would start new headers
  if not s:find("[\128-\255]") then return s end
  return "=?UTF-8?B?" .. hash.base64Encode(s) .. "?="
end

---------------------------------------------------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------------------------------------------------

--- Split text into the header block and the body at the first empty line. Returns headers (list of { name, value } in order) and body.
function M.parseHeaders(text)
  local head, body = text:match("^(.-)\r?\n\r?\n(.*)$")
  if not head then head, body = text, "" end
  local headers, last = {}, nil
  for line in (head .. "\n"):gmatch("(.-)\r?\n") do
    if line:match("^[ \t]") and last then
      last.value = last.value .. " " .. line:gsub("^%s+", "")
    else
      local name, value = line:match("^([^%s:]+):%s*(.*)$")
      if name then
        last = { name = name, value = value, raw = line }
        headers[#headers + 1] = last
      end
    end
  end
  return headers, body
end

local Message = {}
Message.__index = Message

--- The first header of that name (case-insensitive), decoded; or nil.
function Message:header(name)
  name = name:lower()
  for _, h in ipairs(self.headers) do if h.name:lower() == name then return h.value end end
end

function Message:headerAll(name)
  name = name:lower()
  local out = {}
  for _, h in ipairs(self.headers) do if h.name:lower() == name then out[#out + 1] = h.value end end
  return out
end

function Message:subject() return M.decodeWords(self:header("subject") or "") end

function Message:from() return M.parseAddress(M.decodeWords(self:header("from") or "")) end

function Message:addresses(name) return M.parseAddressList(M.decodeWords(self:header(name) or "")) end

--- "text/plain; charset=us-ascii; name=x" -> "text/plain", { charset = "us-ascii", name = "x" }
local function parseContentType(value)
  value = value or "text/plain"
  local ctype = value:match("^%s*([^;%s]+)") or "text/plain"
  local params = {}
  for k, v in value:gmatch(';%s*([%w%-]+)%s*=%s*"?([^";]*)"?') do params[k:lower()] = v end
  return ctype:lower(), params
end
M.parseContentType = parseContentType

local function decodeTransfer(body, encoding)
  encoding = (encoding or "7bit"):lower()
  if encoding == "base64" then return hash.base64Decode((body:gsub("%s+", ""))) or "" end
  if encoding == "quoted-printable" then return M.qpDecode(body) end
  return body
end

--- Parse a complete message. Returns a message object: headers, body (raw), :header(), :parts() ...
function M.parse(text)
  local headers, body = M.parseHeaders(text)
  local self = setmetatable({ headers = headers, body = body, raw = text }, Message)
  return self
end

--- The parts of a message as a flat list: { { type, name, data, disposition } }; a message without MIME structure is a single text/plain part.
function Message:parts()
  if self._parts then return self._parts end
  local ctype, params = parseContentType(self:header("content-type"))
  local out = {}
  -- limits against messages built to exhaust the computer: nesting depth and number of parts
  local function walk(ct, pr, headers, body, depth)
    if #out >= M.MAX_PARTS then return end
    if ct:match("^multipart/") and pr.boundary and depth < M.MAX_DEPTH then
      local b = pr.boundary
      local pieces = {}
      local pos = 1
      local marker = "--" .. b
      local startAt = body:find(marker, 1, true)
      while startAt do
        local lineEnd = body:find("\n", startAt, true)
        if not lineEnd then break end
        local afterMarker = body:sub(startAt + #marker, startAt + #marker + 1)
        if afterMarker == "--" then break end
        local nextAt = body:find("\r?\n" .. marker:gsub("%p", "%%%0"), lineEnd)
        if not nextAt then pieces[#pieces + 1] = body:sub(lineEnd + 1) break end
        pieces[#pieces + 1] = body:sub(lineEnd + 1, nextAt - 1)
        startAt = body:find(marker, nextAt, true)
      end
      for _, piece in ipairs(pieces) do
        local h, pb = M.parseHeaders(piece)
        local sub = setmetatable({ headers = h }, Message)
        local ct2, pr2 = parseContentType(sub:header("content-type"))
        walk(ct2, pr2, sub, pb, depth + 1)
      end
    else
      local disp = headers.header and headers:header("content-disposition") or nil
      local name = pr.name
      if disp then name = name or disp:match('filename%s*=%s*"?([^";]+)"?') end
      local enc = headers.header and headers:header("content-transfer-encoding")
      out[#out + 1] = { type = ct, name = name and M.decodeWords(name), data = decodeTransfer(body, enc), disposition = disp and disp:match("^%s*([%w%-]+)") or nil, charset = pr.charset }
    end
  end
  walk(ctype, params, self, self.body, 1)
  self._parts = out
  return out
end

--- The text of the message: the first text/plain part (or text/html with tags removed), line ends as LF.
function Message:text()
  for _, p in ipairs(self:parts()) do
    if p.type == "text/plain" and p.disposition ~= "attachment" then return (p.data:gsub("\r\n", "\n")) end
  end
  for _, p in ipairs(self:parts()) do
    if p.type == "text/html" then return ((p.data:gsub("<[^>]*>", ""):gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("\r\n", "\n"))) end
  end
  return ""
end

function Message:attachments()
  local out = {}
  for _, p in ipairs(self:parts()) do
    if p.disposition == "attachment" or (p.name and not p.type:match("^text/") ) or (p.name and p.disposition == "inline" and not p.type:match("^text/plain")) then out[#out + 1] = p end
  end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------------------------------------------------

local function rfcDate(ms)
  local sec = math.floor((ms or (os.epoch and os.epoch("utc") or 0)) / 1000)
  return os.date and os.date("!%a, %d %b %Y %H:%M:%S +0000", sec) or "Thu, 01 Jan 1970 00:00:00 +0000"
end
M.date = rfcDate

--- A Message-ID of the form <time.random@host>.
function M.newId(host)
  local r = require("tsr.crypto").rand.bytes(6)
  return ("<%.0f.%s@%s>"):format(os.epoch and os.epoch("utc") or 0, require("tsr.crypto").toHex(r), host or "localhost")
end

--- Build a message. m: from (address text), to / cc (list of address texts or one string), subject, body (text), attachments = { { name, data, type } },
--- headers = { Name = value }, date (ms), messageId, host (for the Message-ID).
function M.build(m)
  local function oneLine(v) return (tostring(v):gsub("[\r\n]+", " ")) end
  local function list(v) if type(v) == "table" then v = table.concat(v, ", ") end return oneLine(v) end
  local h = {}
  h[#h + 1] = "From: " .. M.encodeWord(m.from)
  if m.to then h[#h + 1] = "To: " .. list(m.to) end
  if m.cc then h[#h + 1] = "Cc: " .. list(m.cc) end
  h[#h + 1] = "Subject: " .. M.encodeWord(m.subject or "")
  h[#h + 1] = "Date: " .. rfcDate(m.date)
  h[#h + 1] = "Message-ID: " .. (m.messageId or M.newId(m.host))
  h[#h + 1] = "MIME-Version: 1.0"
  for k, v in pairs(m.headers or {}) do h[#h + 1] = oneLine(k) .. ": " .. oneLine(v) end
  local body = crlf(m.body or "")
  if body ~= "" and body:sub(-2) ~= "\r\n" then body = body .. "\r\n" end
  local text
  if m.attachments and #m.attachments > 0 then
    local boundary = "=_tsr_" .. require("tsr.crypto").toHex(require("tsr.crypto").rand.bytes(8))
    h[#h + 1] = 'Content-Type: multipart/mixed; boundary="' .. boundary .. '"'
    local parts = { "--" .. boundary, "Content-Type: text/plain; charset=us-ascii", "Content-Transfer-Encoding: 7bit", "", body }
    for _, a in ipairs(m.attachments) do
      parts[#parts + 1] = "--" .. boundary
      parts[#parts + 1] = ("Content-Type: %s; name=\"%s\""):format(a.type or "application/octet-stream", a.name)
      parts[#parts + 1] = ("Content-Disposition: attachment; filename=\"%s\""):format(a.name)
      parts[#parts + 1] = "Content-Transfer-Encoding: base64"
      parts[#parts + 1] = ""
      parts[#parts + 1] = wrap76(hash.base64Encode(a.data))
    end
    parts[#parts + 1] = "--" .. boundary .. "--"
    text = table.concat(h, "\r\n") .. "\r\n\r\n" .. table.concat(parts, "\r\n") .. "\r\n"
  else
    h[#h + 1] = "Content-Type: text/plain; charset=us-ascii"
    h[#h + 1] = "Content-Transfer-Encoding: 7bit"
    text = table.concat(h, "\r\n") .. "\r\n\r\n" .. body
  end
  return text
end

--- Put header lines in front of a message (Received, X-Spam-..., Authentication-Results).
function M.prepend(text, lines)
  if type(lines) == "string" then lines = { lines } end
  return table.concat(lines, "\r\n") .. "\r\n" .. text
end

--- Dot-stuffing for SMTP DATA (RFC 5321 4.5.2).
function M.dotStuff(text)
  text = crlf(text)
  if text:sub(-2) ~= "\r\n" then text = text .. "\r\n" end
  return (text:gsub("\r\n%.", "\r\n.."):gsub("^%.", ".."))
end

function M.dotUnstuff(lines)
  for i, l in ipairs(lines) do if l:sub(1, 2) == ".." then lines[i] = l:sub(2) end end
  return lines
end

return M
