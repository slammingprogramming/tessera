-- SPDX-License-Identifier: AGPL-3.0-or-later
-- BGP-4 messages (RFC 4271): the 19-byte header, OPEN, UPDATE with its path attributes (ORIGIN, AS_PATH, NEXT_HOP, MED, LOCAL_PREF, COMMUNITIES),
-- KEEPALIVE and NOTIFICATION. AS numbers are two bytes (1..65535; 64512..65534 are the private range, which is what players should use).
local B = require("tsr.inet.bytes")

local M = {}

M.MARKER = string.rep("\255", 16)
M.OPEN, M.UPDATE, M.NOTIFICATION, M.KEEPALIVE = 1, 2, 3, 4
M.ORIGIN_IGP, M.ORIGIN_EGP, M.ORIGIN_INCOMPLETE = 0, 1, 2
M.NO_EXPORT = 0xFFFFFF01

M.ERRORS = { [1] = "message header error", [2] = "OPEN message error", [3] = "UPDATE message error", [4] = "hold timer expired", [5] = "finite state machine error", [6] = "cease" }
M.OPEN_SUB = { [1] = "unsupported version", [2] = "bad peer AS", [3] = "bad BGP identifier", [4] = "unsupported optional parameter", [5] = "authentication failure", [6] = "unacceptable hold time" }
M.CEASE_SUB = { [1] = "maximum number of prefixes reached", [2] = "administrative shutdown", [3] = "peer de-configured", [4] = "administrative reset", [5] = "connection rejected" }

