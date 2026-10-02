-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A Wi-Fi access point: announces a network name (SSID) with beacons, answers scans, authenticates and associates stations, runs the four-way
-- handshake for WPA2-style networks, and bridges the stations to the wired interfaces of this computer. Inside it is a switch (tsr.inet.switch):
-- every station is a port of it, so VLANs per SSID, client isolation, and managing the AP over IP all work the way they do on a switch.
--
--   local ap = require("tsr.inet.wifi.ap").new(stack, {
--     modem = "top", ssid = "home", channel = 6, security = "psk", passphrase = "correct horse",
--     bridge = { "eth0" },                   -- wired interfaces to join to the Wi-Fi (the LAN side)
--     vlan = 30,                             -- put this SSID in a VLAN (the wired port becomes a trunk for it)
--     isolate = true,                        -- stations cannot talk to each other
--     macFilter = { mode = "allow", list = { "02:54:00:01:00:05" } },
--     maxClients = 16, hidden = false, management = "10.0.0.5/24",
--   })
--   ap:start()
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wifi.frames")
local K = require("tsr.inet.wifi.keys")
local link = require("tsr.inet.link")
local switchMod = require("tsr.inet.switch")

local M = {}
local AP = {}
AP.__index = AP

local T, STATUS = W.TYPES, W.STATUS

