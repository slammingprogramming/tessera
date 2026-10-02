-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Zones: master files (RFC 1035 section 5) and the lookup rules of an authoritative server (RFC 1034 section 4.3.2): exact names, CNAME chains,
-- wildcards, "name exists but has no data", delegations (referrals with glue) and NXDOMAIN with the SOA for negative caching.
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.dns.wire")

local M = {}
local Zone = {}
Zone.__index = Zone
M.Zone = Zone

local T = W.TYPES

function M.new(origin)
  return setmetatable({ origin = W.normalize(origin or ""), names = {}, count = 0, defaultTtl = 3600 }, Zone)
end

local function typeCode(t)
  if type(t) == "number" then return t end
  return W.TYPES[tostring(t):upper()]
end
M.typeCode = typeCode

function Zone:add(rr)
  rr.name = W.normalize(rr.name)
  rr.class = rr.class or W.CLASS_IN
  rr.ttl = rr.ttl or self.defaultTtl
  local node = self.names[rr.name]
  if not node then node = {} self.names[rr.name] = node end
  local list = node[rr.type]
  if not list then list = {} node[rr.type] = list end
  if rr.type == T.SOA then
    node[rr.type] = { rr }
    self.soa = rr
  else
    list[#list + 1] = rr
  end
  self.count = self.count + 1
  return rr
end

--- Remove records: by name, optionally of one type (and optionally one value text).
function Zone:remove(name, rtype)
  name = W.normalize(name)
  local node = self.names[name]
  if not node then return 0 end
  local n = 0
  if rtype then
    local code = typeCode(rtype)
    n = node[code] and #node[code] or 0
    node[code] = nil
  else
    for _, list in pairs(node) do n = n + #list end
    self.names[name] = nil
  end
  if node and next(node) == nil then self.names[name] = nil end
  self.count = self.count - n
  return n
end

function Zone:serial() return self.soa and self.soa.data.serial or 0 end

function Zone:bumpSerial()
  if self.soa then self.soa.data.serial = (self.soa.data.serial + 1) % 4294967296 end
end

--- All records, SOA first (the order AXFR wants), then sorted by name and type.
function Zone:all()
  local out = {}
  if self.soa then out[1] = self.soa end
  local names = {}
  for name in pairs(self.names) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local types = {}
    for t in pairs(self.names[name]) do types[#types + 1] = t end
    table.sort(types)
    for _, t in ipairs(types) do
      if t ~= T.SOA then for _, rr in ipairs(self.names[name][t]) do out[#out + 1] = rr end end
    end
  end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Lookup
---------------------------------------------------------------------------------------------------------------------

local function glueFor(self, targets, additional)
  for _, target in ipairs(targets) do
    local node = self.names[target]
    if node and node[T.A] then for _, rr in ipairs(node[T.A]) do additional[#additional + 1] = rr end end
  end
end

--- Answer a question from this zone's data. Returns { rcode, aa, answers, authority, additional, referral }.
function Zone:lookup(qname, qtype)
  qname = W.normalize(qname)
  local res = { rcode = W.RCODE.OK, aa = true, answers = {}, authority = {}, additional = {} }
  if not W.isSubdomain(qname, self.origin) then res.rcode, res.aa = W.RCODE.REFUSED, false return res end
  -- delegation: a name below a cut (NS records at an interior node)
  local labels = W.labels(qname)
  local originLabels = #W.labels(self.origin)
  for i = 2, #labels - originLabels do
    local ancestor = table.concat(labels, ".", i)
    if ancestor ~= self.origin and W.isSubdomain(ancestor, self.origin) then
      local node = self.names[ancestor]
      if node and node[T.NS] then
        res.aa = false
        res.referral = true
        local targets = {}
        for _, rr in ipairs(node[T.NS]) do res.authority[#res.authority + 1] = rr targets[#targets + 1] = rr.data end
        glueFor(self, targets, res.additional)
        return res
      end
    end
  end
  -- a delegation at the name itself (other than a query for the NS records)
  local own = self.names[qname]
  if own and own[T.NS] and qname ~= self.origin and qtype ~= T.NS and qtype ~= T.ANY then
    res.aa, res.referral = false, true
    local targets = {}
    for _, rr in ipairs(own[T.NS]) do res.authority[#res.authority + 1] = rr targets[#targets + 1] = rr.data end
    glueFor(self, targets, res.additional)
    return res
  end
  local seen = {}
  local name = qname
  for _ = 1, 10 do
    local node = self.names[name]
    if not node then
      -- wildcard: *.parent
      local up = name:match("^[^%.]+%.(.+)$")
      while up and not node do
        local wild = self.names["*." .. up]
        if wild then
          node = {}
          for t, list in pairs(wild) do
            node[t] = {}
            for _, rr in ipairs(list) do node[t][#node[t] + 1] = { name = name, type = rr.type, class = rr.class, ttl = rr.ttl, data = rr.data } end
          end
          break
        end
        if up == self.origin then break end
        up = up:match("^[^%.]+%.(.+)$")
      end
    end
    if not node then
      -- the name does not exist, unless something exists below it (an "empty non-terminal")
      local below = false
      for other in pairs(self.names) do if other ~= name and W.isSubdomain(other, name) then below = true break end end
      if below then
        if self.soa then res.authority[1] = self.soa end
        return res
      end
      res.rcode = W.RCODE.NXDOMAIN
      if self.soa then res.authority[1] = { name = self.origin, type = T.SOA, class = 1, ttl = math.min(self.soa.ttl, self.soa.data.minimum), data = self.soa.data } end
      return res
    end
    if node[T.CNAME] and qtype ~= T.CNAME and qtype ~= T.ANY then
      local rr = node[T.CNAME][1]
      res.answers[#res.answers + 1] = rr
      if seen[rr.data] or not W.isSubdomain(rr.data, self.origin) then return res end
      seen[rr.data] = true
      name = rr.data
    else
      local found = false
      for t, list in pairs(node) do
        if qtype == T.ANY or t == qtype then
          for _, rr in ipairs(list) do res.answers[#res.answers + 1] = rr found = true end
        end
      end
      if not found then
        if self.soa then res.authority[1] = { name = self.origin, type = T.SOA, class = 1, ttl = math.min(self.soa.ttl, self.soa.data.minimum), data = self.soa.data } end
      else
        local targets = {}
        for _, rr in ipairs(res.answers) do
          if rr.type == T.NS then targets[#targets + 1] = rr.data elseif rr.type == T.MX then targets[#targets + 1] = rr.data.exchange end
        end
        glueFor(self, targets, res.additional)
      end
      return res
    end
  end
  return res
end

---------------------------------------------------------------------------------------------------------------------
-- Master files
---------------------------------------------------------------------------------------------------------------------

local function ttlValue(text)
  local n, unit = tostring(text):match("^(%d+)([smhdwSMHDW]?)$")
  if not n then return nil end
  local mult = { s = 1, m = 60, h = 3600, d = 86400, w = 604800 }
  return tonumber(n) * (mult[unit:lower()] or 1)
end

--- Split a record line into tokens, keeping "quoted strings" together and dropping comments.
local function tokenize(line)
  local tokens = {}
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == ";" then break
    elseif c == '"' then
      local j = i + 1
      local buf = {}
      while j <= #line and line:sub(j, j) ~= '"' do
        local ch = line:sub(j, j)
        if ch == "\\" then j = j + 1 ch = line:sub(j, j) end
        buf[#buf + 1] = ch
        j = j + 1
      end
      tokens[#tokens + 1] = { quoted = table.concat(buf) }
      i = j + 1
    elseif c:match("%s") then i = i + 1
    elseif c == "(" or c == ")" then tokens[#tokens + 1] = c i = i + 1
    else
      local j = i
      while j <= #line and not line:sub(j, j):match("[%s;()]") do j = j + 1 end
      tokens[#tokens + 1] = line:sub(i, j - 1)
      i = j
    end
  end
  return tokens
end

local function absolute(name, origin)
  if name == "@" then return origin end
  if name:sub(-1) == "." then return W.normalize(name) end
  if origin == "" then return W.normalize(name) end
  return W.normalize(name) .. "." .. origin
end

local function parseRdata(rtype, toks, origin)
  local function str(i) local t = toks[i] return type(t) == "table" and t.quoted or t end
  if rtype == T.A then
    local ip = B.ip(str(1) or "")
    if not ip then return nil, "bad address" end
    return ip
  elseif rtype == T.NS or rtype == T.CNAME or rtype == T.PTR then
    if not str(1) then return nil, "missing name" end
    return absolute(str(1), origin)
  elseif rtype == T.MX then
    local pref = tonumber(str(1))
    if not pref or not str(2) then return nil, "bad MX" end
    return { preference = pref, exchange = absolute(str(2), origin) }
  elseif rtype == T.TXT then
    local parts = {}
    for _, t in ipairs(toks) do parts[#parts + 1] = type(t) == "table" and t.quoted or t end
    if #parts == 0 then return nil, "empty TXT" end
    return parts
  elseif rtype == T.SOA then
    local nums = {}
    for i = 3, 7 do nums[#nums + 1] = ttlValue(str(i) or "") end
    if not str(1) or not str(2) or #nums < 5 then return nil, "bad SOA" end
    return { mname = absolute(str(1), origin), rname = absolute(str(2), origin), serial = nums[1], refresh = nums[2], retry = nums[3], expire = nums[4], minimum = nums[5] }
  elseif rtype == T.SRV then
    local p, w, port = tonumber(str(1)), tonumber(str(2)), tonumber(str(3))
    if not (p and w and port and str(4)) then return nil, "bad SRV" end
    return { priority = p, weight = w, port = port, target = absolute(str(4), origin) }
  end
  return nil, "unsupported record type"
end

--- Parse master file text. Returns a Zone (origin from $ORIGIN or `origin`) and a list of problems ("line 4: ...").
function M.parse(text, origin)
  local zone = M.new(origin or "")
  local problems = {}
  local ttl = 3600
  local last
  -- join parenthesised continuation lines
  local lines, buf, depth = {}, nil, 0
  local n = 0
  for raw in ((text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    n = n + 1
    local code = raw:gsub(";.*$", "")
    local opens = select(2, code:gsub("%(", ""))
    local closes = select(2, code:gsub("%)", ""))
    if depth == 0 then
      buf = { text = code, line = n, indent = raw:match("^%s") ~= nil }
    else
      buf.text = buf.text .. " " .. code
    end
    depth = depth + opens - closes
    if depth <= 0 then
      depth = 0
      lines[#lines + 1] = buf
      buf = nil
    end
  end
  for _, l in ipairs(lines) do
    local toks = tokenize(l.text)
    local clean = {}
    for _, t in ipairs(toks) do if t ~= "(" and t ~= ")" then clean[#clean + 1] = t end end
    toks = clean
    if #toks > 0 then
      local first = type(toks[1]) == "string" and toks[1] or nil
      if first and first:sub(1, 1) == "$" then
        local d = first:upper()
        if d == "$ORIGIN" and toks[2] then
          zone.origin = W.normalize(toks[2])
        elseif d == "$TTL" and toks[2] and ttlValue(toks[2]) then
          ttl = ttlValue(toks[2])
          zone.defaultTtl = ttl
        else
          problems[#problems + 1] = ("line %d: bad directive %s"):format(l.line, first)
        end
      else
        local i = 1
        local owner
        if l.indent then owner = last else
          owner = absolute(type(toks[1]) == "table" and toks[1].quoted or toks[1], zone.origin)
          i = 2
        end
        local recTtl, class = nil, nil
        while toks[i] and type(toks[i]) == "string" do
          local t = toks[i]
          if ttlValue(t) and not W.TYPES[t:upper()] then recTtl = ttlValue(t) i = i + 1
          elseif t:upper() == "IN" then class = 1 i = i + 1
          else break end
        end
        local typeName = type(toks[i]) == "string" and toks[i]:upper() or nil
        local code = typeName and W.TYPES[typeName]
        if not owner then
          problems[#problems + 1] = ("line %d: no owner name"):format(l.line)
        elseif not code or typeName == "ANY" then
          problems[#problems + 1] = ("line %d: unknown record type %s"):format(l.line, tostring(typeName))
        else
          local rest = {}
          for k = i + 1, #toks do rest[#rest + 1] = toks[k] end
          local data, err = parseRdata(code, rest, zone.origin)
          if data == nil then
            problems[#problems + 1] = ("line %d: %s"):format(l.line, tostring(err))
          else
            last = owner
            zone:add({ name = owner, type = code, class = class or 1, ttl = recTtl or ttl, data = data })
          end
        end
      end
    end
  end
  return zone, problems
end

local function nameOut(name, origin)
  if name == origin then return "@" end
  if origin ~= "" and name:sub(-(#origin + 1)) == "." .. origin then return name:sub(1, -(#origin + 2)) end
  return name .. "."
end

--- Text of a zone as a master file that parse() reads back.
function M.serialize(zone)
  local out = { "$ORIGIN " .. zone.origin .. ".", "$TTL " .. zone.defaultTtl }
  for _, rr in ipairs(zone:all()) do
    local data
    local t = rr.type
    local o = zone.origin
    if t == T.A then data = B.ipStr(rr.data)
    elseif t == T.NS or t == T.CNAME or t == T.PTR then data = nameOut(rr.data, o)
    elseif t == T.MX then data = rr.data.preference .. " " .. nameOut(rr.data.exchange, o)
    elseif t == T.TXT then
      local p = {}
      for _, s in ipairs(rr.data) do p[#p + 1] = '"' .. s:gsub('"', '\\"') .. '"' end
      data = table.concat(p, " ")
    elseif t == T.SOA then
      local v = rr.data
      data = ("%s %s %d %d %d %d %d"):format(nameOut(v.mname, o), nameOut(v.rname, o), v.serial, v.refresh, v.retry, v.expire, v.minimum)
    elseif t == T.SRV then
      local v = rr.data
      data = ("%d %d %d %s"):format(v.priority, v.weight, v.port, nameOut(v.target, o))
    end
    if data then out[#out + 1] = ("%-24s %d IN %-6s %s"):format(nameOut(rr.name, o), rr.ttl, W.TYPE_NAMES[t], data) end
  end
  return table.concat(out, "\n") .. "\n"
end

return M
