-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The physical layer: how Ethernet frames travel over ComputerCraft modems.
--
-- A modem sends a message on a numbered channel and every modem that has opened that channel (and is in reach: connected by networking cable, or
-- within range for wireless) receives it. That is exactly a shared medium, so a channel is used like a cable segment or a radio frequency:
--   * wired modems on one cable network that listen on the same channel form one segment (a hub); two separate cable networks are two segments;
--   * wireless modems in range of each other that use the same channel form one segment; choose another channel for a private radio link;
--   * a switch or router with several modems joins segments (see tsr.inet.switch and the routing packages).
-- The frame is the byte string of an Ethernet II frame (tsr.inet.wire). Optional link encryption seals each frame with ChaCha20-Poly1305 under
-- a shared key (like MACsec), so that only computers with the key can read or inject frames on that channel.
local B = require("tsr.inet.bytes")

local M = {}

M.CHANNEL = 7101                   -- default Ethernet channel
M.FIRST_CHANNEL, M.LAST_CHANNEL = 7101, 7199

M.drivers = {}                     -- list of { name (peripheral), channel, iface, stack, modem, key }

--- A sealed frame on the air: counter (8 bytes) .. low four bytes of the sender's MAC (4) .. ChaCha20-Poly1305(frame). The 12-byte nonce is
--- those four bytes followed by the counter, so it never repeats for one key as long as the counter of each sender only increases.
local function sealFrame(driver, frame)
  local crypto = require("tsr.crypto")
  driver.txCounter = (driver.txCounter or 0) + 1
  local n = driver.txCounter
  local hi, lo = math.floor(n / 4294967296), n % 4294967296
  local sender = frame:sub(9, 12)
  return B.u32(hi) .. B.u32(lo) .. sender .. crypto.chacha.seal(driver.key, sender .. B.u32(hi) .. B.u32(lo), frame, "tsr-link")
end

--- Open a modem as an interface of `stack`. spec: peripheral (name), channel, name (interface name), mac, mtu, key (link encryption secret),
--- kind ("ethernet" for cables, "wifi" is set by the Wi-Fi package). Returns the interface, or nil + reason.
function M.attachModem(stack, spec)
  local modem = spec.modem or peripheral.wrap(spec.peripheral)
  if not modem or not modem.transmit then return nil, "no modem " .. tostring(spec.peripheral) end
  local channel = spec.channel or M.CHANNEL
  local driver = { name = spec.peripheral, channel = channel, modem = modem, stack = stack, key = spec.key and M.deriveKey(spec.key) or nil }
  local iface
  local function send(frame)
    local out = frame
    if driver.key then out = sealFrame(driver, frame) end
    modem.transmit(channel, channel, out)
  end
  local wireless = modem.isWireless and modem.isWireless()
  M.counter = (M.counter or 0) + 1
  iface = stack:addInterface({
    name = spec.name or ((wireless and "wlan" or "eth") .. (M.counter - 1)),
    kind = spec.kind or (wireless and "wireless" or "ethernet"),
    mac = spec.mac or B.makeMac(os.getComputerID(), M.counter, 1),
    mtu = spec.mtu or 1500, send = send,
  })
  iface.driver = driver
  driver.iface = iface
  pcall(modem.open, channel)
  M.drivers[#M.drivers + 1] = driver
  return iface
end

function M.detach(name)
  for i, d in ipairs(M.drivers) do
    if d.iface.name == name then
      pcall(d.modem.close, d.channel)
      table.remove(M.drivers, i)
      return true
    end
  end
  return false
end

--- Derive the link key from a passphrase (the same on every computer of the segment).
function M.deriveKey(secret)
  local kdf = require("tsr.crypto").kdf
  return kdf.hkdf(secret, "tessera-link", "frame-key", 32)
end

--- Feed a modem_message event ({ "modem_message", side, channel, replyChannel, message, distance }) to the right interface.
function M.dispatch(ev)
  local side, channel, message = ev[2], ev[3], ev[5]
  if type(message) ~= "string" then return false end
  local handled = false
  for _, d in ipairs(M.drivers) do
    if d.name == side and d.channel == channel then
      local frame = message
      if d.key then frame = M.unseal(d, message) end
      if frame then
        d.stack:input(d.iface, frame)
        handled = true
      end
    end
  end
  return handled
end

--- Open a sealed frame (see sealFrame). Returns the frame, or nil for damaged, forged or replayed ones.
function M.unseal(d, data)
  local crypto = require("tsr.crypto")
  if #data < 12 + 16 + 14 then return nil end
  local hi, lo = B.rd32(data, 1), B.rd32(data, 5)
  local n = hi * 4294967296 + lo
  local senderLow = data:sub(9, 12)
  local frame = crypto.chacha.open(d.key, senderLow .. B.u32(hi) .. B.u32(lo), data:sub(13), "tsr-link")
  if not frame or frame:sub(9, 12) ~= senderLow then d.badFrames = (d.badFrames or 0) + 1 return nil end
  -- replay protection per sender: counters must increase
  d.seen = d.seen or {}
  local sender = frame:sub(7, 12)
  if n <= (d.seen[sender] or 0) then d.replays = (d.replays or 0) + 1 return nil end
  d.seen[sender] = n
  return frame
end

return M
