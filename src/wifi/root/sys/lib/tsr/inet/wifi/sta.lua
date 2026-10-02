-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A Wi-Fi station: the network card of a computer that connects to an access point. To the IP stack it is an ordinary Ethernet interface (wlan0); underneath
-- it scans the channels for the network, authenticates, associates, runs the four-way handshake, encrypts what it sends, and looks for a better
-- access point when the signal drops or the beacons stop. Signal strength is estimated from the distance the modem reports.
--
--   local sta = require("tsr.inet.wifi.sta").new(stack, { name = "wlan0", modem = "top", ssid = "home", passphrase = "correct horse" })
--   sta:run()                  -- blocks forever: (re)connects whenever the link is down
--   sta:scan() -> list of networks
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wifi.frames")
local K = require("tsr.inet.wifi.keys")
local link = require("tsr.inet.link")

local M = {}
local Sta = {}
Sta.__index = Sta

local T, STATUS = W.TYPES, W.STATUS

M.RANGE = 64               -- blocks: the signal estimate is 100% at 0 and 0% at this distance
M.DWELL = 0.35             -- seconds spent listening on each channel while scanning

--- cfg: name (wlan0), modem (peripheral name or object), modemName (when modem is an object), ssid, passphrase (none = open network), channels (list, default 1..14),
--- mac, iterations, bssid (connect only to this access point), roamThreshold (signal % below which a better AP is looked for, 35), roamMargin (15).
function M.new(stack, cfg)
  local self = setmetatable({
    stack = stack, cfg = cfg, state = "idle", candidates = {}, stats = { scans = 0, roams = 0, connects = 0, rx = 0, tx = 0, replays = 0, decryptFailures = 0 },
    channels = cfg.channels or { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 },
  }, Sta)
  self.name = cfg.name or "wlan0"
  local mac = cfg.mac and B.mac(cfg.mac) or B.makeMac(os.getComputerID and os.getComputerID() or 1, 88, 1)
  local sta = self
  self.iface = stack:addInterface({ name = self.name, kind = "wifi", mac = mac, mtu = 1500, up = false, send = function(frame) return sta:transmitFrame(frame) end })
  self.iface.wifi = self
  self.mac = mac
  return self
end

function Sta:radio()
  if not self.modem then
    local m = self.cfg.modem
    self.modem = type(m) == "string" and peripheral.wrap(m) or m
  end
  return self.modem
end

local function now(self) return self.stack.clock() end

function Sta:sendRadio(channel, msg)
  self.stats.tx = self.stats.tx + 1
  local mchan = W.modemChannel(channel)
  self:radio().transmit(mchan, mchan, msg)
end

function Sta:start()
  if self.started then return end
  self.started = true
  local m = self:radio()
  for _, ch in ipairs(self.channels) do pcall(m.open, W.modemChannel(ch)) end
  self.driver = link.addHandler(self.stack, self.cfg.modemName or (type(self.cfg.modem) == "string" and self.cfg.modem) or "wifi-modem", function(ev) self:handle(ev) end, "sta:" .. self.name)
end

function Sta:stop()
  self:disconnect()
  self.started = false
  for i, d in ipairs(link.drivers) do if d == self.driver then table.remove(link.drivers, i) break end end
  local m = self:radio()
  for _, ch in ipairs(self.channels) do pcall(m.close, W.modemChannel(ch)) end
end

---------------------------------------------------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------------------------------------------------

local function signalOf(distance)
  if not distance then return 50 end
  return math.max(0, math.min(100, math.floor(100 - distance * 100 / M.RANGE)))
end

