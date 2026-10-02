-- SPDX-License-Identifier: AGPL-3.0-or-later
-- DHCP messages (RFC 2131) and options (RFC 2132): the BOOTP header, the magic cookie and the option list.
local B = require("tsr.inet.bytes")

local M = {}

M.CLIENT_PORT, M.SERVER_PORT = 68, 67
M.COOKIE = "\99\130\83\99"

M.DISCOVER, M.OFFER, M.REQUEST, M.DECLINE, M.ACK, M.NAK, M.RELEASE, M.INFORM = 1, 2, 3, 4, 5, 6, 7, 8
M.TYPE_NAMES = { "DISCOVER", "OFFER", "REQUEST", "DECLINE", "ACK", "NAK", "RELEASE", "INFORM" }

-- option code -> { name, kind }; kind: "ip" (one address), "ips" (list), "str", "u8", "u16", "u32", "bytes"
M.OPTIONS = {
  [1] = { "subnetMask", "ip" }, [3] = { "routers", "ips" }, [6] = { "dns", "ips" }, [12] = { "hostname", "str" }, [15] = { "domain", "str" },
  [26] = { "mtu", "u16" }, [28] = { "broadcast", "ip" }, [42] = { "ntp", "ips" }, [50] = { "requestedIp", "ip" }, [51] = { "leaseTime", "u32" },
  [53] = { "type", "u8" }, [54] = { "serverId", "ip" }, [55] = { "paramList", "bytes" }, [56] = { "message", "str" }, [58] = { "renewalTime", "u32" },
  [59] = { "rebindingTime", "u32" }, [61] = { "clientId", "bytes" }, [119] = { "searchList", "str" },
}
M.BY_NAME = {}
for code, o in pairs(M.OPTIONS) do M.BY_NAME[o[1]] = code end

local function encodeOption(code, kind, v)
  local data
  if kind == "ip" then data = B.u32(v)
  elseif kind == "ips" then
    local t = {}
    for _, ip in ipairs(v) do t[#t + 1] = B.u32(ip) end
    data = table.concat(t)
  elseif kind == "str" or kind == "bytes" then data = v
  elseif kind == "u8" then data = string.char(v)
  elseif kind == "u16" then data = B.u16(v)
  elseif kind == "u32" then data = B.u32(v)
  end
  return string.char(code, #data) .. data
end

local function decodeOption(kind, data)
  if kind == "ip" then return B.rd32(data, 1)
  elseif kind == "ips" then
    local t = {}
    for i = 1, #data - 3, 4 do t[#t + 1] = B.rd32(data, i) end
    return t
  elseif kind == "u8" then return data:byte(1)
  elseif kind == "u16" then return B.rd16(data, 1)
  elseif kind == "u32" then return B.rd32(data, 1)
  end
  return data
end

--- m: op (1 request, 2 reply), xid, secs, broadcast (bool), ciaddr, yiaddr, siaddr, giaddr, chaddr (6 bytes), options = { type = 1, routers = {..}, ... }
function M.encode(m)
  local head = string.char(m.op, 1, 6, m.hops or 0) .. B.u32(m.xid) .. B.u16(m.secs or 0) .. B.u16(m.broadcast and 0x8000 or 0)
    .. B.u32(m.ciaddr or 0) .. B.u32(m.yiaddr or 0) .. B.u32(m.siaddr or 0) .. B.u32(m.giaddr or 0)
    .. m.chaddr .. string.rep("\0", 10) .. string.rep("\0", 64) .. string.rep("\0", 128) .. M.COOKIE
  local opts = {}
  local names = {}
  for name in pairs(m.options or {}) do names[#names + 1] = name end
  table.sort(names, function(a, b) return (M.BY_NAME[a] or 999) < (M.BY_NAME[b] or 999) end)
  -- the message type goes first, as real implementations do
  if m.options and m.options.type then opts[#opts + 1] = encodeOption(53, "u8", m.options.type) end
  for _, name in ipairs(names) do
    local code = M.BY_NAME[name]
    if code and name ~= "type" then opts[#opts + 1] = encodeOption(code, M.OPTIONS[code][2], m.options[name]) end
  end
  if m.rawOptions then for _, r in ipairs(m.rawOptions) do opts[#opts + 1] = string.char(r[1], #r[2]) .. r[2] end end
  opts[#opts + 1] = "\255"
  local out = head .. table.concat(opts)
  if #out < 300 then out = out .. string.rep("\0", 300 - #out) end       -- BOOTP minimum size
  return out
end

function M.decode(data)
  if #data < 240 then return nil, "short DHCP message" end
  if data:sub(237, 240) ~= M.COOKIE then return nil, "no DHCP cookie" end
  local m = {
    op = data:byte(1), hops = data:byte(4), xid = B.rd32(data, 5), secs = B.rd16(data, 9), broadcast = B.rd16(data, 11) >= 0x8000,
    ciaddr = B.rd32(data, 13), yiaddr = B.rd32(data, 17), siaddr = B.rd32(data, 21), giaddr = B.rd32(data, 25), chaddr = data:sub(29, 34),
    options = {}, unknown = {},
  }
  local i = 241
  while i <= #data do
    local code = data:byte(i)
    if code == 255 then break end
    if code == 0 then i = i + 1 else
      local len = data:byte(i + 1)
      if not len or i + 1 + len > #data then return nil, "damaged option list" end
      local raw = data:sub(i + 2, i + 1 + len)
      local def = M.OPTIONS[code]
      if def then m.options[def[1]] = decodeOption(def[2], raw) else m.unknown[code] = raw end
      i = i + 2 + len
    end
  end
  return m
end

return M
