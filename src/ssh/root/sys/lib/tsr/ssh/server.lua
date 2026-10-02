-- SPDX-License-Identifier: AGPL-3.0-or-later
-- sshd: the in-game secure shell server. It answers handshakes on the net node (see tsr.ssh.chan), authenticates users and then
-- serves requests inside the encrypted channel: run a command, browse and copy files, register a key.
--
-- Who gets in:  a user must exist (tsr.auth; on a computer without users the single account is "root") and prove it with a key
--               listed in ~/.ssh/authorized_keys (/etc/tsr/ssh/authorized_keys without users), or with the account password when
--               /etc/tsr/sshd.cfg says password = true (off by default). What they can touch is limited by the same soft file
--               permissions as a console login.
-- Abuse limits:  handshakes cost real CPU on a game computer, so each peer may start one every few seconds, the number of open
--               sessions is capped, wrong credentials end the session and get slower, idle sessions expire.
local crypto = require("tsr.crypto")
local keys = require("tsr.ssh.keys")
local chan = require("tsr.ssh.chan")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("sshd")

local M = {}

M.CONFIG = "/etc/tsr/sshd.cfg"
M.SYSTEM_AUTHORIZED = "/etc/tsr/ssh/authorized_keys"
M.MAX_SESSIONS = 16
M.MAX_PER_PEER = 4
M.IDLE_SECONDS = 900
M.HANDSHAKE_SECONDS = 30       -- a session that has not logged in by then is dropped
M.HELLO_INTERVAL = 2
M.CHUNK = 8192
M.MAX_OUTPUT = 60000

local function now() return os.clock() end

--- Settings with defaults: { password = false, allowUsers = nil (everyone who has a key), maxAuthTries = 3 }.
function M.config()
  local c = vfs.readTable(M.CONFIG) or {}
  if c.password == nil then c.password = false end
  c.maxAuthTries = c.maxAuthTries or 3
  return c
end

---------------------------------------------------------------------------------------------------------------------
-- Accounts (through tsr.auth when it is installed and has users)
---------------------------------------------------------------------------------------------------------------------

local function authModule()
  local ok, auth = pcall(require, "tsr.auth")
  if ok and type(auth) == "table" and auth.hasUsers and auth.hasUsers() then return auth end
  return nil
end

local function userExists(user)
  local auth = authModule()
  if auth then
    local u = auth.get(user)
    return u ~= nil and not u.locked
  end
  return user == "root"
end

local function homeOf(user)
  local auth = authModule()
  if auth then
    local u = auth.get(user)
    return u and u.home or "/"
  end
  return "/"
end

local function authorizedPath(user)
  if authModule() then return homeOf(user) .. "/.ssh/authorized_keys" end
  return M.SYSTEM_AUTHORIZED
end

local function asUser(user, fn, ...)
  local auth = authModule()
  if auth and user ~= nil then return auth.asUser(user, fn, ...) end
  return fn(...)
end

--- Where a client-supplied path points: relative paths start in the user's home directory.
local function resolvePath(user, path)
  path = tostring(path or "")
  if path:sub(1, 1) ~= "/" then path = homeOf(user) .. "/" .. path end
  return "/" .. fs.combine(path, "")
end

---------------------------------------------------------------------------------------------------------------------
-- Operations inside an authenticated session. Each takes (session, args) and returns a result table or raises an error string.
---------------------------------------------------------------------------------------------------------------------

local ops = {}
M.ops = ops

local function shellOf(s)
  if not s.sh then s.sh = require("tsr.shell.exec").new({ home = homeOf(s.user) }) end
  return s.sh
end

