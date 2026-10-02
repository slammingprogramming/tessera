-- SPDX-License-Identifier: AGPL-3.0-or-later
-- DNS messages (RFC 1035): header, questions, resource records, and name compression. Supported record types: A, NS, CNAME, SOA, PTR, MX, TXT, SRV.
-- Names are lower-case dotted strings without the final dot ("mail.example.lan"); the root is "".
local B = require("tsr.inet.bytes")

local M = {}

local sbyte, schar, floor, concat = string.byte, string.char, math.floor, table.concat

M.TYPES = { A = 1, NS = 2, CNAME = 5, SOA = 6, PTR = 12, MX = 15, TXT = 16, SRV = 33, ANY = 255, AXFR = 252 }
M.TYPE_NAMES = {}
for name, code in pairs(M.TYPES) do M.TYPE_NAMES[code] = name end
M.CLASS_IN = 1

M.RCODE = { OK = 0, FORMERR = 1, SERVFAIL = 2, NXDOMAIN = 3, NOTIMP = 4, REFUSED = 5 }
M.RCODE_NAMES = { [0] = "NOERROR", [1] = "FORMERR", [2] = "SERVFAIL", [3] = "NXDOMAIN", [4] = "NOTIMP", [5] = "REFUSED" }

---------------------------------------------------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------------------------------------------------

function M.normalize(name)
  name = tostring(name or ""):lower():gsub("%.$", "")
  return name
end