function Sta:handle(ev)
  local ch, message, distance = ev[3], ev[5], ev[6]
  local f = W.parse(message)
  if not f then return end
  self.stats.rx = self.stats.rx + 1
  local wifiChannel = ch - W.BASE_CHANNEL
  if f.type == T.BEACON or f.type == T.PROBE_RESP then
    local b = W.decodeBeacon(f.body)
    if not b then return end
    local c = self.candidates[f.bssid] or {}
    c.bssid, c.ssid, c.channel, c.security, c.hidden, c.load, c.at = f.bssid, (b.ssid ~= "" and b.ssid) or c.ssid or "", wifiChannel, b.security, b.hidden, b.load, now(self)
    local sig = signalOf(distance)
    c.signal = c.signal and math.floor(c.signal * 0.5 + sig * 0.5) or sig
    self.candidates[f.bssid] = c
    if self.ap and f.bssid == self.ap.bssid and f.type == T.BEACON then self.lastBeacon = now(self) self.ap.signal = c.signal end
    return
  end
  if f.dst ~= self.mac then return end
  if self.ap and f.bssid ~= self.ap.bssid and self.state ~= "authenticating" then return end
  if f.type == T.AUTH and self.state == "authenticating" then
    local a = W.decodeAuth(f.body)
    if a.seq == 2 and f.bssid == self.pending.bssid then self.authStatus = a.status end
  elseif f.type == T.ASSOC_RESP and self.state == "associating" then
    local r = W.decodeAssocResp(f.body)
    self.assocStatus, self.aid = r.status, r.aid
  elseif f.type == T.EAPOL and (self.state == "handshake" or self.state == "associating") then
    local e = W.decodeEapol(f.body)
    if not e then return end
    local ap = self.pending or self.ap
    if e.n == 1 then
      self.anonce = e.nonce
      self.snonce = K.nonce()
      self.ptk = K.ptk(self.pmk, ap.bssid, self.mac, self.anonce, self.snonce)
      self.state = "handshake"
      self:sendRadio(ap.channel, W.header(T.EAPOL, ap.bssid, self.mac, ap.bssid) .. W.encodeEapol(2, self.snonce, K.mic(self.ptk.kck, string.char(2) .. self.snonce)))
    elseif e.n == 3 and self.ptk then
      if e.nonce ~= self.anonce or K.mic(self.ptk.kck, string.char(3) .. e.nonce) ~= e.mic then return end
      self:sendRadio(ap.channel, W.header(T.EAPOL, ap.bssid, self.mac, ap.bssid) .. W.encodeEapol(4, nil, K.mic(self.ptk.kck, string.char(4))))
      self.handshakeDone = true
    end
  elseif f.type == T.DATA_FROM_AP and self.state == "connected" then
    local frame
    if self.ap.security == W.SECURITY.PSK then
      local pn
      frame, pn = K.open(self.ptk.tk, 1, f.body, message:sub(1, 19))
      if not frame then self.stats.decryptFailures = self.stats.decryptFailures + 1 return end
      if pn <= (self.pnRx or -1) then self.stats.replays = self.stats.replays + 1 return end
      self.pnRx = pn
    else
      frame = f.body
    end
    self.stack:input(self.iface, frame)
  elseif f.type == T.DEAUTH then
    if self.state ~= "idle" then self:lost("deauthenticated by the access point") end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------------------------------------------------

function Sta:transmitFrame(frame)
  if self.state ~= "connected" or not self.ap then return false end
  local hdr = W.header(T.DATA_TO_AP, self.ap.bssid, self.mac, self.ap.bssid)
  local body
  if self.ap.security == W.SECURITY.PSK then
    self.pnTx = (self.pnTx or 0) + 1
    body = K.seal(self.ptk.tk, self.pnTx, 0, frame, hdr)
  else
    body = frame
  end
  self:sendRadio(self.ap.channel, hdr .. body)
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Scanning and connecting
---------------------------------------------------------------------------------------------------------------------

