-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The wifi command:
--   wifi scan [iface]                         list the networks in range
--   wifi connect <ssid> [passphrase] [iface]  join a network (`ip save` keeps it in /etc/tsr/inet/network.lua)
--   wifi disconnect [iface]                   wifi status
--   wifi ap status | clients | kick <mac> | stop
local B = require("tsr.inet.bytes")

local M = {}

local function defaultCtx(ctx)
  ctx = ctx or {}
  if not ctx.say then
    ctx.say = function(t) print(t) end
    ctx.err = function(t) print(t) end
  end
  ctx.err = ctx.err or ctx.say
  if not ctx.stack then
    local ok, stack = pcall(function() return require("tsr.inet.socket").default() end)
    if not ok then ctx.err(tostring(stack)) return nil end
    ctx.stack = stack
  end
  return ctx
end

local function station(ctx, name)
  local list = ctx.stack.wifiStations or {}
  if name then return list[name] end
  local first
  for n, s in pairs(list) do if not first or n < first.name then first = s end end
  return first
end

local function bars(signal)
  local n = math.max(0, math.min(4, math.floor(signal / 25)))
  return string.rep("#", n) .. string.rep(".", 4 - n)
end

function M.run(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local sub = args[1] or "status"
  if sub == "ap" then
    local apd = ctx.aps or require("tsr.inet.wifi.daemon").aps
    local what = args[2] or "status"
    if #apd == 0 then ctx.err("no access point runs on this computer (service wifiap)") return false end
    for _, ap in ipairs(apd) do
      if what == "status" then
        ctx.say(("%s: channel %d, %s, %d client(s), bssid %s%s"):format(ap.ssid, ap.channel, ap.security == 1 and "WPA-PSK" or "open", ap:clientCount(), B.macStr(ap.bssid), ap.cfg.hidden and ", hidden" or ""))
        ctx.say(("    beacons %d, probes %d, associations %d, refused %d, handshake failures %d"):format(ap.stats.beacons, ap.stats.probes, ap.stats.assoc, ap.stats.refused, ap.stats.handshakeFailures))
      elseif what == "clients" then
        for _, c in ipairs(ap:clientList()) do ctx.say(("%s  %-12s aid %s  signal %s%%  idle %ds"):format(B.macStr(c.mac), c.state, tostring(c.aid or "-"), tostring(c.signal or "?"), math.floor(c.idle))) end
      elseif what == "kick" then
        local mac = B.mac(args[3] or "")
        if not mac then ctx.err("usage: wifi ap kick <mac>") return false end
        ap:kick(mac)
        ctx.say("sent " .. B.macStr(mac) .. " away")
      elseif what == "stop" then ap:stop() ctx.say(ap.ssid .. " stopped")
      else ctx.err("usage: wifi ap status|clients|kick <mac>|stop") return false end
    end
    return true
  end
  local sta
  if sub == "scan" then
    sta = station(ctx, args[2])
    if not sta then ctx.err("no Wi-Fi interface (give a modem a `wifi = {...}` entry in /etc/tsr/inet/network.lua)") return false end
    ctx.say("Scanning...")
    local list = sta:scan()
    if #list == 0 then ctx.say("no networks found") return true end
    for _, n in ipairs(list) do
      ctx.say(("%-22s %-6s ch %-2d %s  %s  %s"):format(n.ssid ~= "" and n.ssid or "(hidden)", n.security, n.channel, bars(n.signal), B.macStr(n.bssid), n.signal .. "%"))
    end
    return true
  elseif sub == "connect" then
    local ssid, pass, name = args[2], args[3], args[4]
    if not ssid then ctx.err("usage: wifi connect <ssid> [passphrase] [iface]") return false end
    sta = station(ctx, name)
    if not sta then ctx.err("no Wi-Fi interface") return false end
    sta.cfg.ssid, sta.cfg.passphrase = ssid, pass
    sta:disconnect()
    local ok, err = sta:connect(ssid, pass)
    if not ok then ctx.err("could not join " .. ssid .. ": " .. tostring(err)) return false end
    ctx.say("connected to " .. ssid .. " (" .. B.macStr(sta.ap.bssid) .. ", channel " .. sta.ap.channel .. ")")
    return true
  elseif sub == "disconnect" then
    sta = station(ctx, args[2])
    if not sta then ctx.err("no Wi-Fi interface") return false end
    sta.cfg.ssid = nil
    sta:disconnect()
    ctx.say("disconnected")
    return true
  elseif sub == "status" then
    local any = false
    for name, s in pairs(ctx.stack.wifiStations or {}) do
      any = true
      local st = s:status()
      if st.state == "connected" then
        ctx.say(("%s: connected to %s (%s) channel %d, %s, signal %s%%"):format(name, st.ssid, B.macStr(st.bssid), st.channel, st.security, tostring(st.signal or "?")))
      else
        ctx.say(("%s: %s%s"):format(name, st.state, s.cfg.ssid and (", looking for " .. s.cfg.ssid) or ""))
      end
    end
    if not any then ctx.say("no Wi-Fi interface") end
    return true
  end
  ctx.err("usage: wifi scan | connect <ssid> [passphrase] | disconnect | status | ap ...")
  return false
end

return M
