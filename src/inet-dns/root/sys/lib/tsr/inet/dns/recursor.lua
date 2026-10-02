-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A recursive resolver (RFC 1034 section 5.3.3): starts at the root servers you give it (the root hints of YOUR network - in this game the root
-- zone is whatever the players run), follows referrals down the tree, resolves name servers that came without an address, chases CNAMEs, and caches
-- answers, delegations and failures. It can also just forward to other resolvers.
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.dns.wire")
local client = require("tsr.inet.dns.client")

local M = {}
local Recursor = {}
Recursor.__index = Recursor

M.MAX_DEPTH = 8           -- nested lookups (CNAME targets, name server addresses)
M.MAX_REFERRALS = 12

--- opts: roots (list of addresses), forwarders (list of addresses; when present nothing is resolved iteratively), timeout.
function M.new(stack, opts)
  opts = opts or {}
  local self = setmetatable({ stack = stack, roots = {}, forwarders = {}, timeout = opts.timeout or 1.5, delegations = {}, queries = 0 }, Recursor)
  for _, r in ipairs(opts.roots or {}) do self.roots[#self.roots + 1] = B.ip(r) end
  for _, f in ipairs(opts.forwarders or {}) do self.forwarders[#self.forwarders + 1] = B.ip(f) end
  return self
end

local function addressesFrom(list, name)
  local out = {}
  for _, rr in ipairs(list) do if rr.type == W.TYPES.A and rr.name == name then out[#out + 1] = rr.data end end
  return out
end

--- The servers to start from for `name`: the deepest cached delegation, else the roots.
function Recursor:startServers(name)
  local best, bestLen
  for zone, d in pairs(self.delegations) do
    if d.expires > self.stack.clock() and W.isSubdomain(name, zone) and (not bestLen or #zone > bestLen) then best, bestLen = d, #zone end
  end
  if best then return best.servers end
  return self.roots
end

function Recursor:learnDelegation(zone, servers, ttl)
  self.delegations[zone] = { servers = servers, expires = self.stack.clock() + math.max(client.MIN_TTL, math.min(ttl, client.MAX_TTL)) }
end

--- Resolve (name, type). Returns { rcode, answers, authority } or nil + reason.
function Recursor:resolve(name, qtype, depth)
  depth = depth or 0
  local stack = self.stack
  name = W.normalize(name)
  local qt = type(qtype) == "number" and qtype or W.TYPES[tostring(qtype):upper()]
  local cached = client.cacheGet(stack, name, qt)
  if cached then return cached end
  if depth > M.MAX_DEPTH then return nil, "lookup too deep" end
  if #self.forwarders > 0 then
    local result, err = client.lookup(stack, name, qt, { servers = self.forwarders, timeout = self.timeout })
    return result, err
  end
  local servers = self:startServers(name)
  if #servers == 0 then return nil, "no root servers are configured" end
  local chain = {}                          -- CNAME records collected on the way
  local current = name
  for hop = 1, M.MAX_REFERRALS * 2 do
    local reply, tried = nil, 0
    for _, server in ipairs(servers) do
      tried = tried + 1
      self.queries = self.queries + 1
      local r = client.query(stack, B.ipStr(server), current, qt, { rd = false, timeout = self.timeout })
      if r and r.rcode ~= W.RCODE.SERVFAIL and r.rcode ~= W.RCODE.REFUSED then reply = r break end
    end
    if not reply then return { rcode = W.RCODE.SERVFAIL, answers = chain, authority = {} } end
    if reply.rcode == W.RCODE.NXDOMAIN then
      local result = { rcode = W.RCODE.NXDOMAIN, answers = chain, authority = reply.authority }
      local ttl = client.NEGATIVE_TTL
      for _, rr in ipairs(reply.authority) do if rr.type == W.TYPES.SOA then ttl = math.min(rr.data.minimum, client.MAX_TTL) end end
      client.cachePut(stack, name, qt, result, math.max(client.MIN_TTL, ttl))
      return result
    end
    if #reply.answers > 0 then
      -- answers for `current`: the wanted type, or a CNAME to follow
      local direct, cname = {}, nil
      for _, rr in ipairs(reply.answers) do
        chain[#chain + 1] = rr
        if rr.name == current and rr.type == qt then direct[#direct + 1] = rr end
        if rr.type == W.TYPES.CNAME and rr.name == current then cname = rr.data end
      end
      -- a server may have followed the chain itself: look for the wanted type under any name of the chain
      local final = false
      for _, rr in ipairs(reply.answers) do if rr.type == qt then final = true end end
      if final or qt == W.TYPES.CNAME or not cname then
        local result = { rcode = W.RCODE.OK, answers = chain, authority = reply.authority }
        client.cachePut(stack, name, qt, result, #chain > 0 and math.max(client.MIN_TTL, math.min(client.MAX_TTL, chain[1].ttl)) or client.MIN_TTL)
        return result
      end
      current = cname
      servers = self:startServers(current)
    elseif reply.aa or (#reply.authority > 0 and reply.authority[1].type == W.TYPES.SOA) then
      -- the name exists but has no data of this type
      local result = { rcode = W.RCODE.OK, answers = chain, authority = reply.authority }
      client.cachePut(stack, name, qt, result, client.NEGATIVE_TTL)
      return result
    else
      -- a referral: follow the name servers
      local ns = {}
      local zone
      for _, rr in ipairs(reply.authority) do if rr.type == W.TYPES.NS then ns[#ns + 1] = rr.data zone = zone or rr.name end end
      if #ns == 0 then return { rcode = W.RCODE.SERVFAIL, answers = chain, authority = {} } end
      local addrs = {}
      for _, n in ipairs(ns) do for _, a in ipairs(addressesFrom(reply.additional, n)) do addrs[#addrs + 1] = a end end
      if #addrs == 0 then
        for _, n in ipairs(ns) do
          local sub = self:resolve(n, "A", depth + 1)
          if sub and sub.rcode == W.RCODE.OK then
            for _, rr in ipairs(sub.answers) do if rr.type == W.TYPES.A then addrs[#addrs + 1] = rr.data end end
          end
          if #addrs > 0 then break end
        end
      end
      if #addrs == 0 then return { rcode = W.RCODE.SERVFAIL, answers = chain, authority = {} } end
      self:learnDelegation(zone, addrs, reply.authority[1].ttl)
      servers = addrs
    end
  end
  return { rcode = W.RCODE.SERVFAIL, answers = chain, authority = {} }
end

return M