function M.frame(typ, body)
  body = body or ""
  return M.MARKER .. B.u16(19 + #body) .. string.char(typ) .. body
end

--- Split the header off a complete message: returns type, body or nil + reason.
function M.parseHeader(head)
  if #head < 19 or head:sub(1, 16) ~= M.MARKER then return nil, "bad marker" end
  local len = B.rd16(head, 17)
  if len < 19 or len > 4096 then return nil, "bad length" end
  return head:byte(19), len
end

---------------------------------------------------------------------------------------------------------------------
-- OPEN / KEEPALIVE / NOTIFICATION
---------------------------------------------------------------------------------------------------------------------

--- o: as, holdTime, id (router ID, IPv4 number), auth (optional parameter: a string).
function M.openBody(o)
  local params = ""
  if o.auth then params = string.char(255, #o.auth) .. o.auth end        -- our own optional parameter type 255: authentication
  return string.char(4) .. B.u16(o.as) .. B.u16(o.holdTime) .. B.u32(o.id) .. string.char(#params) .. params
end

function M.parseOpen(body)
  if #body < 10 then return nil, "short OPEN" end
  local o = { version = body:byte(1), as = B.rd16(body, 2), holdTime = B.rd16(body, 4), id = B.rd32(body, 6) }
  local optlen = body:byte(10)
  local pos = 11
  while pos < 11 + optlen do
    local t, l = body:byte(pos), body:byte(pos + 1)
    if not l then break end
    if t == 255 then o.auth = body:sub(pos + 2, pos + 1 + l) end
    pos = pos + 2 + l
  end
  return o
end

function M.notification(code, sub, data) return M.frame(M.NOTIFICATION, string.char(code, sub or 0) .. (data or "")) end

function M.parseNotification(body)
  return { code = body:byte(1) or 0, sub = body:byte(2) or 0, data = body:sub(3) }
end

---------------------------------------------------------------------------------------------------------------------
-- UPDATE
---------------------------------------------------------------------------------------------------------------------

local function encodePrefix(net, plen)
  local nbytes = math.ceil(plen / 8)
  return string.char(plen) .. B.u32(net):sub(1, nbytes)
end

local function decodePrefixes(data)
  local out, pos = {}, 1
  while pos <= #data do
    local plen = data:byte(pos)
    if plen > 32 then return nil, "bad prefix length" end
    local nbytes = math.ceil(plen / 8)
    if pos + nbytes > #data then return nil, "truncated prefix" end
    local raw = data:sub(pos + 1, pos + nbytes) .. string.rep("\0", 4 - nbytes)
    out[#out + 1] = { net = B.rd32(raw, 1), plen = plen }
    pos = pos + 1 + nbytes
  end
  return out
end

local function attr(flags, typ, value)
  if #value > 255 then return string.char(flags + 16, typ) .. B.u16(#value) .. value end
  return string.char(flags, typ, #value) .. value
end

--- u: withdrawn = { {net, plen} }, nlri = { {net, plen} }, attrs = { origin, asPath = { as, ... }, nextHop, med, localPref, communities = { n } }.
function M.updateBody(u)
  local withdrawn = {}
  for _, p in ipairs(u.withdrawn or {}) do withdrawn[#withdrawn + 1] = encodePrefix(p.net, p.plen) end
  withdrawn = table.concat(withdrawn)
  local attrs = ""
  if u.nlri and #u.nlri > 0 then
    local a = u.attrs
    local path = ""
    if #a.asPath > 0 then
      local asn = {}
      for _, x in ipairs(a.asPath) do asn[#asn + 1] = B.u16(x) end
      path = string.char(2, #a.asPath) .. table.concat(asn)
    end
    attrs = attr(0x40, 1, string.char(a.origin or 0)) .. attr(0x40, 2, path) .. attr(0x40, 3, B.u32(a.nextHop))
    if a.med then attrs = attrs .. attr(0x80, 4, B.u32(a.med)) end
    if a.localPref then attrs = attrs .. attr(0x40, 5, B.u32(a.localPref)) end
    if a.communities and #a.communities > 0 then
      local c = {}
      for _, x in ipairs(a.communities) do c[#c + 1] = B.u32(x) end
      attrs = attrs .. attr(0xC0, 8, table.concat(c))
    end
  end
  local nlri = {}
  for _, p in ipairs(u.nlri or {}) do nlri[#nlri + 1] = encodePrefix(p.net, p.plen) end
  return B.u16(#withdrawn) .. withdrawn .. B.u16(#attrs) .. attrs .. table.concat(nlri)
end

--- Returns { withdrawn, nlri, attrs } or nil + reason.
function M.parseUpdate(body)
  if #body < 4 then return nil, "short UPDATE" end
  local wlen = B.rd16(body, 1)
  if 2 + wlen + 2 > #body then return nil, "bad withdrawn length" end
  local withdrawn, err = decodePrefixes(body:sub(3, 2 + wlen))
  if not withdrawn then return nil, err end
  local alen = B.rd16(body, 3 + wlen)
  if 4 + wlen + alen > #body then return nil, "bad attribute length" end
  local attrData = body:sub(5 + wlen, 4 + wlen + alen)
  local nlri, err2 = decodePrefixes(body:sub(5 + wlen + alen))
  if not nlri then return nil, err2 end
  local attrs = { asPath = {}, communities = {} }
  local pos = 1
  while pos < #attrData do
    local flags, typ = attrData:byte(pos, pos + 1)
    local len, hdr
    if flags % 32 >= 16 then len, hdr = B.rd16(attrData, pos + 2), 4 else len, hdr = attrData:byte(pos + 2), 3 end
    if not len or pos + hdr - 1 + len > #attrData then return nil, "bad attribute" end
    local v = attrData:sub(pos + hdr, pos + hdr - 1 + len)
    if typ == 1 then attrs.origin = v:byte(1)
    elseif typ == 2 then
      local p = 1
      while p < #v do
        local segType, count = v:byte(p), v:byte(p + 1)
        for i = 0, count - 1 do attrs.asPath[#attrs.asPath + 1] = B.rd16(v, p + 2 + i * 2) end
        p = p + 2 + count * 2
      end
    elseif typ == 3 then attrs.nextHop = B.rd32(v, 1)
    elseif typ == 4 then attrs.med = B.rd32(v, 1)
    elseif typ == 5 then attrs.localPref = B.rd32(v, 1)
    elseif typ == 8 then for i = 1, #v - 3, 4 do attrs.communities[#attrs.communities + 1] = B.rd32(v, i) end end
    pos = pos + hdr + len
  end
  if #nlri > 0 and (attrs.origin == nil or attrs.nextHop == nil) then return nil, "missing well-known attribute" end
  return { withdrawn = withdrawn, nlri = nlri, attrs = attrs }
end

function M.communityText(c) return ("%d:%d"):format(math.floor(c / 65536), c % 65536) end
function M.community(text)
  local a, b = tostring(text):match("^(%d+):(%d+)$")
  if a then return tonumber(a) * 65536 + tonumber(b) end
  if text == "no-export" then return M.NO_EXPORT end
  return nil
end

return M