--- Is `name` equal to or below `zone`?
function M.isSubdomain(name, zone)
  if zone == "" then return true end
  return name == zone or name:sub(-(#zone + 1)) == "." .. zone
end

function M.labels(name)
  local t = {}
  for l in name:gmatch("[^%.]+") do t[#t + 1] = l end
  return t
end

local function validName(name)
  if #name > 253 then return false end
  for label in name:gmatch("[^%.]+") do
    if #label > 63 then return false end
  end
  return not name:find("..", 1, true)
end
M.validName = validName

---------------------------------------------------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------------------------------------------------

local function writeName(out, name, offsets)
  -- out is a buffer { parts = {}, len = n }
  name = M.normalize(name)
  local labels = M.labels(name)
  for i = 1, #labels do
    local suffix = concat(labels, ".", i)
    local at = offsets and offsets[suffix]
    if at and at < 16384 then
      out.parts[#out.parts + 1] = B.u16(0xC000 + at)
      out.len = out.len + 2
      return
    end
    if offsets and out.len < 16384 then offsets[suffix] = out.len end
    out.parts[#out.parts + 1] = schar(#labels[i]) .. labels[i]
    out.len = out.len + 1 + #labels[i]
  end
  out.parts[#out.parts + 1] = "\0"
  out.len = out.len + 1
end

local function push(out, s)
  out.parts[#out.parts + 1] = s
  out.len = out.len + #s
end

local function writeRdata(out, rr, offsets)
  local t, v = rr.type, rr.data
  local mark = #out.parts + 1
  -- reserve the length field; fill it afterwards
  out.parts[#out.parts + 1] = "\0\0"
  out.len = out.len + 2
  local start = out.len
  if t == M.TYPES.A then push(out, B.u32(v))
  elseif t == M.TYPES.NS or t == M.TYPES.CNAME or t == M.TYPES.PTR then writeName(out, v, offsets)
  elseif t == M.TYPES.MX then push(out, B.u16(v.preference)) writeName(out, v.exchange, offsets)
  elseif t == M.TYPES.TXT then
    local strings = type(v) == "table" and v or { v }
    for _, s in ipairs(strings) do
      while #s > 255 do push(out, schar(255) .. s:sub(1, 255)) s = s:sub(256) end
      push(out, schar(#s) .. s)
    end
  elseif t == M.TYPES.SOA then
    writeName(out, v.mname, offsets) writeName(out, v.rname, offsets)
    push(out, B.u32(v.serial) .. B.u32(v.refresh) .. B.u32(v.retry) .. B.u32(v.expire) .. B.u32(v.minimum))
  elseif t == M.TYPES.SRV then
    push(out, B.u16(v.priority) .. B.u16(v.weight) .. B.u16(v.port))
    writeName(out, v.target, nil)
  else
    push(out, tostring(v or ""))
  end
  local rdlen = out.len - start
  out.parts[mark] = B.u16(rdlen)
end

local function writeRR(out, rr, offsets)
  writeName(out, rr.name, offsets)
  push(out, B.u16(rr.type) .. B.u16(rr.class or M.CLASS_IN) .. B.u32(rr.ttl or 0))
  writeRdata(out, rr, offsets)
end

--- m: id, qr (bool), opcode, aa, tc, rd, ra, rcode, questions = { {name, type, class} }, answers / authority / additional = { rr }.
--- rr = { name, type, class, ttl, data }. With `maxSize` the message is cut at record boundaries and TC is set when something was left out.
function M.encode(m, maxSize)
  local out = { parts = {}, len = 12 }
  local offsets = {}
  local counts = { 0, 0, 0, 0 }
  for _, qq in ipairs(m.questions or {}) do
    writeName(out, qq.name, offsets)
    push(out, B.u16(qq.type) .. B.u16(qq.class or 1))
    counts[1] = counts[1] + 1
  end
  local tc = false
  local sections = { m.answers or {}, m.authority or {}, m.additional or {} }
  for si, list in ipairs(sections) do
    for _, rr in ipairs(list) do
      if tc then break end
      local keepParts, keepLen = #out.parts, out.len
      writeRR(out, rr, offsets)
      if maxSize and out.len > maxSize then
        for i = #out.parts, keepParts + 1, -1 do out.parts[i] = nil end
        out.len = keepLen
        tc = true
        break
      end
      counts[si + 1] = counts[si + 1] + 1
    end
  end
  local flags = (m.qr and 0x8000 or 0) + (m.opcode or 0) * 2048 + (m.aa and 0x0400 or 0) + ((tc or m.tc) and 0x0200 or 0) + (m.rd and 0x0100 or 0) + (m.ra and 0x0080 or 0) + (m.rcode or 0)
  local head = B.u16(m.id or 0) .. B.u16(flags) .. B.u16(counts[1]) .. B.u16(counts[2]) .. B.u16(counts[3]) .. B.u16(counts[4])
  return head .. concat(out.parts)
end

---------------------------------------------------------------------------------------------------------------------
-- Decoding
---------------------------------------------------------------------------------------------------------------------

local function readName(data, pos)
  local labels = {}
  local jumped, endPos = false, nil
  local hops = 0
  while true do
    local len = sbyte(data, pos)
    if not len then return nil, "truncated name" end
    if len == 0 then
      pos = pos + 1
      break
    elseif len >= 192 then
      local b2 = sbyte(data, pos + 1)
      if not b2 then return nil, "truncated pointer" end
      if not jumped then endPos = pos + 2 jumped = true end
      pos = (len % 64) * 256 + b2 + 1
      hops = hops + 1
      if hops > 32 then return nil, "compression loop" end
    elseif len >= 64 then
      return nil, "bad label"
    else
      local label = data:sub(pos + 1, pos + len)
      if #label < len then return nil, "truncated label" end
      labels[#labels + 1] = label:lower()
      pos = pos + 1 + len
    end
  end
  return concat(labels, "."), endPos or pos
end

local function readRdata(data, pos, rtype, rdlen)
  local stop = pos + rdlen
  if stop > #data + 1 then return nil, "truncated record" end
  if rtype == M.TYPES.A then
    if rdlen ~= 4 then return nil, "bad A record" end
    return B.rd32(data, pos)
  elseif rtype == M.TYPES.NS or rtype == M.TYPES.CNAME or rtype == M.TYPES.PTR then
    return (readName(data, pos))
  elseif rtype == M.TYPES.MX then
    local pref = B.rd16(data, pos)
    local name = readName(data, pos + 2)
    if not pref or not name then return nil, "bad MX" end
    return { preference = pref, exchange = name }
  elseif rtype == M.TYPES.TXT then
    local strings, p = {}, pos
    while p < stop do
      local l = sbyte(data, p)
      strings[#strings + 1] = data:sub(p + 1, p + l)
      p = p + 1 + l
    end
    return strings
  elseif rtype == M.TYPES.SOA then
    local mname, p = readName(data, pos)
    if not mname then return nil, "bad SOA" end
    local rname, p2 = readName(data, p)
    if not rname then return nil, "bad SOA" end
    return { mname = mname, rname = rname, serial = B.rd32(data, p2), refresh = B.rd32(data, p2 + 4), retry = B.rd32(data, p2 + 8), expire = B.rd32(data, p2 + 12), minimum = B.rd32(data, p2 + 16) }
  elseif rtype == M.TYPES.SRV then
    local target = readName(data, pos + 6)
    if not target then return nil, "bad SRV" end
    return { priority = B.rd16(data, pos), weight = B.rd16(data, pos + 2), port = B.rd16(data, pos + 4), target = target }
  end
  return data:sub(pos, stop - 1)
end

function M.decode(data)
  if #data < 12 then return nil, "short DNS message" end
  local flags = B.rd16(data, 3)
  local m = {
    id = B.rd16(data, 1), qr = flags >= 0x8000, opcode = floor(flags / 2048) % 16, aa = floor(flags / 1024) % 2 == 1, tc = floor(flags / 512) % 2 == 1,
    rd = floor(flags / 256) % 2 == 1, ra = floor(flags / 128) % 2 == 1, rcode = flags % 16, questions = {}, answers = {}, authority = {}, additional = {},
  }
  local qd, an, ns, ar = B.rd16(data, 5), B.rd16(data, 7), B.rd16(data, 9), B.rd16(data, 11)
  local pos = 13
  for _ = 1, qd do
    local name, p = readName(data, pos)
    if not name then return nil, p end
    if p + 3 > #data then return nil, "truncated question" end
    m.questions[#m.questions + 1] = { name = name, type = B.rd16(data, p), class = B.rd16(data, p + 2) }
    pos = p + 4
  end
  for si, count in ipairs({ an, ns, ar }) do
    local list = ({ m.answers, m.authority, m.additional })[si]
    for _ = 1, count do
      local name, p = readName(data, pos)
      if not name then return nil, p end
      if p + 9 > #data then return nil, "truncated record" end
      local rtype, class, ttl, rdlen = B.rd16(data, p), B.rd16(data, p + 2), B.rd32(data, p + 4), B.rd16(data, p + 8)
      local value, err = readRdata(data, p + 10, rtype, rdlen)
      if value == nil then return nil, err end
      list[#list + 1] = { name = name, type = rtype, class = class, ttl = ttl, data = value }
      pos = p + 10 + rdlen
    end
  end
  return m
end

--- Text form of a record's data (for tools).
function M.dataText(rr)
  local t, v = rr.type, rr.data
  if t == M.TYPES.A then return B.ipStr(v)
  elseif t == M.TYPES.NS or t == M.TYPES.CNAME or t == M.TYPES.PTR then return v .. "."
  elseif t == M.TYPES.MX then return v.preference .. " " .. v.exchange .. "."
  elseif t == M.TYPES.TXT then
    local parts = {}
    for _, s in ipairs(v) do parts[#parts + 1] = '"' .. s .. '"' end
    return concat(parts, " ")
  elseif t == M.TYPES.SOA then return ("%s. %s. %d %d %d %d %d"):format(v.mname, v.rname, v.serial, v.refresh, v.retry, v.expire, v.minimum)
  elseif t == M.TYPES.SRV then return ("%d %d %d %s."):format(v.priority, v.weight, v.port, v.target)
  end
  return tostring(v)
end

--- The name a reverse lookup of an address uses ("2.0.0.10.in-addr.arpa").
function M.reverseName(ip)
  return ("%d.%d.%d.%d.in-addr.arpa"):format(ip % 256, floor(ip / 256) % 256, floor(ip / 65536) % 256, floor(ip / 16777216) % 256)
end

return M
