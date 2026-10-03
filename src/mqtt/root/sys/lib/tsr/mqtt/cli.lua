-- SPDX-License-Identifier: AGPL-3.0-or-later
-- mqtt pub <host> <topic> <message> [-r] [-q 0|1] [-u user] [-P password] [-i clientid] [-p port]
-- mqtt sub <host> <filter> [-q 0|1] [-n count] [-t seconds] [-u user] [-P password] [-p port]      print messages as they arrive
-- mqttctl init | user list | user add <name> [password] | user del <name> | status
local mqtt = require("tsr.mqtt")
local daemon = require("tsr.mqtt.daemon")
local brokerMod = require("tsr.mqtt.broker")
local vfs = require("tsr.vfs")

local M = {}

local function defaultCtx(ctx)
  ctx = ctx or {}
  ctx.say = ctx.say or function(t) print(t) end
  ctx.err = ctx.err or ctx.say
  ctx.readPassword = ctx.readPassword or function(prompt) io.write(prompt) return read("*") end
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
    if a == "-r" then opt.retain = true
    elseif a == "-q" then i = i + 1 opt.qos = tonumber(args[i])
    elseif a == "-u" then i = i + 1 opt.username = args[i]
    elseif a == "-P" then i = i + 1 opt.password = args[i]
    elseif a == "-i" then i = i + 1 opt.clientId = args[i]
    elseif a == "-p" then i = i + 1 opt.port = tonumber(args[i])
    elseif a == "-n" then i = i + 1 opt.count = tonumber(args[i])
    elseif a == "-t" then i = i + 1 opt.timeout = tonumber(args[i])
    else pos[#pos + 1] = a end
    i = i + 1
  end
  return pos, opt
end

function M.run(args, ctx)
  ctx = defaultCtx(ctx)
  local sub = table.remove(args, 1)
  local pos, opt = parse(args)
  if not ctx.stack then ctx.err("the network is not running (svc start inetd)") return false end
  if sub == "pub" then
    if #pos < 3 then ctx.err("usage: mqtt pub <host> <topic> <message> [-r] [-q 0|1] [-u user] [-P password]") return false end
    local c, err = mqtt.connect(ctx.stack, pos[1], { port = opt.port, username = opt.username, password = opt.password, clientId = opt.clientId })
    if not c then ctx.err(tostring(err)) return false end
    local ok, perr = c:publish(pos[2], table.concat(pos, " ", 3), { qos = opt.qos, retain = opt.retain })
    c:disconnect()
    if not ok then ctx.err(tostring(perr)) return false end
    return true
  elseif sub == "sub" then
    if #pos < 2 then ctx.err("usage: mqtt sub <host> <filter> [-q 0|1] [-n count] [-t seconds]") return false end
    local c, err = mqtt.connect(ctx.stack, pos[1], { port = opt.port, username = opt.username, password = opt.password, clientId = opt.clientId })
    if not c then ctx.err(tostring(err)) return false end
    local granted, serr = c:subscribe(pos[2], opt.qos or 0)
    if not granted then c:disconnect() ctx.err(tostring(serr)) return false end
    local seen = 0
    local deadline = opt.timeout and (ctx.stack.clock() + opt.timeout)
    while true do
      local left = deadline and (deadline - ctx.stack.clock()) or 30
      if left <= 0 then break end
      local m, why = c:receive(left)
      if m then
        ctx.say(("%s %s"):format(m.topic, m.payload))
        seen = seen + 1
        if opt.count and seen >= opt.count then break end
      elseif why ~= "timeout" then ctx.err(tostring(why)) break
      elseif deadline then break end
    end
    c:disconnect()
    return seen > 0 or opt.timeout ~= nil
  end
  ctx.err("usage: mqtt pub|sub ...")
  return false
end

function M.ctl(args, ctx)
  ctx = defaultCtx(ctx)
  local sub = table.remove(args, 1)
  local users = brokerMod.users(daemon.USERS)
  if sub == "init" then
    if vfs.fs.exists(daemon.CONFIG) then ctx.err(daemon.CONFIG .. " exists already") return false end
    vfs.mkdirp("/etc/tsr/mqtt")
    vfs.writeFile(daemon.CONFIG, daemon.TEMPLATE)
    ctx.say("wrote " .. daemon.CONFIG .. "; add users with: mqttctl user add <name>, then: svc start mqttd")
    return true
  elseif sub == "user" then
    local action = table.remove(args, 1) or "list"
    if action == "list" then
      local list = users:list()
      if #list == 0 then ctx.say("no users (mqttctl user add <name>)") end
      for _, n in ipairs(list) do ctx.say(n) end
      return true
    elseif action == "add" then
      local name, pw = args[1], args[2]
      if not name then ctx.err("usage: mqttctl user add <name> [password]") return false end
      if not pw then
        pw = ctx.readPassword("Password: ")
        if ctx.readPassword("Again: ") ~= pw then ctx.err("the passwords differ") return false end
      end
      local ok, err = users:add(name, pw)
      if not ok then ctx.err(tostring(err)) return false end
      ctx.say("user " .. name .. " saved")
      return true
    elseif action == "del" then
      local ok, err = users:remove(args[1] or "")
      if not ok then ctx.err(tostring(err)) return false end
      ctx.say("user removed")
      return true
    end
  elseif sub == "status" or sub == nil then
    local cfg = daemon.loadConfig() or {}
    ctx.say(("port %d, anonymous devices %s, %d user(s)"):format(cfg.port or 1883, cfg.allowAnonymous and "allowed" or "refused", #users:list()))
    local b = daemon.broker
    if b then
      ctx.say(("running: %d client(s), %d messages received, %d sent"):format(b.stats.connected, b.stats.received, b.stats.sent))
    else
      ctx.say("the broker runs in the mqttd service (svc status mqttd)")
    end
    return true
  end
  ctx.err("usage: mqttctl init | user list|add|del | status")
  return false
end

return M
