-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The mqttd service: an MQTT broker on port 1883. Settings in /etc/tsr/mqtt/mqtt.lua:
--   return { allowAnonymous = false, port = 1883, maxClients = 50,
--            acl = { sensor = { pub = { "home/+/+/state" }, sub = {} }, ["*"] = { pub = {}, sub = { "home/#" } } } }
-- Accounts: mqttctl user add <name>.  Retained messages are kept in /var/lib/tsr/mqtt/retained.lua across restarts.
local socket = require("tsr.inet.socket")
local packet = require("tsr.mqtt.packet")
local brokerMod = require("tsr.mqtt.broker")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("mqttd")

local M = {}

M.CONFIG = "/etc/tsr/mqtt/mqtt.lua"
M.USERS = "/etc/tsr/mqtt/users.db"
M.RETAINED = "/var/lib/tsr/mqtt/retained.lua"

M.TEMPLATE = [[
-- MQTT broker settings. After a change: svc restart mqttd
return {
  port = 1883,
  allowAnonymous = false,      -- true: devices may connect without a user name (a trusted LAN only)
  maxClients = 50,
  -- who may publish (pub) and subscribe (sub) to what; "*" is everybody not listed. No acl table = everybody logged in may do everything.
  -- acl = { ["*"] = { pub = {}, sub = { "home/#" } }, thermostat = { pub = { "home/+/thermostat/#" }, sub = { "home/+/thermostat/set" } } },
}
]]

local function loadConfig()
  local text = vfs.readFile(M.CONFIG)
  if not text then return {} end
  local chunk, err = load(text, "=mqtt.lua", "t", {})
  if not chunk then return nil, err end
  local ok, value = pcall(chunk)
  if not ok or type(value) ~= "table" then return nil, tostring(value) end
  return value
end
M.loadConfig = loadConfig

--- Serve one TCP connection.
function M.serve(broker, conn)
  local client = broker:open({
    send = function(bytes) local ok = conn:send(bytes, 5) return ok end,
    close = function() conn:close() end,
  })
  local first = true
  while client.state ~= "closed" do
    local timeout = first and 10 or ((client.keepalive > 0) and client.keepalive * 1.5 or nil)
    local p, why = packet.read(conn, timeout)
    if not p then
      -- a protocol error, a vanished device or silence
      broker:close(client, false)
      break
    end
    first = false
    broker:handle(client, p)
  end
  conn:close()
end

function M.main()
  local stack
  while true do
    local ok, s = pcall(socket.default)
    if ok then stack = s break end
    os.sleep(1)
  end
  local cfg, err = loadConfig()
  if not cfg then log.error("%s", "mqtt.lua: " .. tostring(err)) return end
  local broker = brokerMod.new({ allowAnonymous = cfg.allowAnonymous, users = brokerMod.users(M.USERS), acl = cfg.acl, maxClients = cfg.maxClients,
    now = function() return stack.clock() end, log = function(t) log.info("%s", t) end })
  broker:importRetained(vfs.readTable(M.RETAINED))
  M.broker = broker
  local listener = socket.tcp(stack)
  listener:bind(nil, cfg.port or 1883)
  local ok, lerr = listener:listen(16)
  if not ok then log.error("%s", "cannot listen: " .. tostring(lerr)) return end
  M.listener = listener
  local state = { running = true }
  M.state = state
  local jobs = {}
  for _ = 1, cfg.workers or 6 do
    jobs[#jobs + 1] = function()
      while state.running do
        local c = listener:accept(1)
        if c then pcall(M.serve, broker, c) end
      end
    end
  end
  jobs[#jobs + 1] = function()
    local lastSave, saved = 0, nil
    while state.running do
      broker:tick()
      for _, item in ipairs(broker:sys()) do
        for _, cl in pairs(broker.clients) do
          for filter in pairs(cl.subs) do
            if require("tsr.mqtt.topic").match(filter, item[1]) then
              cl.sink.send(packet.encode({ type = "publish", topic = item[1], payload = item[2], qos = 0 }))
              break
            end
          end
        end
      end
      local now = stack.clock()
      if now - lastSave > 60 then
        lastSave = now
        local snapshot = textutils.serialize(broker:exportRetained())
        if snapshot ~= saved then
          vfs.mkdirp("/var/lib/tsr/mqtt")
          vfs.writeFile(M.RETAINED, snapshot)
          saved = snapshot
        end
      end
      stack.wait(function() return not state.running end, 10)
    end
  end
  log.info("%s", ("MQTT broker on port %d"):format(cfg.port or 1883))
  parallel.waitForAny(table.unpack(jobs))
end

function M.stop()
  if M.state then M.state.running = false end
  if M.listener then M.listener:close() end
end

return M
