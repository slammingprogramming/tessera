-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Wi-Fi frames, in the spirit of IEEE 802.11 (beacons, probes, authentication, association, the four-way handshake, encrypted data) but simplified for
-- ComputerCraft modems: every frame is one modem message, a byte string. Wi-Fi channel n (1..14) uses modem channel 7110 + n, so APs and stations that
-- do not share a channel do not hear each other.
--
-- Header (19 bytes): type(1) bssid(6) source(6) destination(6).
local B = require("tsr.inet.bytes")

local M = {}

M.BASE_CHANNEL = 7110
M.TYPES = { BEACON = 1, PROBE_REQ = 2, PROBE_RESP = 3, AUTH = 4, ASSOC_REQ = 6, ASSOC_RESP = 7, DEAUTH = 8, EAPOL = 10, DATA_TO_AP = 16, DATA_FROM_AP = 17 }
M.SECURITY = { OPEN = 0, PSK = 1 }

function M.modemChannel(wifiChannel) return M.BASE_CHANNEL + wifiChannel end

function M.header(typ, bssid, src, dst) return string.char(typ) .. bssid .. src .. dst end

--- Split a received message into header fields and body. Returns nil for anything that is not a Wi-Fi frame.
function M.parse(msg)
  if type(msg) ~= "string" or #msg < 19 then return nil end
  local typ = msg:byte(1)
  if typ < 1 or typ > 20 then return nil end
  return { type = typ, bssid = msg:sub(2, 7), src = msg:sub(8, 13), dst = msg:sub(14, 19), body = msg:sub(20) }
end

---------------------------------------------------------------------------------------------------------------------
-- Bodies
---------------------------------------------------------------------------------------------------------------------

--- Beacon / probe response body.
function M.encodeBeacon(b)
  return B.u16(b.interval or 1000) .. string.char(b.channel, b.security or 0, b.hidden and 1 or 0, #(b.hidden and "" or b.ssid)) .. (b.hidden and "" or b.ssid)
    .. string.char(math.min(255, b.load or 0)) .. B.u32(b.timestamp or 0)
end

function M.decodeBeacon(body)
  if #body < 5 then return nil end
  local ssidLen = body:byte(6)
  if #body < 6 + ssidLen + 5 then return nil end
  return { interval = B.rd16(body, 1), channel = body:byte(3), security = body:byte(4), hidden = body:byte(5) == 1, ssid = body:sub(7, 6 + ssidLen),
    load = body:byte(7 + ssidLen), timestamp = B.rd32(body, 8 + ssidLen) }
end

function M.encodeProbe(ssid) return string.char(#ssid) .. ssid end
function M.decodeProbe(body) local n = body:byte(1) or 0 return body:sub(2, 1 + n) end

function M.encodeAuth(seq, status) return string.char(seq, status or 0) end
function M.decodeAuth(body) return { seq = body:byte(1), status = body:byte(2) } end

function M.encodeAssocReq(ssid) return string.char(#ssid) .. ssid end
function M.decodeAssocReq(body) local n = body:byte(1) or 0 return body:sub(2, 1 + n) end
function M.encodeAssocResp(status, aid) return string.char(status) .. B.u16(aid or 0) end
function M.decodeAssocResp(body) return { status = body:byte(1), aid = B.rd16(body, 2) } end

M.STATUS = { OK = 0, REFUSED = 1, FULL = 2, DENIED = 3, BAD_SSID = 4 }
M.REASONS = { LEFT = 1, INACTIVE = 2, AUTH_FAILED = 3, KICKED = 4, AP_DOWN = 5 }

function M.encodeDeauth(reason) return string.char(reason or 1) end

---------------------------------------------------------------------------------------------------------------------
-- The four-way handshake messages (EAPOL): body = message number (1..4) .. fields
--   1 AP->STA: ANonce(32)
--   2 STA->AP: SNonce(32) MIC(16)
--   3 AP->STA: ANonce(32) MIC(16)
--   4 STA->AP: MIC(16)
---------------------------------------------------------------------------------------------------------------------

function M.encodeEapol(n, nonce, mic) return string.char(n) .. (nonce or "") .. (mic or "") end

function M.decodeEapol(body)
  local n = body:byte(1)
  if n == 1 and #body >= 33 then return { n = 1, nonce = body:sub(2, 33) } end
  if (n == 2 or n == 3) and #body >= 49 then return { n = n, nonce = body:sub(2, 33), mic = body:sub(34, 49) } end
  if n == 4 and #body >= 17 then return { n = 4, mic = body:sub(2, 17) } end
  return nil
end

return M
