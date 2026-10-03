-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A Modbus/TCP slave: makes the redstone ports and machines of this computer readable and settable by numbers, so that a control room (or a SCADA display) can
-- supervise a plant. The map says which address means what:
--   units = { [1] = {
--     coils     = { [0] = { rs = "back:red" },                       -- an output you can switch                (functions 1, 5, 15)
--                   [1] = { dev = "smelter", read = "machine.running", on = "machine.start", off = "machine.stop" } },
--     inputs    = { [0] = { rs = "left" } },                          -- an on/off sensor                        (function 2)
--     registers = { [0] = { dev = "tank", read = "fluid.percent", scale = 100 } },   -- a measurement 0..65535    (function 4)
--     holding   = { [0] = { var = "setpoint", init = 50 },            -- a value stored here, or an analog output (functions 3, 6, 16)
--                   [1] = { rs = "right", analog = true } },
--   } }
-- A point is { rs = port } (redstone), { dev = name, read = reading, on/off/act = action, scale = factor } (a HAL device), { var = name, init = value } (a stored value),
-- { const = value } (read only) or { read = function() ... end, write = function(value) ... end } (your own code).
-- Safety: allow = { "10.0.0.0/24" } lets only those networks in; readonly = true refuses every write.
local B = require("tsr.inet.bytes")
local modbus = require("tsr.modbus")

local M = {}
local Server = {}
Server.__index = Server

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function rd16(s, i) local a, b = s:byte(i, i + 1) if not b then return nil end return a * 256 + b end

---------------------------------------------------------------------------------------------------------------------
-- Points
---------------------------------------------------------------------------------------------------------------------

local function truthy(v)
  if type(v) == "number" then return v > 0 end
  return v == true
end

