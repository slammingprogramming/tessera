-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Modbus/TCP: the plain, old protocol of industrial control. A master (a control room computer) reads and writes numbered coils (on/off outputs), discrete inputs
-- (on/off sensors), holding registers (16-bit values it may set) and input registers (16-bit measurements) of slave devices ("units").
-- This file: the message format (MBAP header + PDU) and a client. tsr.modbus.server makes a computer a slave that exposes redstone and machines.
--   local c = modbus.connect(stack, "10.0.0.7", { unit = 1 })
--   c:readCoils(0, 8)  c:readInputRegisters(0, 2)  c:writeCoil(3, true)  c:writeRegister(0, 1500)   -- each returns a value / table, or nil + reason
local socket = require("tsr.inet.socket")

local M = {}
local Client = {}
Client.__index = Client

M.TIMEOUT = 5
M.MAX_FRAME = 260

M.FUNCTIONS = { readCoils = 1, readDiscrete = 2, readHolding = 3, readInput = 4, writeCoil = 5, writeRegister = 6, writeCoils = 15, writeRegisters = 16 }
M.EXCEPTIONS = { [1] = "illegal function", [2] = "illegal data address", [3] = "illegal data value", [4] = "device failure", [6] = "device busy" }
M.LIMITS = { [1] = 2000, [2] = 2000, [3] = 125, [4] = 125, [15] = 1968, [16] = 123 }

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function rd16(s, i) local a, b = s:byte(i, i + 1) if not b then return nil end return a * 256 + b end

--- A TCP frame: transaction id, unit, PDU (function code + data).
function M.frame(tid, unit, pdu)
  return u16(tid) .. u16(0) .. u16(#pdu + 1) .. string.char(unit) .. pdu
end

--- Read one frame from a socket. Returns tid, unit, pdu — or nil + reason.
function M.readFrame(sock, timeout)
  local head, err = sock:receive(7, timeout)
  if not head then return nil, err or "closed" end
  local tid, proto, len = rd16(head, 1), rd16(head, 3), rd16(head, 5)
  if proto ~= 0 then return nil, "not a Modbus frame" end
  if len < 2 or len > M.MAX_FRAME then return nil, "bad frame length" end
  local pdu, e2 = sock:receive(len - 1, timeout or M.TIMEOUT)
  if not pdu then return nil, e2 or "closed" end
  return tid, head:byte(7), pdu
end

local function bitsToBytes(bits)
  local out = {}
  for i = 1, math.ceil(#bits / 8) do
    local b = 0
    for j = 0, 7 do
      if bits[(i - 1) * 8 + j + 1] then b = b + 2 ^ j end
    end
    out[i] = string.char(b)
  end
  return table.concat(out)
end
M.bitsToBytes = bitsToBytes

local function bytesToBits(data, count)
  local bits = {}
  for i = 1, count do
    local byte = data:byte(math.floor((i - 1) / 8) + 1)
    if not byte then return nil end
    bits[i] = math.floor(byte / 2 ^ ((i - 1) % 8)) % 2 == 1
  end
  return bits
end
M.bytesToBits = bytesToBits

--- Connect. opts: port (502), unit (1), timeout.
function M.connect(stack, host, opts)
  opts = opts or {}
  local sock = socket.tcp(stack)
  local ok, err = sock:connect(host, opts.port or 502, opts.timeout or M.TIMEOUT)
  if not ok then return nil, "cannot connect to " .. tostring(host) .. ": " .. tostring(err) end
  return setmetatable({ sock = sock, unit = opts.unit or 1, tid = 0, timeout = opts.timeout or M.TIMEOUT }, Client)
end

--- Send a request PDU and return the answer PDU (or nil + reason; a Modbus exception becomes an error text).
function Client:request(pdu)
  self.tid = (self.tid + 1) % 65536
  local ok, err = self.sock:send(M.frame(self.tid, self.unit, pdu), self.timeout)
  if not ok then return nil, tostring(err) end
  local tid, unit, answer = M.readFrame(self.sock, self.timeout)
  if not tid then return nil, tostring(unit) end
  if tid ~= self.tid then return nil, "answer to another request" end
  local fn = pdu:byte(1)
  if answer:byte(1) == fn + 128 then
    local code = answer:byte(2)
    return nil, M.EXCEPTIONS[code] or ("exception " .. tostring(code)), code
  end
  if answer:byte(1) ~= fn then return nil, "unexpected answer" end
  return answer
end

local function readBits(self, fn, addr, count)
  if count < 1 or count > M.LIMITS[fn] then return nil, "bad count" end
  local a, why, code = self:request(string.char(fn) .. u16(addr) .. u16(count))
  if not a then return nil, why, code end
  local bits = bytesToBits(a:sub(3), count)
  if not bits or a:byte(2) ~= math.ceil(count / 8) then return nil, "damaged answer" end
  return bits
end

local function readWords(self, fn, addr, count)
  if count < 1 or count > M.LIMITS[fn] then return nil, "bad count" end
  local a, why, code = self:request(string.char(fn) .. u16(addr) .. u16(count))
  if not a then return nil, why, code end
  if a:byte(2) ~= count * 2 or #a ~= 2 + count * 2 then return nil, "damaged answer" end
  local out = {}
  for i = 1, count do out[i] = rd16(a, 3 + (i - 1) * 2) end
  return out
end

function Client:readCoils(addr, count) return readBits(self, 1, addr, count or 1) end
function Client:readDiscrete(addr, count) return readBits(self, 2, addr, count or 1) end
function Client:readHolding(addr, count) return readWords(self, 3, addr, count or 1) end
function Client:readInput(addr, count) return readWords(self, 4, addr, count or 1) end

function Client:writeCoil(addr, on)
  local a, why, code = self:request(string.char(5) .. u16(addr) .. (on and "\255\0" or "\0\0"))
  if not a then return nil, why, code end
  return true
end

function Client:writeRegister(addr, value)
  if value < 0 or value > 65535 or value ~= math.floor(value) then return nil, "a register holds 0..65535" end
  local a, why, code = self:request(string.char(6) .. u16(addr) .. u16(value))
  if not a then return nil, why, code end
  return true
end

function Client:writeCoils(addr, bits)
  if #bits < 1 or #bits > M.LIMITS[15] then return nil, "bad count" end
  local data = bitsToBytes(bits)
  local a, why, code = self:request(string.char(15) .. u16(addr) .. u16(#bits) .. string.char(#data) .. data)
  if not a then return nil, why, code end
  return true
end

function Client:writeRegisters(addr, values)
  if #values < 1 or #values > M.LIMITS[16] then return nil, "bad count" end
  local data = {}
  for i, v in ipairs(values) do
    if v < 0 or v > 65535 or v ~= math.floor(v) then return nil, "a register holds 0..65535" end
    data[i] = u16(v)
  end
  local a, why, code = self:request(string.char(16) .. u16(addr) .. u16(#values) .. string.char(#values * 2) .. table.concat(data))
  if not a then return nil, why, code end
  return true
end

function Client:close() self.sock:close() return true end

return M