--- Run `line` in the session's shell, capturing its output. Returns status, output, timedOut.
local function runCommand(s, line, timeout)
  local capture = require("tsr.shell.capture")
  local sh = shellOf(s)
  local okK, kernel = pcall(require, "tsr.kernel")
  if okK and kernel.isRunning and kernel.isRunning() then
    local cap = capture.new()
    local status = 1
    local pid = kernel.spawn({
      name = "ssh-cmd", term = cap.term, daemon = true,
      fn = function()
        local auth = authModule()
        if auth then auth.setSessionUser(s.user) end        -- first thing: from here on the user's file permissions apply
        status = sh:runLine(line)
      end,
    })
    local timedOut = false
    if pid then
      local timer = os.startTimer(timeout)
      while kernel.get(pid) do
        local ev, id = os.pullEvent()
        if ev == "timer" and id == timer then kernel.kill(pid) timedOut = true end
      end
      os.cancelTimer(timer)
    end
    return status, cap.text(), timedOut
  end
  local status, out = asUser(s.user, function() return sh:withIO("", true, function() return sh:runLine(line) end) end)
  return status, out or "", false
end

function ops.hello(s)
  local sh = shellOf(s)
  return { host = s.node.hostname, user = s.user, home = homeOf(s.user), cwd = "/" .. sh.dir }
end

function ops.exec(s, a)
  if type(a) ~= "table" or type(a.line) ~= "string" then error("need a command line", 0) end
  local timeout = math.min(tonumber(a.timeout) or 30, 300)
  local status, out, timedOut = runCommand(s, a.line, timeout)
  local truncated = false
  if #out > M.MAX_OUTPUT then out = out:sub(1, M.MAX_OUTPUT) truncated = true end
  return { status = status, output = out, cwd = "/" .. shellOf(s).dir, truncated = truncated, timedOut = timedOut }
end

function ops.stat(s, a)
  return asUser(s.user, function()
    local p = resolvePath(s.user, a.path)
    if not fs.exists(p) then return { exists = false } end
    return { exists = true, isDir = fs.isDir(p), size = fs.isDir(p) and 0 or fs.getSize(p) }
  end)
end

