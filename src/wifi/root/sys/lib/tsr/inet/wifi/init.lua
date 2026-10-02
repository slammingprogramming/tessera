-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Wi-Fi for the network stack. A station (wlan0) is configured in /etc/tsr/inet/network.lua:
--   wlan0 = { modem = "top", wifi = { ssid = "home", passphrase = "correct horse", channels = { 1, 6, 11 } }, dhcp = true }
-- An access point is configured in /etc/tsr/inet/wifi-ap.lua (see tsr.inet.wifi.ap).
local Sta = require("tsr.inet.wifi.sta")

local M = {}

--- Create the interface for a station and start listening. The wifid service runs the connection loop (sta:run()).
function M.attachStation(stack, name, spec)
  local w = spec.wifi or {}
  local sta = Sta.new(stack, {
    name = name, modem = spec.modem, modemName = spec.modem, ssid = w.ssid, passphrase = w.passphrase, channels = w.channels, mac = spec.mac,
    bssid = w.bssid, iterations = w.iterations, roamThreshold = w.roamThreshold, roamMargin = w.roamMargin,
  })
  stack.wifiStations = stack.wifiStations or {}
  stack.wifiStations[name] = sta
  if spec.dhcp then stack.dhcpWanted = stack.dhcpWanted or {} stack.dhcpWanted[name] = true end
  sta:start()
  return sta
end

return M
