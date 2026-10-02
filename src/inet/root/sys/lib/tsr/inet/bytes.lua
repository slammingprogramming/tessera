-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Byte-level helpers for the network stack: big-endian integers, the Internet checksum (RFC 1071), IPv4 and MAC address text forms,
-- CIDR arithmetic. Addresses are Lua numbers (IPv4: 0..2^32-1) or 6-byte strings (MAC).
local M = {}

local sbyte, schar, floor = string.byte, string.char, math.floor
local concat = table.concat

M.TWO32 = 4294967296

function M.u16(n) return schar(floor(n / 256) % 256, n % 256) end
function M.u32(n) return schar(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256) end

--- Read a big-endian 16/32-bit number at position i of string s (1-based). Returns nil if the string is too short.
function M.rd16(s, i)
  local a, b = sbyte(s, i, i + 1)
  if not b then return nil end
  return a * 256 + b
end

function M.rd32(s, i)
  local a, b, c, d = sbyte(s, i, i + 3)
  if not d then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

--- The Internet checksum of `data` (RFC 1071): one's complement of the one's complement sum of 16-bit words. `init` is a partial sum
--- (for pseudo headers). Returns the 16-bit checksum to store; a packet that includes its checksum sums to 0 when intact.
function M.sum(data, init)
  local sum = init or 0
  local len = #data
  local i = 1
  while i + 7 <= len do
    local a, b, c, d, e, f, g, h = sbyte(data, i, i + 7)
    sum = sum + (a * 256 + b) + (c * 256 + d) + (e * 256 + f) + (g * 256 + h)
    i = i + 8
  end
  while i + 1 <= len do
    local a, b = sbyte(data, i, i + 1)
    sum = sum + a * 256 + b
    i = i + 2
  end
  if i == len then sum = sum + sbyte(data, i) * 256 end
  return sum
end

function M.fold(sum)
  while sum >= 65536 do sum = floor(sum / 65536) + sum % 65536 end
  return sum
end

function M.checksum(data, init)
  return 65535 - M.fold(M.sum(data, init))
end

---------------------------------------------------------------------------------------------------------------------
-- IPv4 addresses
---------------------------------------------------------------------------------------------------------------------

--- "10.0.0.1" -> 167772161, or nil when the text is not a dotted quad.
function M.ip(text)
  if type(text) == "number" then return text end
  if type(text) ~= "string" then return nil end
  local a, b, c, d = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

function M.ipStr(n)
  if n == nil then return "?" end
  return ("%d.%d.%d.%d"):format(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

--- The netmask for a prefix length (0..32) as a number.
function M.mask(plen)
  if plen <= 0 then return 0 end
  if plen >= 32 then return M.TWO32 - 1 end
  return M.TWO32 - 2 ^ (32 - plen)
end

--- Bitwise AND of two 32-bit numbers (bit32 is available in ComputerCraft; this keeps results non-negative).
function M.band(a, b) return bit32.band(a, b) end
function M.bor(a, b) return bit32.bor(a, b) end
function M.bnot(a) return bit32.bnot(a) end

--- "10.0.0.0/24" -> network number, prefix length. A bare address is /32. Returns nil for bad input.
function M.cidr(text)
  local addr, plen = tostring(text):match("^([%d%.]+)/(%d+)$")
  if not addr then addr, plen = tostring(text):match("^([%d%.]+)$"), "32" end
  local ip = addr and M.ip(addr)
  plen = tonumber(plen)
  if not ip or not plen or plen > 32 then return nil end
  return M.band(ip, M.mask(plen)), plen
end

function M.cidrStr(net, plen) return M.ipStr(net) .. "/" .. plen end

function M.inNet(ip, net, plen) return M.band(ip, M.mask(plen)) == net end

--- The broadcast address of net/plen.
function M.broadcast(net, plen) return M.bor(net, M.bnot(M.mask(plen))) end

--- Dotted-quad mask "255.255.255.0" -> 24, or nil when it is not a contiguous mask.
function M.maskToPrefix(text)
  local m = M.ip(text)
  if not m then return nil end
  for plen = 0, 32 do if M.mask(plen) == m then return plen end end
  return nil
end

function M.isMulticast(ip) return ip >= 3758096384 and ip <= 4026531839 end      -- 224.0.0.0/4
function M.isLoopback(ip) return floor(ip / 16777216) == 127 end
function M.isPrivate(ip)
  local a, b = floor(ip / 16777216), floor(ip / 65536) % 256
  return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
end

M.BROADCAST = M.TWO32 - 1        -- 255.255.255.255
M.ANY = 0

---------------------------------------------------------------------------------------------------------------------
-- MAC addresses
---------------------------------------------------------------------------------------------------------------------

M.MAC_BROADCAST = "\255\255\255\255\255\255"

--- "02:00:5e:00:00:01" -> 6 raw bytes (or nil).
function M.mac(text)
  if type(text) == "string" and #text == 6 and not text:find(":", 1, true) then return text end
  local parts = {}
  for h in tostring(text):gmatch("(%x%x)") do parts[#parts + 1] = schar(tonumber(h, 16)) end
  if #parts ~= 6 or not tostring(text):match("^%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x$") then return nil end
  return concat(parts)
end

function M.macStr(raw)
  if not raw or #raw ~= 6 then return "??:??:??:??:??:??" end
  local a, b, c, d, e, f = sbyte(raw, 1, 6)
  return ("%02x:%02x:%02x:%02x:%02x:%02x"):format(a, b, c, d, e, f)
end

function M.isBroadcastMac(raw) return raw == M.MAC_BROADCAST end
function M.isMulticastMac(raw) return sbyte(raw, 1) % 2 == 1 end

--- A locally administered unicast MAC (02:...) built from numbers, e.g. computer id and interface index.
function M.makeMac(a, b, c)
  return schar(2, 0x54, floor(a / 256) % 256, a % 256, (b or 0) % 256, (c or 0) % 256)
end

---------------------------------------------------------------------------------------------------------------------
-- Hex dump (for capture output)
---------------------------------------------------------------------------------------------------------------------

function M.hex(s, limit)
  local out = {}
  for i = 1, math.min(#s, limit or #s) do out[#out + 1] = ("%02x"):format(sbyte(s, i)) end
  return concat(out)
end

--- Sequence number arithmetic modulo 2^32 (TCP): is a before b, a before-or-equal b, difference.
function M.seqLt(a, b) return a ~= b and (b - a) % M.TWO32 < 2147483648 end
function M.seqLe(a, b) return a == b or (b - a) % M.TWO32 < 2147483648 end
function M.seqAdd(a, n) return (a + n) % M.TWO32 end
function M.seqDiff(a, b) return (a - b) % M.TWO32 end            -- how far a is ahead of b (assuming a >= b)

return M