--- Make read/write functions from a point description. kind: "bit" or "word". env: rsio, devices (function -> list of HAL devices), vars (table).
local function compile(spec, kind, env, unitVars, isInput)
  if spec.read and type(spec.read) == "function" then
    return { read = spec.read, write = spec.write }
  end
  if spec.const ~= nil then
    return { read = function() return spec.const end }
  end
  if spec.var then
    if unitVars[spec.var] == nil then
      local init = spec.init
      if init == nil then if kind == "bit" then init = false else init = 0 end end
      unitVars[spec.var] = init
    end
    return { read = function() return unitVars[spec.var] end, write = function(v) unitVars[spec.var] = v return true end }
  end
  if spec.rs then
    local function port()
      local p, err = (env.rsio or require("tsrapps.rsio")).open(spec.rs, env.rsEnv)
      if not p then error(err, 0) end
      return p
    end
    local forInput = isInput and not spec.output
    return {
      read = function()
        local p = port()
        local v
        if forInput then v = p.getInput() else v = p.getOutput() end
        if kind == "bit" then return truthy(v) end
        if type(v) == "boolean" then return v and 15 or 0 end
        return v
      end,
      write = (not forInput) and function(v)
        local p = port()
        if kind == "bit" then p.set(v and true or false) else p.set(math.min(15, math.max(0, v))) end
        return true
      end or nil,
    }
  end
  if spec.dev then
    local function device()
      local d
      for _, x in ipairs(env.devices and env.devices() or {}) do if x.name == spec.dev then d = x break end end
      if not d then error("device " .. spec.dev .. " is not there", 0) end
      return d
    end
    local scale = spec.scale or 1
    return {
      read = function()
        local v = device():get(spec.read)
        if kind == "bit" then return truthy(v) end
        v = tonumber(v) or (v == true and 1 or 0)
        return math.floor(v * scale + 0.5)
      end,
      write = (spec.on or spec.act) and function(v)
        local d = device()
        local lead = spec.args or {}
        if kind == "bit" then
          if spec.on or spec.off then
            local action = v and spec.on or spec.off
            if not action then return false end
            return d:act(action, table.unpack(lead)) ~= nil
          end
          local args = { table.unpack(lead) }
          args[#args + 1] = v
          return d:act(spec.act, table.unpack(args)) ~= nil
        end
        local args = { table.unpack(lead) }
        args[#args + 1] = v / scale
        return d:act(spec.act, table.unpack(args)) ~= nil
      end or nil,
    }
  end
  error("a point needs rs, dev, var, const or read/write", 0)
end

local TABLES = { coils = { "bit", false }, inputs = { "bit", true }, registers = { "word", true }, holding = { "word", false } }

---------------------------------------------------------------------------------------------------------------------

--- cfg: units, readonly, allow, maxConnections, onWrite(unit, table, address, value). env (optional): rsio, rsEnv, devices.
function M.new(cfg, env)
  env = env or {}
  if not env.devices then
    env.devices = function()
      local now = os.clock()
      if not env.cached or now - (env.cachedAt or 0) > 5 then
        local ok, hal = pcall(require, "tsr.hal")
        env.cached = ok and hal.scan() or {}
        env.cachedAt = now
      end
      return env.cached
    end
  end
  local self = setmetatable({ cfg = cfg, env = env, units = {}, vars = {}, allow = {}, stats = { requests = 0, writes = 0, errors = 0, refused = 0 } }, Server)
  for id, unit in pairs(cfg.units or {}) do
    self.vars[id] = {}
    local u = {}
    for name, def in pairs(TABLES) do
      u[name] = {}
      for addr, spec in pairs(unit[name] or {}) do
        local ok, point = pcall(compile, spec, def[1], env, self.vars[id], def[2])
        if not ok then error(("unit %s %s[%s]: %s"):format(tostring(id), name, tostring(addr), tostring(point)), 0) end
        u[name][addr] = point
      end
    end
    self.units[id] = u
  end
  for _, c in ipairs(cfg.allow or {}) do
    local net, plen = B.cidr(c)
    if net then self.allow[#self.allow + 1] = { net, plen } end
  end
  return self
end

--- May this client address talk to us?
function Server:permits(ip)
  if #self.allow == 0 then return true end
  local n = type(ip) == "number" and ip or B.ip(ip or "")
  if not n then return false end
  for _, r in ipairs(self.allow) do if B.inNet(n, r[1], r[2]) then return true end end
  return false
end

local function exception(fn, code) return string.char(fn + 128, code) end

local function readPoint(pt)
  local ok, v = pcall(pt.read)
  if not ok then return nil end
  return v
end

--- Handle one request PDU for a unit. Returns the answer PDU.
function Server:request(unitId, pdu)
  self.stats.requests = self.stats.requests + 1
  local fn = pdu:byte(1)
  local unit = self.units[unitId]
  if not unit then return exception(fn or 0, 11) end
  local function fail(code) self.stats.errors = self.stats.errors + 1 return exception(fn, code) end
  local isWrite = fn == 5 or fn == 6 or fn == 15 or fn == 16
  if isWrite and self.cfg.readonly then self.stats.refused = self.stats.refused + 1 return fail(1) end
  local onWrite = self.cfg.onWrite
  if fn == 1 or fn == 2 or fn == 3 or fn == 4 then
    local addr, qty = rd16(pdu, 2), rd16(pdu, 4)
    if not addr or not qty or #pdu ~= 5 then return fail(3) end
    if qty < 1 or qty > modbus.LIMITS[fn] then return fail(3) end
    local points = unit[(fn == 1 and "coils") or (fn == 2 and "inputs") or (fn == 3 and "holding") or "registers"]
    local values = {}
    for i = 0, qty - 1 do
      local pt = points[addr + i]
      if not pt then return fail(2) end
      local v = readPoint(pt)
      if v == nil then return fail(4) end
      values[i + 1] = v
    end
    if fn <= 2 then
      local bits = {}
      for i, v in ipairs(values) do bits[i] = v and true or false end
      local data = modbus.bitsToBytes(bits)
      return string.char(fn, #data) .. data
    end
    local out = {}
    for i, v in ipairs(values) do out[i] = u16(math.min(65535, math.max(0, math.floor(v)))) end
    return string.char(fn, qty * 2) .. table.concat(out)
  elseif fn == 5 then
    local addr, value = rd16(pdu, 2), rd16(pdu, 4)
    if not addr or #pdu ~= 5 or (value ~= 0xFF00 and value ~= 0) then return fail(3) end
    local pt = unit.coils[addr]
    if not pt then return fail(2) end
    if not pt.write then return fail(2) end
    local ok, res = pcall(pt.write, value == 0xFF00)
    if not ok or res == false then return fail(4) end
    self.stats.writes = self.stats.writes + 1
    if onWrite then pcall(onWrite, unitId, "coil", addr, value == 0xFF00) end
    return pdu
  elseif fn == 6 then
    local addr, value = rd16(pdu, 2), rd16(pdu, 4)
    if not addr or #pdu ~= 5 then return fail(3) end
    local pt = unit.holding[addr]
    if not pt or not pt.write then return fail(2) end
    local ok, res = pcall(pt.write, value)
    if not ok or res == false then return fail(4) end
    self.stats.writes = self.stats.writes + 1
    if onWrite then pcall(onWrite, unitId, "register", addr, value) end
    return pdu
  elseif fn == 15 then
    local addr, qty, count = rd16(pdu, 2), rd16(pdu, 4), pdu:byte(6)
    if not addr or not qty or not count or qty < 1 or qty > modbus.LIMITS[15] or count ~= math.ceil(qty / 8) or #pdu ~= 6 + count then return fail(3) end
    local bits = modbus.bytesToBits(pdu:sub(7), qty)
    for i = 0, qty - 1 do
      local pt = unit.coils[addr + i]
      if not pt or not pt.write then return fail(2) end
    end
    for i = 0, qty - 1 do
      local ok, res = pcall(unit.coils[addr + i].write, bits[i + 1])
      if not ok or res == false then return fail(4) end
      if onWrite then pcall(onWrite, unitId, "coil", addr + i, bits[i + 1]) end
    end
    self.stats.writes = self.stats.writes + qty
    return string.char(15) .. u16(addr) .. u16(qty)
  elseif fn == 16 then
    local addr, qty, count = rd16(pdu, 2), rd16(pdu, 4), pdu:byte(6)
    if not addr or not qty or not count or qty < 1 or qty > modbus.LIMITS[16] or count ~= qty * 2 or #pdu ~= 6 + count then return fail(3) end
    for i = 0, qty - 1 do
      local pt = unit.holding[addr + i]
      if not pt or not pt.write then return fail(2) end
    end
    for i = 0, qty - 1 do
      local value = rd16(pdu, 7 + i * 2)
      local ok, res = pcall(unit.holding[addr + i].write, value)
      if not ok or res == false then return fail(4) end
      if onWrite then pcall(onWrite, unitId, "register", addr + i, value) end
    end
    self.stats.writes = self.stats.writes + qty
    return string.char(16) .. u16(addr) .. u16(qty)
  end
  return fail(1)
end

--- Serve one TCP connection until it ends.
function Server:serve(conn)
  local ip = conn:getpeername()
  if not self:permits(ip) then
    self.stats.refused = self.stats.refused + 1
    conn:close()
    return
  end
  while true do
    local tid, unit, pdu = modbus.readFrame(conn, self.cfg.idleTimeout or 60)
    if not tid then break end
    local answer = self:request(unit, pdu)
    local ok = conn:send(modbus.frame(tid, unit, answer), 5)
    if not ok then break end
  end
  conn:close()
end

return M