function M.new(stack, cfg)
  assert(cfg.ssid and #cfg.ssid > 0 and #cfg.ssid <= 32, "the SSID must be 1 to 32 characters")
  local security = cfg.security or (cfg.passphrase and "psk" or "open")
  if security == "psk" then assert(cfg.passphrase and #cfg.passphrase >= 8, "a WPA passphrase needs at least 8 characters") end
  local self = setmetatable({
    stack = stack, cfg = cfg, ssid = cfg.ssid, channel = cfg.channel or 1, security = security == "psk" and W.SECURITY.PSK or W.SECURITY.OPEN,
    clients = {}, nextAid = 1, beaconInterval = cfg.beaconInterval or 1, maxClients = cfg.maxClients or 32, inactivity = cfg.inactivity or 120,
    stats = { beacons = 0, probes = 0, assoc = 0, refused = 0, handshakeFailures = 0, rx = 0, tx = 0, replays = 0 },
  }, AP)
  self.mchan = W.modemChannel(self.channel)
  self.bssid = cfg.mac and B.mac(cfg.mac) or B.makeMac(os.getComputerID and os.getComputerID() or 1, 77, 1)
  if security == "psk" then self.pmk = K.pmk(cfg.passphrase, cfg.ssid, cfg.iterations) end
  -- the bridge
  local ports = {}
  local trunk = cfg.vlan and cfg.trunk ~= false and cfg.vlan ~= 1
  for _, name in ipairs(cfg.bridge or {}) do
    if cfg.ports and cfg.ports[name] then ports[name] = cfg.ports[name]
    elseif cfg.vlan then ports[name] = trunk and { mode = "trunk", allowed = { cfg.vlan } } or { vlan = cfg.vlan }
    else ports[name] = {} end
  end
  self.switch = switchMod.new(stack, { name = cfg.ssid, ports = ports, stp = false, lldp = false })
  if cfg.management then self.switch:addSvi(cfg.vlan or 1, cfg.management) end
  return self
end

function AP:radio()
  if not self.modem then
    local m = self.cfg.modem
    self.modem = type(m) == "string" and peripheral.wrap(m) or m
  end
  return self.modem
end

function AP:send(msg)
  self.stats.tx = self.stats.tx + 1
  local m = self:radio()
  m.transmit(self.mchan, self.mchan, msg)
end

local function now(self) return self.stack.clock() end

function AP:allowed(mac)
  local f = self.cfg.macFilter
  if not f or not f.list or #f.list == 0 then return true end
  local listed = false
  for _, m in ipairs(f.list) do if B.mac(m) == mac then listed = true end end
  if f.mode == "deny" then return not listed end
  return listed
end

function AP:beaconBody()
  return W.encodeBeacon({ interval = math.floor(self.beaconInterval * 1000), channel = self.channel, security = self.security, hidden = self.cfg.hidden, ssid = self.ssid,
    load = self:clientCount(), timestamp = math.floor(now(self)) })
end

function AP:clientCount()
  local n = 0
  for _, c in pairs(self.clients) do if c.state == "connected" then n = n + 1 end end
  return n
end

function AP:clientList()
  local out = {}
  for mac, c in pairs(self.clients) do
    out[#out + 1] = { mac = mac, state = c.state, aid = c.aid, signal = c.signal, idle = now(self) - c.lastSeen }
  end
  table.sort(out, function(a, b) return a.mac < b.mac end)
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Clients
---------------------------------------------------------------------------------------------------------------------

function AP:drop(mac, reason, notify)
  local c = self.clients[mac]
  if not c then return false end
  if notify then self:send(W.header(T.DEAUTH, self.bssid, self.bssid, mac) .. W.encodeDeauth(reason)) end
  if c.port then self.switch:removePort(c.port.name) end
  self.clients[mac] = nil
  return true
end

function AP:kick(mac, reason) return self:drop(mac, reason or W.REASONS.KICKED, true) end

local function micInput(n, nonce) return string.char(n) .. (nonce or "") end

function AP:connectClient(c)
  c.state = "connected"
  self.stats.assoc = self.stats.assoc + 1
  local ap = self
  c.port = self.switch:addVirtualPort("sta-" .. B.macStr(c.mac):gsub(":", ""), {
    mac = c.mac, vlan = self.cfg.vlan or 1, isolated = self.cfg.isolate,
    send = function(frame) ap:sendData(c, frame) end,
  })
end

function AP:sendData(c, frame)
  local hdr = W.header(T.DATA_FROM_AP, self.bssid, self.bssid, c.mac)
  local body
  if self.security == W.SECURITY.PSK then
    c.pnTx = (c.pnTx or 0) + 1
    body = K.seal(c.ptk.tk, c.pnTx, 1, frame, hdr)
  else
    body = frame
  end
  self:send(hdr .. body)
end

function AP:handle(ev)
  local ch, message, distance = ev[3], ev[5], ev[6]
  if ch ~= self.mchan then return end
  local f = W.parse(message)
  if not f then return end
  self.stats.rx = self.stats.rx + 1
  local mine = f.bssid == self.bssid or f.bssid == B.MAC_BROADCAST
  local c = self.clients[f.src]
  if c then
    c.lastSeen = now(self)
    if distance then c.signal = math.max(0, math.floor(100 - distance * 100 / 64)) end
  end
  if f.type == T.PROBE_REQ then
    local want = W.decodeProbe(f.body)
    if want == "" and self.cfg.hidden then return end
    if want == "" or want == self.ssid then
      self.stats.probes = self.stats.probes + 1
      local body = W.encodeBeacon({ interval = math.floor(self.beaconInterval * 1000), channel = self.channel, security = self.security, ssid = self.ssid, load = self:clientCount() })
      self:send(W.header(T.PROBE_RESP, self.bssid, self.bssid, f.src) .. body)
    end
    return
  end
  if f.bssid ~= self.bssid then return end
  if f.type == T.AUTH then
    local a = W.decodeAuth(f.body)
    if a.seq ~= 1 then return end
    if not self:allowed(f.src) then
      self.stats.refused = self.stats.refused + 1
      self:send(W.header(T.AUTH, self.bssid, self.bssid, f.src) .. W.encodeAuth(2, STATUS.DENIED))
      return
    end
    -- a new authentication always starts from scratch (a station that reconnects, or retries after a failed handshake)
    if c then self:drop(f.src, nil, false) end
    self.clients[f.src] = { mac = f.src, state = "authenticated", lastSeen = now(self), signal = distance and math.max(0, math.floor(100 - distance * 100 / 64)) or 50 }
    self:send(W.header(T.AUTH, self.bssid, self.bssid, f.src) .. W.encodeAuth(2, STATUS.OK))
  elseif f.type == T.ASSOC_REQ then
    if not c or c.state ~= "authenticated" then return self:send(W.header(T.DEAUTH, self.bssid, self.bssid, f.src) .. W.encodeDeauth(W.REASONS.AUTH_FAILED)) end
    if W.decodeAssocReq(f.body) ~= self.ssid then
      return self:send(W.header(T.ASSOC_RESP, self.bssid, self.bssid, f.src) .. W.encodeAssocResp(STATUS.BAD_SSID))
    end
    if self:clientCount() >= self.maxClients then
      self.stats.refused = self.stats.refused + 1
      self:drop(f.src)
      return self:send(W.header(T.ASSOC_RESP, self.bssid, self.bssid, f.src) .. W.encodeAssocResp(STATUS.FULL))
    end
    c.aid = c.aid or self.nextAid
    if c.aid == self.nextAid then self.nextAid = self.nextAid + 1 end
    self:send(W.header(T.ASSOC_RESP, self.bssid, self.bssid, f.src) .. W.encodeAssocResp(STATUS.OK, c.aid))
    if self.security == W.SECURITY.PSK then
      c.state = "handshake"
      c.anonce = K.nonce()
      c.tries = 0
      self:send(W.header(T.EAPOL, self.bssid, self.bssid, f.src) .. W.encodeEapol(1, c.anonce))
    else
      self:connectClient(c)
    end
  elseif f.type == T.EAPOL then
    if not c or c.state ~= "handshake" then return end
    local e = W.decodeEapol(f.body)
    if not e then return end
    if e.n == 2 then
      c.ptk = K.ptk(self.pmk, self.bssid, f.src, c.anonce, e.nonce)
      if K.mic(c.ptk.kck, micInput(2, e.nonce)) ~= e.mic then
        self.stats.handshakeFailures = self.stats.handshakeFailures + 1
        c.tries = (c.tries or 0) + 1
        if c.tries >= 2 then self:drop(f.src, W.REASONS.AUTH_FAILED, true) end
        return
      end
      c.snonce = e.nonce
      self:send(W.header(T.EAPOL, self.bssid, self.bssid, f.src) .. W.encodeEapol(3, c.anonce, K.mic(c.ptk.kck, micInput(3, c.anonce))))
    elseif e.n == 4 and c.ptk then
      if K.mic(c.ptk.kck, micInput(4, "")) ~= e.mic then self.stats.handshakeFailures = self.stats.handshakeFailures + 1 return end
      c.pnRx = -1
      self:connectClient(c)
    end
  elseif f.type == T.DATA_TO_AP then
    if not c or c.state ~= "connected" then
      return self:send(W.header(T.DEAUTH, self.bssid, self.bssid, f.src) .. W.encodeDeauth(W.REASONS.AUTH_FAILED))
    end
    local frame, pn
    if self.security == W.SECURITY.PSK then
      frame, pn = K.open(c.ptk.tk, 0, f.body, message:sub(1, 19))
      if not frame then return end
      if pn <= (c.pnRx or -1) then self.stats.replays = self.stats.replays + 1 return end
      c.pnRx = pn
    else
      frame = f.body
    end
    self.switch:ingress(c.port, frame)
  elseif f.type == T.DEAUTH then
    if c then self:drop(f.src, nil, false) end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------------------------------------------------

function AP:start()
  if self.running then return end
  self.running = true
  local m = self:radio()
  pcall(m.open, self.mchan)
  self.driver = link.addHandler(self.stack, self.cfg.modemName or (type(self.cfg.modem) == "string" and self.cfg.modem) or self.cfg.modemId or "wifi-modem", function(ev) self:handle(ev) end, "ap:" .. self.ssid)
  self.switch:start()
  local ap = self
  local function loop()
    if not ap.running then return end
    ap.stats.beacons = ap.stats.beacons + 1
    ap:send(W.header(T.BEACON, ap.bssid, ap.bssid, B.MAC_BROADCAST) .. ap:beaconBody())
    local t = now(ap)
    for mac, c in pairs(ap.clients) do
      if t - c.lastSeen > ap.inactivity then ap:drop(mac, W.REASONS.INACTIVE, true)
      elseif c.state ~= "connected" and t - c.lastSeen > 10 then ap:drop(mac, nil, false) end
    end
    ap.stack:after(ap.beaconInterval, loop)
  end
  loop()
end

function AP:stop()
  if not self.running then return end
  for mac in pairs(self.clients) do self:drop(mac, W.REASONS.AP_DOWN, true) end
  self.running = false
  self.switch:stop()
  for i, d in ipairs(link.drivers) do if d == self.driver then table.remove(link.drivers, i) break end end
  pcall(self:radio().close, self.mchan)
end

return M
