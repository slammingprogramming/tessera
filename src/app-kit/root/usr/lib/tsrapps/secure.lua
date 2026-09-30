-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Authenticated request/reply messaging over rednet (or any transport with send/receive), shared by the turtle remote
-- and file sync. Every request carries HMAC-SHA256(passphrase, counter|command|arguments); a receiver accepts only a
-- counter higher than the last one seen from that sender (so captured messages cannot be replayed) and stays silent for
-- anything that does not verify. Replies are signed too, so the caller knows who answered.
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")

local S = {}

local function argText(arg)
  if arg == nil then return "" end
  if type(arg) == "table" then return textutils.serializeJSON(arg) end
  return tostring(arg)
end

function S.sign(secret, n, cmd, arg)
  return hash.hmacSha256(secret, tostring(n) .. "|" .. cmd .. "|" .. argText(arg))
end

--- Build a request. `n` must increase with every request from this sender (default: the current time in ms).
function S.request(secret, cmd, arg, n)
  n = n or (os.epoch and os.epoch("utc") or os.clock() * 1000)
  return { v = 1, n = n, cmd = cmd, arg = arg, sig = S.sign(secret, n, cmd, arg) }
end

function S.replySig(secret, n, ok, data)
  return hash.hmacSha256(secret, tostring(n) .. "|reply|" .. tostring(ok) .. "|" .. textutils.serializeJSON(data == nil and "" or data))
end

--- Build a signed reply to `msg`.
function S.reply(secret, msg, ok, data)
  local r = { v = 1, n = msg.n, ok = ok and true or false, data = data }
  r.sig = S.replySig(secret, r.n, r.ok, r.data)
  return r
end

--- Check a reply. Returns true or false + reason.
function S.verifyReply(secret, reply, n)
  if type(reply) ~= "table" or reply.n ~= n then return false, "reply does not match the request" end
  if reply.sig ~= S.replySig(secret, reply.n, reply.ok, reply.data) then return false, "bad signature on the reply" end
  return true
end

--- Receiver-side check. state = { last = { [sender] = counter } } (mutated on success).
--- Returns the message when it is well-formed, correctly signed and fresh; otherwise nil (say nothing).
function S.gate(secret, state, sender, msg)
  if type(msg) ~= "table" or msg.v ~= 1 or type(msg.cmd) ~= "string" or type(msg.n) ~= "number" then return nil end
  if msg.sig ~= S.sign(secret, msg.n, msg.cmd, msg.arg) then return nil end
  local last = state.last[sender] or -1
  if msg.n <= last then return nil end
  state.last[sender] = msg.n
  return msg
end

--- One request/response round trip. Returns reply.data (true when there is none), or nil + error.
function S.call(secret, net, target, cmd, arg, timeout)
  local req = S.request(secret, cmd, arg)
  net.send(target, req)
  local deadline = os.clock() + (timeout or 5)
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then return nil, "no answer from computer " .. tostring(target) end
    local sender, reply = net.receive(remaining)
    if sender == target then
      local good, why = S.verifyReply(secret, reply, req.n)
      if good then
        if reply.ok then return reply.data == nil and true or reply.data end
        return nil, tostring(reply.data or "command failed")
      elseif why ~= "reply does not match the request" then
        return nil, why
      end
    end
  end
end

--- The default network: rednet on the first modem found, for `protocol`.
function S.rednetNet(protocol)
  local modem = peripheral.find("modem")
  if not modem then return nil, "no modem attached" end
  rednet.open(peripheral.getName(modem))
  local net = {}
  function net.receive(timeout) local id, msg = rednet.receive(protocol, timeout) return id, msg end
  function net.send(id, msg) rednet.send(id, msg, protocol) end
  function net.host(name) rednet.host(protocol, name) end
  function net.lookup(name) return rednet.lookup(protocol, name) end
  return net
end

---------------------------------------------------------------------------------------------------------------------
-- Shared passphrase files
---------------------------------------------------------------------------------------------------------------------

function S.loadKey(path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local k = h.readAll()
  h.close()
  k = k and k:match("^%s*(.-)%s*$")
  return (k and k ~= "") and k or nil
end

function S.saveKey(path, secret) return vfs.writeFile(path, secret) end

--- The passphrase: read from `path`, or asked for (and saved) when missing or `force` is set.
function S.secret(io, path, force)
  local key = (not force) and S.loadKey(path)
  if key then return key end
  io.say("Choose a passphrase shared by both computers (at least 8 characters).")
  local a = io.secret and io.secret("Passphrase") or io.prompt("Passphrase")
  if not a or #a < 8 then return nil, "the passphrase must have at least 8 characters" end
  S.saveKey(path, a)
  io.say("Saved. Use the same passphrase on the other computer.")
  return a
end

--- Persisted replay counters.
function S.loadState(path)
  local s = vfs.readJSON(path)
  if type(s) ~= "table" or type(s.last) ~= "table" then s = { last = {} } end
  return s
end

function S.saveState(path, state) return vfs.writeJSON(path, state) end

return S
