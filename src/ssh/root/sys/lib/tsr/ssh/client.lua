-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The secure shell client library: connect to an sshd on another computer of the same game world, check its host key against
-- known_hosts, log in, and then make requests through the encrypted channel (see tsr.ssh.chan for the protocol).
--
--   local conn, err = client.connect(node, "alpha", { user = "alex", identity = key, confirm = function(info) return true end })
--   local res, err  = conn:call("exec", { line = "ls" })
--   conn:close()
local crypto = require("tsr.crypto")
local keys = require("tsr.ssh.keys")
local chan = require("tsr.ssh.chan")

local M = {}

M.TIMEOUT = 5
M.RETRIES = 2

local Conn = {}
Conn.__index = Conn

--- The directory for per-user ssh files (known_hosts, id_ed25519): ~/.ssh of the logged-in user, else /root/.ssh.
function M.sshDir()
  local ok, auth = pcall(require, "tsr.auth")
  if ok and type(auth) == "table" and auth.current then
    local me = auth.current()
    local u = me and auth.get(me)
    if u and u.home then return u.home .. "/.ssh" end
  end
  return "/root/.ssh"
end

function M.defaultIdentity() return M.sshDir() .. "/id_ed25519" end
function M.defaultKnownHosts() return M.sshDir() .. "/known_hosts" end

--- One request with retransmission. Returns the body of the reply or nil + reason.
function Conn:call(op, args, timeout)
  timeout = timeout or M.TIMEOUT
  if self.closed then return nil, "connection closed" end
  self.n = self.n + 1
  local n = self.n
  local payload = chan.seal(self.c2s, chan.CLIENT_TO_SERVER, self.sid, n, { op = op, a = args })
  local node = self.node
  for attempt = 0, M.RETRIES do
    node:send(self.peerId, { t = "ssh", k = "rec", sid = self.sid, n = n, d = payload })
    local reply = node:await(self.peerId, function(m) return m.t == "ssh" and m.sid == self.sid and (m.k == "rep" and m.n == n or m.k == "refuse") end, timeout)
    if reply then
      if reply.k == "refuse" then self.closed = true return nil, "the server ended the session (" .. tostring(reply.reason) .. ")" end
      local body = chan.open(self.s2c, chan.SERVER_TO_CLIENT, self.sid, n, reply.d)
      if not body then return nil, "a reply failed authentication" end
      if body.ok then return body.result end
      return nil, tostring(body.err)
    end
  end
  return nil, "no answer from " .. tostring(self.host or self.peerId)
end

function Conn:close()
  if not self.closed then
    self:call("bye", {}, 2)
    self.closed = true
  end
end

--- Log in. opts.user; opts.identity (a key table { secret, public }); opts.password. Returns true or nil + reason.
local function login(conn, opts)
  local user = opts.user or "root"
  if opts.identity then
    local sig = chan.userSign(opts.identity.secret, conn.h, user)
    local res, err = conn:call("auth", { user = user, method = "publickey", pub = crypto.base64Encode(opts.identity.public), sig = crypto.base64Encode(sig) })
    if res then return true end
    if conn.closed then return nil, err end
  end
  local password = opts.password
  if type(password) == "function" then password = password() end
  if password then
    local res, err = conn:call("auth", { user = user, method = "password", password = password })
    if res then return true end
    return nil, err
  end
  return nil, "permission denied (no accepted key" .. (opts.identity and "" or " or password") .. ")"
end

--- Connect and log in. `node` is a tsr.net node, `target` a computer id or name. Options:
---   user, identity (key table), password (string or function), timeout,
---   knownHosts (file path), confirm(info) -> boolean to accept an unknown host (info: id, host, fingerprint, art),
---   acceptNew (add unknown hosts without asking), onWarning(text).
--- Returns a connection or nil + reason.
function M.connect(node, target, opts)
  opts = opts or {}
  local id, rerr = node:resolve(target, opts.timeout)
  if not id then return nil, rerr end
  local eph = crypto.agreementKey()
  local sid = crypto.toHex(crypto.rand.bytes(8))
  local hello = { t = "ssh", k = "hello", v = chan.VERSION, sid = sid, ce = crypto.base64Encode(eph.public) }
  local reply
  for _ = 0, M.RETRIES do
    node:send(id, hello)
    reply = node:await(id, function(m) return m.t == "ssh" and m.sid == sid and (m.k == "reply" or m.k == "refuse") end, opts.timeout or 10)
    if reply then break end
  end
  if not reply then return nil, "no answer from " .. tostring(target) .. " (is sshd running there?)" end
  if reply.k == "refuse" then return nil, "connection refused: " .. tostring(reply.reason) end

  local se, hostPublic, sig = crypto.base64Decode(reply.se or ""), crypto.base64Decode(reply.hostkey or ""), crypto.base64Decode(reply.sig or "")
  if not (se and #se == 32 and hostPublic and #hostPublic == 32 and sig) then return nil, "malformed handshake reply" end
  local shared = crypto.x25519.shared(eph.secret, se)
  if not shared then return nil, "bad key from the server" end
  local h = chan.transcript(sid, node.id, id, eph.public, se, hostPublic)
  if not chan.hostVerify(hostPublic, h, sig) then return nil, "the server could not prove it owns its host key (possible attack)" end

  -- who is this computer? known_hosts decides
  local khPath = opts.knownHosts or M.defaultKnownHosts()
  local hostname = reply.host
  local status, oldPublic = keys.checkHost(khPath, id, hostname, hostPublic)
  if status == "changed" then
    return nil, ("WARNING: the host key of computer %d (%s) has CHANGED.\nIt was %s, now it is %s.\nSomeone may be impersonating it, or it was reinstalled.\nIf you are sure: ssh-keygen -R %d"):format(
      id, tostring(hostname), crypto.fingerprint(oldPublic), crypto.fingerprint(hostPublic), id)
  elseif status == "new" then
    local info = { id = id, host = hostname, fingerprint = crypto.fingerprint(hostPublic), art = keys.randomart(hostPublic) }
    if not opts.acceptNew then
      if not (opts.confirm and opts.confirm(info)) then return nil, "host key not accepted" end
    end
    keys.addHost(khPath, id, hostname, hostPublic)
    if opts.onWarning then opts.onWarning(("Permanently added computer %d (%s) to the list of known hosts."):format(id, tostring(hostname))) end
  end

  local c2s, s2c = chan.deriveKeys(shared, h)
  local conn = setmetatable({ node = node, peerId = id, host = hostname, sid = sid, h = h, c2s = c2s, s2c = s2c, n = 0, hostPublic = hostPublic }, Conn)
  local ok, lerr = login(conn, opts)
  if not ok then
    if not conn.closed then conn:call("bye", {}, 1) end      -- tell the server so it can free the session
    conn.closed = true
    return nil, lerr
  end
  conn.user = opts.user or "root"
  return conn
end

return M
