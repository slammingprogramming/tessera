-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Blocklists in DNS (DNSBL, RFC 5782): a list server answers A queries for "<reversed ip>.<zone>"; any answer in 127.0.0.0/8 means "listed". Players who run a
-- DNS server can run such a list (a zone with entries like 5.0.0.10.bl.example.lan A 127.0.0.2); mail servers name the lists they trust, with a score each.
--   dnsbl.check(mail, "10.0.0.5", { { zone = "bl.example.lan", score = 4 } })  ->  { { zone, score, code } ... }
local B = require("tsr.inet.bytes")

local M = {}

local function reversed(ip)
  local n = type(ip) == "number" and ip or B.ip(ip)
  if not n then return nil end
  local a, b, c, d = B.ipStr(n):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return d .. "." .. c .. "." .. b .. "." .. a
end

--- Lists that contain the address. Lookup problems count as "not listed".
function M.check(mail, ip, zones)
  local rev = reversed(ip)
  local hits = {}
  if not rev then return hits end
  for _, z in ipairs(zones or {}) do
    local zone = type(z) == "string" and { zone = z, score = 3 } or z
    local answers = mail:dnsA(rev .. "." .. zone.zone)
    for _, a in ipairs(answers or {}) do
      if a:match("^127%.") then hits[#hits + 1] = { zone = zone.zone, score = zone.score or 3, code = a } break end
    end
  end
  return hits
end

--- Lists of domains (URIBL style): the domain itself is the query prefix.
function M.checkDomain(mail, domain, zones)
  local hits = {}
  if not domain or domain == "" then return hits end
  for _, z in ipairs(zones or {}) do
    local zone = type(z) == "string" and { zone = z, score = 3 } or z
    local answers = mail:dnsA(domain .. "." .. zone.zone)
    for _, a in ipairs(answers or {}) do
      if a:match("^127%.") then hits[#hits + 1] = { zone = zone.zone, score = zone.score or 3, code = a } break end
    end
  end
  return hits
end

M.reversed = reversed

return M
