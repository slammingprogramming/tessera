-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Services: wifid (keeps stations connected) and wifiap (runs the access points of /etc/tsr/inet/wifi-ap.lua).
local socket = require("tsr.inet.socket")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("wifi")

local M = {}

M.AP_CONFIG = "/etc/tsr/inet/wifi-ap.lua"
M.aps = {}

local function waitForStack()
  while true do
    local ok, stack = pcall(socket.default)
    if ok then return stack end
    os.sleep(1)
  end
end

function M.stations()
  local stack = waitForStack()
  while true do
    local jobs = {}
    for name, sta in pairs(stack.wifiStations or {}) do
      sta.onConnect = function(ap) log.info("%s joined %s", name, tostring(ap.ssid)) end
      sta.onLost = function(why) log.warn("%s lost the network: %s", name, tostring(why)) end
      jobs[#jobs + 1] = function() sta:run() end
    end
    if #jobs == 0 then os.sleep(5) else parallel.waitForAny(table.unpack(jobs)) end
  end
end

function M.accessPoints()
  local stack = waitForStack()
  local text = vfs.readFile(M.AP_CONFIG)
  if not text then log.warn("%s", "no " .. M.AP_CONFIG .. ": no access point to run") return end
  local chunk, err = load(text, "=wifi-ap.lua", "t", {})
  local cfg
  if chunk then local ok, value = pcall(chunk) cfg = ok and value or nil err = err or value end
  if type(cfg) ~= "table" then log.error("%s", "wifi-ap.lua: " .. tostring(err)) return end
  if cfg.ssid then cfg = { cfg } end
  local apMod = require("tsr.inet.wifi.ap")
  for _, c in ipairs(cfg) do
    local ok, ap = pcall(apMod.new, stack, c)
    if ok then
      ap:start()
      M.aps[#M.aps + 1] = ap
      log.info("%s", "access point " .. c.ssid .. " on channel " .. tostring(c.channel or 1))
    else
      log.error("%s", "access point: " .. tostring(ap))
    end
  end
  while true do os.sleep(10) end
end

return M
