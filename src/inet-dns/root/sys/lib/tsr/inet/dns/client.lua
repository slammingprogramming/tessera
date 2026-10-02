-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The DNS client: one query to one server (UDP, with TCP when the answer was truncated) and the stub resolver that the rest of the system uses
-- through stack:resolve(name): the servers come from DHCP or the configuration (stack.dnsServers), names without a dot get the search domains,
-- answers are cached for their TTL, and failures are cached for a short while so a dead name does not slow every program down.
local B = require("tsr.inet.bytes")
local socket = require("tsr.inet.socket")
local W = require("tsr.inet.dns.wire")

local M = {}

M.PORT = 53
M.TIMEOUT = 2
M.TRIES = 2
M.MAX_TTL = 3600
M.MIN_TTL = 5
M.NEGATIVE_TTL = 60

local function randomId(stack) return stack.random(65535) end

--- Ask one server. opts: rd (recursion desired, default true), timeout, tcp (force TCP), edns no. Returns the decoded reply or nil + reason.
function M.query(stack, server, name, qtype, opts)
  opts = opts or {}
  local ip = B.ip(server)
  if not ip then return nil, "bad server address" end
  local qt = type(qtype) == "number" and qtype or W.TYPES[tostring(qtype):upper()]
  if not qt then return nil, "unknown record type " .. tostring(qtype) end
  local id = randomId(stack)
  local msg = W.encode({ id = id, rd = opts.rd ~= false, questions = { { name = name, type = qt, class = 1 } } })
  local function viaTcp()
    local c = socket.tcp(stack)
    local ok, err = c:connect(B.ipStr(ip), M.PORT, opts.timeout or M.TIMEOUT)
    if not ok then return nil, err end
    c:send(B.u16(#msg) .. msg)
    local len = c:receive(2, opts.timeout or M.TIMEOUT)
    if not len then c:close() return nil, "timeout" end
    local data = c:receive(B.rd16(len, 1), opts.timeout or M.TIMEOUT)
    c:close()
    if not data then return nil, "timeout" end
    return W.decode(data)
  end
  if opts.tcp then return viaTcp() end
  local u = socket.udp(stack)
  local deadline = stack.clock() + (opts.timeout or M.TIMEOUT)
  local connected, cerr = u:connect(B.ipStr(ip), M.PORT)          -- a connected socket hears about ICMP "port unreachable"
  if not connected then u:close() return nil, cerr end
  local sent, serr = u:send(msg)
  if not sent then u:close() return nil, serr end
  while true do
    local left = deadline - stack.clock()
    if left <= 0 then u:close() return nil, "timeout" end
    local data, from, port = u:receivefrom(left)
    if not data then u:close() return nil, from == "connection refused" and from or "timeout" end
    if from == B.ipStr(ip) and port == M.PORT then
      local reply = W.decode(data)
      if reply and reply.id == id and reply.qr then
        u:close()
        if reply.tc then return viaTcp() end
        return reply
      end
    end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Cache
---------------------------------------------------------------------------------------------------------------------

local function cacheOf(stack)
  if not stack.dnsCache then stack.dnsCache = {} end
  return stack.dnsCache
end

local function minTtl(rrs)
  local t = M.MAX_TTL
  for _, rr in ipairs(rrs) do t = math.min(t, rr.ttl) end
  return math.max(M.MIN_TTL, t)
end

function M.cachePut(stack, name, qtype, result, ttl)
  cacheOf(stack)[name .. "|" .. qtype] = { result = result, expires = stack.clock() + ttl }
end

function M.cacheGet(stack, name, qtype)
  local c = cacheOf(stack)
  local e = c[name .. "|" .. qtype]
  if not e then return nil end
  if e.expires <= stack.clock() then c[name .. "|" .. qtype] = nil return nil end
  return e.result
end

function M.flush(stack) stack.dnsCache = {} end

---------------------------------------------------------------------------------------------------------------------
-- Stub resolver
---------------------------------------------------------------------------------------------------------------------

--- Resolve name/type with the configured servers. Returns { rcode, answers, authority, cached } or nil + reason.
function M.lookup(stack, name, qtype, opts)
  opts = opts or {}
  name = W.normalize(name)
  local qt = type(qtype) == "number" and qtype or W.TYPES[tostring(qtype or "A"):upper()]
  if not qt then return nil, "unknown record type" end
  local hit = M.cacheGet(stack, name, qt)
  if hit and not opts.nocache then return hit end
  local servers = opts.servers or stack.dnsServers or {}
  if #servers == 0 then return nil, "no DNS server is configured" end
  local lastErr = "timeout"
  for attempt = 1, M.TRIES do
    for _, server in ipairs(servers) do
      local reply, err = M.query(stack, server, name, qt, { timeout = opts.timeout or M.TIMEOUT })
      if reply then
        if reply.rcode == W.RCODE.SERVFAIL or reply.rcode == W.RCODE.REFUSED then
          lastErr = W.RCODE_NAMES[reply.rcode]:lower()
        else
          local result = { rcode = reply.rcode, answers = reply.answers, authority = reply.authority, additional = reply.additional, aa = reply.aa, from = B.ipStr(B.ip(server)) }
          if reply.rcode == W.RCODE.OK and #reply.answers > 0 then M.cachePut(stack, name, qt, result, minTtl(reply.answers))
          else
            local ttl = M.NEGATIVE_TTL
            for _, rr in ipairs(reply.authority) do if rr.type == W.TYPES.SOA then ttl = math.min(M.MAX_TTL, rr.data.minimum) end end
            M.cachePut(stack, name, qt, result, math.max(M.MIN_TTL, ttl))
          end
          return result
        end
      else
        lastErr = err or "timeout"
      end
    end
  end
  return nil, lastErr
end

local function firstA(result, name)
  -- follow the CNAME chain in the answer to the address
  local target = name
  for _ = 1, 10 do
    local next
    for _, rr in ipairs(result.answers) do
      if rr.name == target then
        if rr.type == W.TYPES.A then return rr.data end
        if rr.type == W.TYPES.CNAME then next = rr.data end
      end
    end
    if not next then break end
    target = next
  end
  for _, rr in ipairs(result.answers) do if rr.type == W.TYPES.A then return rr.data end end
end

--- name -> ip with search domains. This is what stack:resolve calls after the hosts table.
function M.resolveName(stack, name, timeout)
  name = W.normalize(name)
  local candidates = {}
  if name:find(".", 1, true) then candidates[#candidates + 1] = name end
  if not name:find(".", 1, true) or #(stack.searchDomains or {}) > 0 and not name:find(".", 1, true) then
    for _, d in ipairs(stack.searchDomains or {}) do candidates[#candidates + 1] = name .. "." .. d end
    if not name:find(".", 1, true) then candidates[#candidates + 1] = name end
  end
  local lastReason = "cannot resolve " .. name
  for _, cand in ipairs(candidates) do
    local result, err = M.lookup(stack, cand, "A", { timeout = timeout and math.min(timeout, M.TIMEOUT) or nil })
    if result then
      if result.rcode == W.RCODE.OK then
        local ip = firstA(result, cand)
        if ip then return ip end
        lastReason = "no address record for " .. cand
      elseif result.rcode == W.RCODE.NXDOMAIN then lastReason = "no such name: " .. cand
      else lastReason = (W.RCODE_NAMES[result.rcode] or "error"):lower() .. " for " .. cand end
    else
      lastReason = "cannot resolve " .. cand .. ": " .. tostring(err)
    end
  end
  return nil, lastReason
end

--- Make this stack use DNS for names it does not know from the hosts table.
function M.install(stack)
  stack.resolver = function(name, timeout) return M.resolveName(stack, name, timeout) end
end

--- Reverse lookup: ip -> name.
function M.reverse(stack, ip)
  local result = M.lookup(stack, W.reverseName(ip), "PTR")
  if result and result.rcode == W.RCODE.OK then
    for _, rr in ipairs(result.answers) do if rr.type == W.TYPES.PTR then return rr.data end end
  end
  return nil
end

return M
