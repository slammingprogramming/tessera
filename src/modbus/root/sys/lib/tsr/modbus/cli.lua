-- SPDX-License-Identifier: AGPL-3.0-or-later
-- modbus read <host> coils|inputs|holding|registers <address> [count] [-u unit] [-p port]
-- modbus write <host> coil <address> on|off [-u unit] [-p port]
-- modbus write <host> register <address> <value...> [-u unit] [-p port]
-- modbus poll <host> coils|inputs|holding|registers <address> [count] [-n times] [-i seconds]
-- modbusctl init | status
local modbus = require("tsr.modbus")
local daemon = require("tsr.modbus.daemon")
local vfs = require("tsr.vfs")

local M = {}

local function defaultCtx(ctx)
  ctx = ctx or {}
  ctx.say = ctx.say or function(t) print(t) end
  ctx.err = ctx.err or ctx.say
  ctx.sleep = ctx.sleep or sleep
  if not ctx.stack then
    local ok, s = pcall(function() return require("tsr.inet.socket").default() end)
    if ok then ctx.stack = s end
  end
  return ctx
end

local function parse(args)
  local pos, opt = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-u" then i = i + 1 opt.unit = tonumber(args[i])
    elseif a == "-p" then i = i + 1 opt.port = tonumber(args[i])
    elseif a == "-n" then i = i + 1 opt.times = tonumber(args[i])
    elseif a == "-i" then i = i + 1 opt.interval = tonumber(args[i])
    else pos[#pos + 1] = a end
    i = i + 1
  end
  return pos, opt
end

local READERS = { coils = "readCoils", inputs = "readDiscrete", holding = "readHolding", registers = "readInput" }

local function show(ctx, kind, addr, values)
  for i, v in ipairs(values) do
    local text = type(v) == "boolean" and (v and "ON" or "off") or tostring(v)
    ctx.say(("%-9s %5d  %s"):format(kind, addr + i - 1, text))
  end
end

function M.run(args, ctx)
  ctx = defaultCtx(ctx)
  local sub = table.remove(args, 1)
  local pos, opt = parse(args)
  if not ctx.stack then ctx.err("the network is not running (svc start inetd)") return false end
  if sub == "read" or sub == "poll" then
    local host, kind, addr, count = pos[1], pos[2], tonumber(pos[3]), tonumber(pos[4]) or 1
    if not host or not READERS[kind or ""] or not addr then ctx.err("usage: modbus " .. sub .. " <host> coils|inputs|holding|registers <address> [count]") return false end
    local c, err = modbus.connect(ctx.stack, host, { port = opt.port, unit = opt.unit })
    if not c then ctx.err(tostring(err)) return false end
    local rounds = sub == "poll" and (opt.times or 10) or 1
    for round = 1, rounds do
      local values, why = c[READERS[kind]](c, addr, count)
      if not values then ctx.err(tostring(why)) c:close() return false end
      show(ctx, kind, addr, values)
      if round < rounds then ctx.sleep(opt.interval or 1) end
    end
    c:close()
    return true
  elseif sub == "write" then
    local host, kind, addr = pos[1], pos[2], tonumber(pos[3])
    if not host or not addr or (kind ~= "coil" and kind ~= "register") or not pos[4] then ctx.err("usage: modbus write <host> coil|register <address> <value...>") return false end
    local c, err = modbus.connect(ctx.stack, host, { port = opt.port, unit = opt.unit })
    if not c then ctx.err(tostring(err)) return false end
    local ok, why
    if kind == "coil" then
      local word = pos[4]:lower()
      local on = word == "on" or word == "1" or word == "true"
      if not on and word ~= "off" and word ~= "0" and word ~= "false" then c:close() ctx.err("a coil is set to on or off") return false end
      ok, why = c:writeCoil(addr, on)
    else
      local values = {}
      for i = 4, #pos do values[#values + 1] = tonumber(pos[i]) end
      for _, v in ipairs(values) do if not v then c:close() ctx.err("register values are numbers") return false end end
      if #values == 1 then ok, why = c:writeRegister(addr, values[1]) else ok, why = c:writeRegisters(addr, values) end
    end
    c:close()
    if not ok then ctx.err(tostring(why)) return false end
    ctx.say("ok")
    return true
  end
  ctx.err("usage: modbus read|write|poll ...")
  return false
end

function M.ctl(args, ctx)
  ctx = defaultCtx(ctx)
  local sub = table.remove(args, 1)
  if sub == "init" then
    if vfs.fs.exists(daemon.CONFIG) then ctx.err(daemon.CONFIG .. " exists already") return false end
    vfs.writeFile(daemon.CONFIG, daemon.TEMPLATE)
    ctx.say("wrote " .. daemon.CONFIG .. " - edit the address map, then: svc start modbusd")
    return true
  elseif sub == "status" or sub == nil then
    local cfg, err = daemon.loadConfig()
    if not cfg then ctx.err(tostring(err)) return false end
    local units, points = 0, 0
    for _, u in pairs(cfg.units or {}) do
      units = units + 1
      for _, t in pairs({ "coils", "inputs", "registers", "holding" }) do for _ in pairs(u[t] or {}) do points = points + 1 end end
    end
    ctx.say(("port %d, %d unit(s), %d point(s), %s, networks: %s"):format(cfg.port or 502, units, points, cfg.readonly and "read only" or "writable",
      (#(cfg.allow or {}) > 0) and table.concat(cfg.allow, ", ") or "ANYONE (set allow in the settings)"))
    if daemon.server then ctx.say(("running: %d request(s), %d write(s), %d error(s), %d refused"):format(daemon.server.stats.requests, daemon.server.stats.writes, daemon.server.stats.errors, daemon.server.stats.refused)) end
    return true
  end
  ctx.err("usage: modbusctl init | status")
  return false
end

return M
