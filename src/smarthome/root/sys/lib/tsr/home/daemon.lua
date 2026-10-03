-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The homed service: runs the schedule of scenes and, when an MQTT broker is configured, keeps the broker informed about every device and obeys the "set" topics.
local home = require("tsr.home")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("homed")

local M = {}

M.CONFIG = "/etc/tsr/home.lua"

M.TEMPLATE = [[
-- Smart home. After a change: svc restart homed
-- Devices are named hardware (hal list shows what there is; declare redstone-only things with: hal virtual add ...).
return {
  clock = "ingame",                      -- "ingame" (Minecraft time of day) or "local" (the real clock) for the schedule
  devices = {
    -- ["kitchen-light"] = { room = "kitchen", kind = "light", dev = "lamp1" },
    -- ["front-door"] = { room = "hall", kind = "door", dev = "doorrelay", on = { "redstone.set", "top", 15 }, off = { "redstone.set", "top", 0 } },
    -- ["cellar-tank"] = { room = "cellar", kind = "sensor", dev = "gauge", read = "sensor.value", unit = "%" },
  },
  scenes = {
    -- night = { ["kitchen-light"] = "off", ["front-door"] = "closed" },
  },
  schedule = {
    -- { at = "22:30", scene = "night" },
  },
  -- mqtt = { host = "10.0.0.5", username = "home", password = "secret", prefix = "home" },
}
]]

function M.loadConfig()
  local text = vfs.readFile(M.CONFIG)
  if not text then return nil, M.CONFIG .. " does not exist (home init)" end
  local chunk, err = load(text, "=home.lua", "t", {})
  if not chunk then return nil, err end
  local ok, value = pcall(chunk)
  if not ok or type(value) ~= "table" then return nil, tostring(value) end
  return value
end

local DAYS = { "sun", "mon", "tue", "wed", "thu", "fri", "sat" }

--- The clock the schedule uses: { hour, min, day, date }.
function M.clock(kind)
  if kind == "local" and os.date then
    local t = os.date("*t")
    return { hour = t.hour, min = t.min, day = DAYS[t.wday], date = ("%04d-%02d-%02d"):format(t.year, t.month, t.day) }
  end
  local h = os.time("ingame")
  local day = os.day("ingame")
  return { hour = math.floor(h), min = math.floor((h % 1) * 60), day = DAYS[day % 7 + 1], date = "day" .. day }
end

function M.main()
  local cfg, err = M.loadConfig()
  if not cfg then log.error("%s", tostring(err)) return end
  local okH, hal = pcall(require, "tsr.hal")
  local env = {
    devices = function()
      local now = os.clock()
      if not M.cache or now - M.cacheAt > 2 then M.cache = okH and hal.scan() or {} M.cacheAt = now end
      return M.cache
    end,
    now = function() return M.clock(cfg.clock) end,
  }
  local okN, hub = pcall(home.new, cfg, env)
  if not okN then log.error("%s", tostring(hub)) return end
  M.hub = hub
  M.running = true
  local jobs = {
    function()
      while M.running do
        for _, scene in ipairs(hub:tick()) do log.info("%s", "scene " .. scene) end
        sleep(15)
      end
    end,
  }
  if cfg.mqtt and cfg.mqtt.host then
    jobs[#jobs + 1] = function()
      local mqtt = require("tsr.mqtt")
      local socket = require("tsr.inet.socket")
      while M.running do
        local stack = socket.default()
        local c, cerr = mqtt.connect(stack, cfg.mqtt.host, { clientId = "homed", username = cfg.mqtt.username, password = cfg.mqtt.password, port = cfg.mqtt.port,
          will = { topic = (cfg.mqtt.prefix or "home") .. "/hub/online", payload = "0", retain = true } })
        if c then
          log.info("%s", "connected to the MQTT broker at " .. cfg.mqtt.host)
          c:publish((cfg.mqtt.prefix or "home") .. "/hub/online", "1", { retain = true })
          hub:subscribe(c)
          hub:publishChanges(c, true)
          while M.running do
            local m, why = c:receive(2)
            if m then
              local done = hub:onMessage(m)
              if done then log.info("%s", "mqtt: " .. done) end
            elseif why ~= "timeout" then break end
            hub:publishChanges(c)
          end
          pcall(c.disconnect, c)
        else
          log.warn("%s", "MQTT: " .. tostring(cerr))
        end
        sleep(10)
      end
    end
  end
  parallel.waitForAny(table.unpack(jobs))
end

function M.stop() M.running = false end

return M