--- Look for networks on every channel. Returns a list sorted by signal: { ssid, bssid, channel, security, signal }.
function Sta:scan(ssid)
  self:start()
  self.stats.scans = self.stats.scans + 1
  local stack = self.stack
  for _, ch in ipairs(self.channels) do
    self:sendRadio(ch, W.header(T.PROBE_REQ, B.MAC_BROADCAST, self.mac, B.MAC_BROADCAST) .. W.encodeProbe(ssid or ""))
    stack.wait(function() return false end, M.DWELL)
  end
  local out, t = {}, now(self)
  for _, c in pairs(self.candidates) do
    if t - c.at < 15 then out[#out + 1] = { ssid = c.ssid, bssid = c.bssid, channel = c.channel, security = c.security == W.SECURITY.PSK and "psk" or "open", signal = c.signal, hidden = c.hidden } end
  end
  table.sort(out, function(a, b) if a.signal ~= b.signal then return a.signal > b.signal end return a.bssid < b.bssid end)
  return out
end

function Sta:lost(why)
  local was = self.state
  self.state = "idle"
  self.ap = nil
  self.ptk, self.pnRx, self.pnTx = nil, nil, nil
  self.stack:setUp(self.name, false)
  self.stack:wake()
  if self.onLost and was ~= "idle" then self.onLost(why) end
end

--- One connection attempt to the named network. Returns true or nil + reason.
function Sta:connect(ssid, passphrase)
  ssid = ssid or self.cfg.ssid
  passphrase = passphrase or self.cfg.passphrase
  if not ssid then return nil, "no network name" end
  self:start()
  local stack = self.stack
  local wantSec = passphrase and W.SECURITY.PSK or W.SECURITY.OPEN
  local found = self:scan(ssid)
  local pick
  for _, c in ipairs(found) do
    if c.ssid == ssid and (c.security == "psk") == (wantSec == W.SECURITY.PSK) and (not self.cfg.bssid or B.macStr(c.bssid) == self.cfg.bssid:lower()) then pick = c break end
  end
  if not pick then
    for _, c in ipairs(found) do if c.ssid == ssid then return nil, "the network " .. ssid .. " is " .. c.security .. " but you gave " .. (passphrase and "a passphrase" or "none") end end
    return nil, "network " .. ssid .. " not found"
  end
  return self:connectTo(pick, ssid, passphrase)
end

function Sta:connectTo(pick, ssid, passphrase)
  local stack = self.stack
  self.pending = { bssid = pick.bssid, channel = pick.channel, security = pick.security == "psk" and W.SECURITY.PSK or W.SECURITY.OPEN, signal = pick.signal }
  if passphrase then self.pmk = K.pmk(passphrase, ssid, self.cfg.iterations) end
  self.authStatus, self.assocStatus, self.handshakeDone = nil, nil, nil
  self.state = "authenticating"
  self:sendRadio(pick.channel, W.header(T.AUTH, pick.bssid, self.mac, pick.bssid) .. W.encodeAuth(1))
  stack.wait(function() return self.authStatus ~= nil end, 1.5)
  if self.authStatus ~= STATUS.OK then
    local st = self.authStatus
    self.state = "idle"
    return nil, st == STATUS.DENIED and "the access point refused this computer (MAC filter)" or "no answer to authentication"
  end
  self.state = "associating"
  self:sendRadio(pick.channel, W.header(T.ASSOC_REQ, pick.bssid, self.mac, pick.bssid) .. W.encodeAssocReq(ssid))
  stack.wait(function() return self.assocStatus ~= nil end, 1.5)
  if self.assocStatus ~= STATUS.OK then
    local st = self.assocStatus
    self.state = "idle"
    return nil, st == STATUS.FULL and "the access point is full" or (st == nil and "no answer to association" or "association refused")
  end
  if pick.security == "psk" then
    self.state = "handshake"
    stack.wait(function() return self.handshakeDone or self.state == "idle" end, 3)
    if not self.handshakeDone then
      self:sendRadio(pick.channel, W.header(T.DEAUTH, pick.bssid, self.mac, pick.bssid) .. W.encodeDeauth(W.REASONS.LEFT))
      self.state = "idle"
      return nil, "the handshake failed: wrong passphrase?"
    end
  end
  self.ap = self.pending
  self.ap.ssid = ssid
  self.pnRx, self.pnTx = -1, 0
  self.lastBeacon = now(self)
  self.state = "connected"
  self.stats.connects = self.stats.connects + 1
  self.stack:setUp(self.name, true)
  stack:wake()
  if self.onConnect then self.onConnect(self.ap) end
  return true
end

function Sta:disconnect()
  if self.state == "connected" and self.ap then
    self:sendRadio(self.ap.channel, W.header(T.DEAUTH, self.ap.bssid, self.mac, self.ap.bssid) .. W.encodeDeauth(W.REASONS.LEFT))
  end
  self:lost("disconnected")
end

function Sta:status()
  return { state = self.state, ssid = self.ap and self.ap.ssid, bssid = self.ap and self.ap.bssid, channel = self.ap and self.ap.channel, signal = self.ap and self.ap.signal,
    security = self.ap and (self.ap.security == W.SECURITY.PSK and "psk" or "open") }
end

--- Keep the connection up: connect, watch the beacons and the signal, roam, reconnect.
function Sta:run()
  local stack = self.stack
  while self.cfg.ssid do
    if self.state ~= "connected" then
      local ok, err = self:connect()
      if not ok then
        if self.onFail then self.onFail(err) end
        stack.wait(function() return false end, 4)
      end
    else
      stack.wait(function() return self.state ~= "connected" end, 2)
      if self.state == "connected" then
        if now(self) - (self.lastBeacon or 0) > 6 then
          self:lost("the access point went silent")
        elseif (self.ap.signal or 100) < (self.cfg.roamThreshold or 35) then
          -- look for a better access point of the same network
          local list = self:scan(self.cfg.ssid)
          for _, c in ipairs(list) do
            if c.ssid == self.cfg.ssid and c.bssid ~= self.ap.bssid and c.signal >= (self.ap.signal or 0) + (self.cfg.roamMargin or 15)
              and (c.security == "psk") == (self.cfg.passphrase ~= nil) then
              self.stats.roams = self.stats.roams + 1
              self:disconnect()
              self:connectTo(c, self.cfg.ssid, self.cfg.passphrase)
              break
            end
          end
        end
      end
    end
  end
end

return M