function ops.list(s, a)
  return asUser(s.user, function()
    local p = resolvePath(s.user, a.path)
    if not fs.isDir(p) then error("not a directory: " .. p, 0) end
    local out = {}
    for _, name in ipairs(fs.list(p)) do
      out[#out + 1] = { name = name, isDir = fs.isDir(p .. "/" .. name), size = fs.isDir(p .. "/" .. name) and 0 or fs.getSize(p .. "/" .. name) }
    end
    return out
  end)
end

function ops.get(s, a)
  return asUser(s.user, function()
    local p = resolvePath(s.user, a.path)
    if not fs.exists(p) or fs.isDir(p) then error("no such file: " .. p, 0) end
    local h = fs.open(p, "rb")
    if not h then error("cannot read " .. p, 0) end
    local data = h.readAll() or ""
    h.close()
    local offset = tonumber(a.offset) or 0
    local piece = data:sub(offset + 1, offset + M.CHUNK)
    return { data = crypto.base64Encode(piece), eof = offset + #piece >= #data, size = #data }
  end)
end

function ops.put(s, a)
  return asUser(s.user, function()
    local p = resolvePath(s.user, a.path)
    if fs.isDir(p) then error("is a directory: " .. p, 0) end
    local tmp = p .. ".tsr-part"
    local offset = tonumber(a.offset) or 0
    local piece = crypto.base64Decode(a.data or "") or error("bad data", 0)
    local h = fs.open(tmp, offset == 0 and "wb" or "ab")
    if not h then error("cannot write " .. p, 0) end
    h.write(piece)
    h.close()
    if a.finish then
      if fs.exists(p) then fs.delete(p) end
      fs.move(tmp, p)
    end
    return { written = #piece }
  end)
end

function ops.mkdir(s, a)
  return asUser(s.user, function() fs.makeDir(resolvePath(s.user, a.path)) return true end)
end

function ops.rm(s, a)
  return asUser(s.user, function()
    local p = resolvePath(s.user, a.path)
    if not fs.exists(p) then error("no such file: " .. p, 0) end
    local okT, trash = pcall(require, "tsr.trash")
    if okT and trash.discard then trash.discard(p) else fs.delete(p) end
    return true
  end)
end

function ops.mv(s, a)
  return asUser(s.user, function()
    local from, to = resolvePath(s.user, a.from), resolvePath(s.user, a.to)
    if not fs.exists(from) then error("no such file: " .. from, 0) end
    if fs.exists(to) then error("already exists: " .. to, 0) end
    fs.move(from, to)
    return true
  end)
end

--- ssh-copy-id: append a public key line to this user's authorized_keys.
function ops.authorize(s, a)
  local public, comment = keys.decode(tostring(a.line or ""))
  if not public then error("that is not a public key line", 0) end
  return asUser(s.user, function() return { added = keys.addAuthorized(authorizedPath(s.user), public, comment) } end)
end

function ops.bye(s) s.closed = true return true end

---------------------------------------------------------------------------------------------------------------------
-- Sessions and the handshake
---------------------------------------------------------------------------------------------------------------------

local sessions = {}       -- sid -> session
local lastHello = {}      -- peer id -> time of its last handshake

--- Forget everything (tests).
function M.reset() sessions, lastHello = {}, {} end

function M.sessionCount()
  local n = 0
  for _ in pairs(sessions) do n = n + 1 end
  return n
end

local function sweep()
  local t = now()
  for sid, s in pairs(sessions) do
    if s.closed or t - s.touched > M.IDLE_SECONDS or (not s.user and t - s.created > M.HANDSHAKE_SECONDS) then sessions[sid] = nil end
  end
end

local function refuse(node, from, sid, reason)
  node:send(from, { t = "ssh", k = "refuse", sid = sid, reason = reason })
end

local function onHello(node, from, msg)
  sweep()
  local sid = msg.sid
  if type(sid) ~= "string" or #sid < 8 or #sid > 32 or type(msg.ce) ~= "string" or msg.v ~= chan.VERSION then
    return refuse(node, from, tostring(msg.sid), "unsupported protocol")
  end
  if sessions[sid] then return end                                 -- a retransmitted hello: the reply is on its way or was sent
  local t = now()
  if lastHello[from] and t - lastHello[from] < M.HELLO_INTERVAL then return refuse(node, from, sid, "slow down") end
  lastHello[from] = t
  local mine = 0
  for _, s in pairs(sessions) do if s.peer == from then mine = mine + 1 end end
  if M.sessionCount() >= M.MAX_SESSIONS or mine >= M.MAX_PER_PEER then return refuse(node, from, sid, "too many sessions") end
  local ce = crypto.base64Decode(msg.ce)
  if not ce or #ce ~= 32 then return refuse(node, from, sid, "bad key") end

  local hostKey = keys.hostKey()
  local eph = crypto.agreementKey()
  local shared = crypto.x25519.shared(eph.secret, ce)
  if not shared then return refuse(node, from, sid, "bad key") end
  local h = chan.transcript(sid, from, node.id, ce, eph.public, hostKey.public)
  local c2s, s2c = chan.deriveKeys(shared, h)
  sessions[sid] = { sid = sid, peer = from, node = node, h = h, c2s = c2s, s2c = s2c, lastN = 0, touched = t, created = t, tries = 0, user = nil }
  node:send(from, {
    t = "ssh", k = "reply", sid = sid, se = crypto.base64Encode(eph.public), hostkey = crypto.base64Encode(hostKey.public),
    sig = crypto.base64Encode(chan.hostSign(hostKey.secret, h)), host = node.hostname,
  })
end

--- Check credentials. Returns true or nil + reason.
local function authenticate(s, a)
  local cfg = M.config()
  local user = tostring(a.user or "")
  if not userExists(user) then return nil, "denied" end
  if cfg.allowUsers then
    local allowed = false
    for _, u in ipairs(cfg.allowUsers) do if u == user then allowed = true end end
    if not allowed then return nil, "denied" end
  end
  if a.method == "publickey" then
    local pub = crypto.base64Decode(tostring(a.pub or ""))
    if not pub or #pub ~= 32 then return nil, "denied" end
    if not keys.isAuthorized(authorizedPath(user), pub) then return nil, "denied" end    -- read by the daemon itself (the system)
    local sig = crypto.base64Decode(tostring(a.sig or ""))
    if not sig or not chan.userVerify(pub, s.h, user, sig) then return nil, "denied" end
    return true
  elseif a.method == "password" then
    if not cfg.password then return nil, "password login is disabled on this computer" end
    local auth = authModule()
    if not auth then return nil, "denied" end
    if not auth.verify(user, tostring(a.password or "")) then return nil, "denied" end
    return true
  end
  return nil, "unknown method"
end

local function reply(node, s, n, body)
  local payload = chan.seal(s.s2c, chan.SERVER_TO_CLIENT, s.sid, n, body)
  s.lastReply = { n = n, p = payload }
  node:send(s.peer, { t = "ssh", k = "rep", sid = s.sid, n = n, d = payload })
end

local function process(node, s, n, body)
  local okOp, result
  if body.op == "auth" then
    if s.user then okOp, result = true, { user = s.user }
    else
      local good, why = authenticate(s, body.a or {})
      if good then
        s.user = tostring(body.a.user)
        log.info("%s logged in from computer %d", s.user, s.peer)
        okOp, result = true, { user = s.user }
      else
        s.tries = s.tries + 1
        log.warn("failed login for %s from computer %d (%s)", tostring(body.a and body.a.user), s.peer, tostring(why))
        if s.tries >= M.config().maxAuthTries then s.closed = true end
        okOp, result = false, tostring(why)
      end
    end
  elseif not s.user and body.op ~= "bye" then
    okOp, result = false, "not authenticated"
  else
    local fn = ops[body.op]
    if not fn then okOp, result = false, "unknown request " .. tostring(body.op)
    else okOp, result = pcall(fn, s, body.a or {}) end
  end
  local rep = okOp and { ok = true, result = result } or { ok = false, err = tostring(result) }
  reply(node, s, n, rep)
  if s.closed then sessions[s.sid] = nil end
end

local function onRecord(node, from, msg)
  local s = sessions[msg.sid]
  if not s or s.peer ~= from then return refuse(node, from, tostring(msg.sid), "no such session") end
  local n = msg.n
  if type(n) ~= "number" then return end
  s.touched = now()
  if n == s.lastN and s.lastReply and s.lastReply.n == n then          -- a retransmission of an answered request
    node:send(from, { t = "ssh", k = "rep", sid = s.sid, n = n, d = s.lastReply.p })
    return
  end
  if n ~= s.lastN + 1 then return end                                   -- replay, reordering or garbage: ignore silently
  local body = chan.open(s.c2s, chan.CLIENT_TO_SERVER, s.sid, n, msg.d)
  if not body then return end                                           -- does not authenticate: ignore silently
  s.lastN = n
  local okK, kernel = pcall(require, "tsr.kernel")
  if okK and kernel.isRunning and kernel.isRunning() then
    kernel.spawn({ name = "ssh:" .. tostring(body.op), window = false, daemon = true, fn = function() process(node, s, n, body) end })
  else
    process(node, s, n, body)
  end
end

--- Handle one network message (installed as the node's "ssh" handler).
function M.handle(node, from, msg)
  if msg.k == "hello" then return onHello(node, from, msg) end
  if msg.k == "rec" then return onRecord(node, from, msg) end
end

--- Start answering on `node`.
function M.attach(node)
  node.handlers = node.handlers or {}
  node.handlers.ssh = M.handle
  keys.hostKey()
  return node
end

--- The sshd service: attach to the default node and idle (the netd daemon dispatches the messages).
function M.daemon()
  M.attach(require("tsr.net").default())
  log.info("sshd ready; host key %s", crypto.fingerprint(keys.hostKey().public))
  while true do
    sleep(60)
    sweep()
  end
end

return M
