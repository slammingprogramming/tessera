-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A TLS-like secure channel over a TCP socket of the in-game network (for https, SMTP STARTTLS and SMTPS, POP3S, MQTT over TLS and your own services).
-- It is not wire-compatible with real TLS and never leaves the game, but it does what TLS 1.3 does:
--   * a fresh X25519 key exchange for every connection (forward secrecy), the server proves its identity by signing the handshake with the key of its certificate
--   * the certificate is checked: valid dates, the right name, and either signed by a CA you trust, or pinned the first time it was seen (and loudly refused if
--     it ever changes), and not on the revoked list
--   * records are encrypted and authenticated with ChaCha20-Poly1305 and sequence numbers, so nothing can be read, altered, replayed or reordered
-- The wrapped socket has the same methods as a TCP socket (send, receive, close, getpeername, settimeout), so protocols can run over it unchanged.
--
--   local tls = require("tsr.inet.tls")
--   local conn = socket.tcp(); conn:connect("mail.lan", 465)
--   local secure, err = tls.client(conn, "mail.lan")          -- verifies the certificate against the trust store
--   secure:send("hello\r\n")
--   -- server side, on an accepted socket:
--   local secure = tls.server(accepted, { cert = certObject, key = signingKeyPair })
-- Speed: public-key operations in Lua take time (a handshake may take seconds on a real computer); keep connections open and reuse them.
local crypto = require("tsr.crypto")
local cert = require("tsr.inet.tls.cert")
local vfs = require("tsr.vfs")

local M = {}
M.cert = cert

M.DIR = "/etc/tsr/inet/tls"
M.VERSION = 1
M.MAX_RECORD = 8192

local T_CLIENT_HELLO, T_SERVER_HELLO, T_FINISHED, T_DATA, T_ALERT = 1, 2, 20, 23, 21

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function rd16(s, i) local a, b = s:byte(i, i + 1) return a * 256 + b end

local function nonce(direction, seq)
  local b = {}
  for i = 8, 1, -1 do b[i] = seq % 256 seq = math.floor(seq / 256) end
  return string.char(direction, 0, 0, 0) .. string.char(table.unpack(b))
end

---------------------------------------------------------------------------------------------------------------------
-- Trust store
---------------------------------------------------------------------------------------------------------------------

--- A trust store: CA certificates, pinned server certificates (host -> fingerprint) and revocations. All files live in M.DIR unless paths are given.
function M.store(opts)
  opts = opts or {}
  local dir = opts.dir or M.DIR
  local s = { dir = dir, cas = {}, pinned = {}, revoked = {}, tofu = opts.tofu ~= false }
  local function lines(path)
    local text = vfs.readFile(path)
    local out = {}
    for l in (text or ""):gmatch("[^\r\n]+") do if l:sub(1, 1) ~= "#" then out[#out + 1] = l end end
    return out
  end
  function s:reload()
    self.cas, self.pinned, self.revoked = {}, {}, {}
    if vfs.fs.exists(dir .. "/ca") then
      for _, n in ipairs(vfs.fs.list(dir .. "/ca")) do
        local c = cert.decode(vfs.readFile(dir .. "/ca/" .. n))
        if c and c.ca and cert.signatureOk(c) then self.cas[#self.cas + 1] = c end
      end
    end
    for _, l in ipairs(lines(dir .. "/known_certs")) do
      local host, fp = l:match("^(%S+)%s+(%S+)$")
      if host then self.pinned[host:lower()] = fp end
    end
    for _, l in ipairs(lines(dir .. "/revoked")) do self.revoked[l:match("^(%S+)")] = true end
  end
  function s:pin(host, fingerprint)
    self.pinned[host:lower()] = fingerprint
    local text = vfs.readFile(dir .. "/known_certs") or ""
    vfs.writeFile(dir .. "/known_certs", text .. host:lower() .. " " .. fingerprint .. "\n")
  end
  function s:forget(host)
    host = host:lower()
    self.pinned[host] = nil
    local out = {}
    for _, l in ipairs(lines(dir .. "/known_certs")) do if l:match("^(%S+)") ~= host then out[#out + 1] = l end end
    vfs.writeFile(dir .. "/known_certs", table.concat(out, "\n") .. (#out > 0 and "\n" or ""))
  end
  function s:addCa(c)
    vfs.writeFile(dir .. "/ca/" .. c.subject:gsub("[^%w%-_.]", "_") .. ".crt", cert.encode(c))
    self:reload()
  end
  function s:revoke(id)
    vfs.writeFile(dir .. "/revoked", (vfs.readFile(dir .. "/revoked") or "") .. id .. "\n")
    self.revoked[id] = true
  end
  s:reload()
  return s
end

--- Check a server certificate. Returns true, how ("ca" | "pinned" | "new") or nil + reason ("expired", "name", "revoked", "untrusted", "changed", "bad signature").
function M.verify(c, host, store, now)
  if cert.expired(c, now) then return nil, "expired", "the certificate is not valid now" end
  if store.revoked[c.serial] or store.revoked[cert.fingerprint(c)] then return nil, "revoked", "the certificate was revoked" end
  if not cert.matches(c, host) then return nil, "name", "the certificate is for " .. c.subject .. ", not " .. tostring(host) end
  if not cert.signatureOk(c) then return nil, "bad signature", "the signature on the certificate is wrong" end
  -- signed by a CA we trust?
  if not cert.isSelfSigned(c) then
    for _, ca in ipairs(store.cas) do
      if ca.key == c.issuerKey and not cert.expired(ca, now) and not store.revoked[ca.serial] then return true, "ca", ca.subject end
    end
  else
    for _, ca in ipairs(store.cas) do if ca.key == c.key then return true, "ca", ca.subject end end
  end
  -- pinned?
  local fp = cert.fingerprint(c)
  local pinned = store.pinned[tostring(host):lower()]
  if pinned then
    if pinned == fp then return true, "pinned" end
    return nil, "changed", ("WARNING: the certificate of %s is not the one seen before (was %s, now %s): someone may be impersonating it"):format(host, pinned, fp)
  end
  if store.tofu then return true, "new", fp end
  return nil, "untrusted", "no trusted CA signed this certificate and it is not pinned (" .. fp .. ")"
end

---------------------------------------------------------------------------------------------------------------------
-- Records
---------------------------------------------------------------------------------------------------------------------

local Session = {}
Session.__index = Session

local function writeRecord(sock, typ, payload, timeout)
  return sock:send(string.char(typ) .. u16(#payload) .. payload, timeout)
end

local function readRecord(sock, timeout)
  local head, err = sock:receive(3, timeout)
  if not head then return nil, err end
  local len = rd16(head, 2)
  local payload = ""
  if len > 0 then
    payload, err = sock:receive(len, timeout)
    if not payload then return nil, err end
  end
  return head:byte(1), payload
end

local function newSession(sock, sendKey, recvKey, sendDir, recvDir, peer)
  return setmetatable({ sock = sock, sendKey = sendKey, recvKey = recvKey, sendDir = sendDir, recvDir = recvDir, sendSeq = 0, recvSeq = 0, buf = "", timeout = nil, peer = peer or {}, closed = false }, Session)
end

local function sealRecord(self, typ, plain)
  local sealed = crypto.chacha.seal(self.sendKey, nonce(self.sendDir, self.sendSeq), plain, string.char(typ))
  self.sendSeq = self.sendSeq + 1
  return sealed
end

local function openRecord(self, typ, sealed)
  local plain = crypto.chacha.open(self.recvKey, nonce(self.recvDir, self.recvSeq), sealed, string.char(typ))
  if plain then self.recvSeq = self.recvSeq + 1 end
  return plain
end

function Session:settimeout(t) self.timeout = t return true end
function Session:getpeername() return self.sock:getpeername() end
function Session:getsockname() return self.sock:getsockname() end
function Session:setoption(...) return self.sock:setoption(...) end
function Session:state() return self.closed and "CLOSED" or self.sock:state() end

function Session:send(data, timeout)
  if self.closed then return nil, "closed" end
  timeout = timeout or self.timeout
  local sent = 0
  while sent < #data do
    local chunk = data:sub(sent + 1, sent + M.MAX_RECORD)
    local ok, err = writeRecord(self.sock, T_DATA, sealRecord(self, T_DATA, chunk), timeout)
    if not ok then return nil, err, sent end
    sent = sent + #chunk
  end
  return sent
end

--- Take the next record into the buffer. Returns true, or nil + reason ("closed" after a close_notify).
local function fill(self, timeout)
  local typ, payload = readRecord(self.sock, timeout)
  if not typ then return nil, payload end
  if typ == T_DATA then
    local plain = openRecord(self, typ, payload)
    if not plain then self.closed = true self.sock:close() return nil, "bad record (the connection was tampered with)" end
    self.buf = self.buf .. plain
    return true
  elseif typ == T_ALERT then
    openRecord(self, typ, payload)
    self.closed = true
    self.sock:close()
    return nil, "closed"
  end
  self.closed = true
  self.sock:close()
  return nil, "unexpected record"
end

function Session:receive(pattern, timeout)
  timeout = timeout or self.timeout
  pattern = pattern or "*l"
  local stack = self.sock.stack
  local deadline = timeout and (stack.clock() + timeout)
  local function left() return deadline and math.max(0, deadline - stack.clock()) or nil end
  if type(pattern) == "number" then
    while #self.buf < pattern do
      local ok, err = fill(self, left())
      if not ok then local partial = self.buf self.buf = "" return nil, err, partial end
    end
    local out = self.buf:sub(1, pattern)
    self.buf = self.buf:sub(pattern + 1)
    return out
  elseif pattern == "*l" or pattern == "l" then
    while true do
      local nl = self.buf:find("\n", 1, true)
      if nl then
        local line = self.buf:sub(1, nl - 1)
        self.buf = self.buf:sub(nl + 1)
        return (line:gsub("\r$", ""))
      end
      local ok, err = fill(self, left())
      if not ok then local partial = self.buf self.buf = "" return nil, err, partial end
    end
  elseif pattern == "*a" or pattern == "a" then
    while true do
      local ok, err = fill(self, left())
      if not ok then
        if err == "closed" then local all = self.buf self.buf = "" return all end
        local partial = self.buf self.buf = "" return nil, err, partial
      end
    end
  elseif pattern == "*any" or pattern == "any" then
    if #self.buf == 0 then
      local ok, err = fill(self, left())
      if not ok then return nil, err end
    end
    local out = self.buf
    self.buf = ""
    return out
  end
  return nil, "bad receive pattern"
end

function Session:close()
  if not self.closed then
    self.closed = true
    pcall(function() writeRecord(self.sock, T_ALERT, sealRecord(self, T_ALERT, "\0"), 2) end)
  end
  self.sock:close()
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Handshake
---------------------------------------------------------------------------------------------------------------------

local function deriveKeys(shared, h1)
  local okm = crypto.kdf.hkdf(shared, h1, "tessera-tls-v1 keys", 64)
  return okm:sub(1, 32), okm:sub(33, 64)
end

local function finishedValue(label, h1, sig) return crypto.kdf.sha256(label .. h1 .. sig) end

--- Wrap a connected TCP socket as the client. opts: store (trust store, default M.store()), now (UTC ms), timeout (20), ignoreTime.
--- Returns the secure socket, or nil + reason (+ detail text).
function M.client(sock, host, opts)
  opts = opts or {}
  local timeout = opts.timeout or 20
  local eph = crypto.agreementKey()
  local random = crypto.rand.bytes(32)
  local sni = tostring(host or ""):lower()
  local ch = string.char(M.VERSION) .. random .. eph.public .. string.char(#sni) .. sni
  local ok, err = writeRecord(sock, T_CLIENT_HELLO, ch, timeout)
  if not ok then return nil, "handshake failed: " .. tostring(err) end
  local typ, sh = readRecord(sock, timeout)
  if typ ~= T_SERVER_HELLO then sock:close() return nil, "handshake failed", typ == T_ALERT and "the server refused: " .. tostring(sh:byte(1)) or "unexpected answer" end
  if #sh < 1 + 32 + 32 + 2 or sh:byte(1) ~= M.VERSION then sock:close() return nil, "handshake failed", "bad server hello" end
  local spub = sh:sub(34, 65)
  local certLen = rd16(sh, 66)
  local certText = sh:sub(68, 67 + certLen)
  local sig = sh:sub(68 + certLen, 131 + certLen)
  local shBody = sh:sub(1, 67 + certLen)
  if #sig ~= 64 then sock:close() return nil, "handshake failed", "damaged server hello" end
  local c, cerr = cert.decode(certText)
  if not c then sock:close() return nil, "handshake failed", cerr end
  local store = opts.store or M.store()
  local now = opts.ignoreTime and c.from or opts.now
  local trusted, how, detail = M.verify(c, host, store, now)
  if not trusted then
    pcall(writeRecord, sock, T_ALERT, "\1", 2)
    sock:close()
    return nil, "certificate rejected: " .. how, detail
  end
  local h1 = crypto.kdf.sha256("tessera-tls-v1" .. ch .. shBody)
  if not crypto.verifyData(c.key, h1, sig, "tls-server") then sock:close() return nil, "handshake failed", "the server did not prove that it owns the certificate" end
  if how == "new" and store.tofu then
    if store.pin then store:pin(host, cert.fingerprint(c)) end
  end
  local shared = crypto.x25519.shared(eph.secret, spub)
  if not shared then sock:close() return nil, "handshake failed", "bad key exchange" end
  local c2s, s2c = deriveKeys(shared, h1)
  local session = newSession(sock, c2s, s2c, 0, 1, { cert = c, trust = how, fingerprint = cert.fingerprint(c), name = c.subject })
  local fin = sealRecord(session, T_FINISHED, finishedValue("client finished", h1, sig))
  ok, err = writeRecord(sock, T_FINISHED, fin, timeout)
  if not ok then return nil, "handshake failed: " .. tostring(err) end
  local t2, sfin = readRecord(sock, timeout)
  if t2 ~= T_FINISHED then sock:close() return nil, "handshake failed", "the server did not finish the handshake" end
  local expect = openRecord(session, T_FINISHED, sfin)
  if not expect or not crypto.equal(expect, finishedValue("server finished", h1, sig)) then sock:close() return nil, "handshake failed", "bad finished message" end
  return session
end

--- Wrap an accepted TCP socket as the server. opts: cert (decoded certificate), key (signing key pair { secret, public } of the certificate),
--- certs (a list of { cert, key } to choose from by the name the client asks for), timeout (20).
function M.server(sock, opts)
  local timeout = opts.timeout or 20
  local typ, ch = readRecord(sock, timeout)
  if typ ~= T_CLIENT_HELLO or #ch < 66 or ch:byte(1) ~= M.VERSION then sock:close() return nil, "handshake failed", "bad client hello" end
  local cpub = ch:sub(34, 65)
  local sniLen = ch:byte(66)
  local sni = ch:sub(67, 66 + sniLen)
  local chosen = { cert = opts.cert, key = opts.key }
  if opts.certs then
    for _, e in ipairs(opts.certs) do if cert.matches(e.cert, sni) then chosen = e break end end
    chosen = chosen.cert and chosen or opts.certs[1]
  end
  local eph = crypto.agreementKey()
  local certText = cert.encode(chosen.cert)
  local shBody = string.char(M.VERSION) .. crypto.rand.bytes(32) .. eph.public .. u16(#certText) .. certText
  local h1 = crypto.kdf.sha256("tessera-tls-v1" .. ch .. shBody)
  local sig = crypto.signData(chosen.key.secret, h1, "tls-server")
  local ok, err = writeRecord(sock, T_SERVER_HELLO, shBody .. sig, timeout)
  if not ok then return nil, "handshake failed: " .. tostring(err) end
  local shared = crypto.x25519.shared(eph.secret, cpub)
  if not shared then sock:close() return nil, "handshake failed", "bad key exchange" end
  local c2s, s2c = deriveKeys(shared, h1)
  local session = newSession(sock, s2c, c2s, 1, 0, { name = sni, cert = chosen.cert })
  local t2, cfin = readRecord(sock, timeout)
  if t2 ~= T_FINISHED then sock:close() return nil, "handshake failed", "the client did not finish the handshake" end
  local plain = openRecord(session, T_FINISHED, cfin)
  if not plain or not crypto.equal(plain, finishedValue("client finished", h1, sig)) then
    pcall(writeRecord, sock, T_ALERT, "\2", 2)
    sock:close()
    return nil, "handshake failed", "bad finished message"
  end
  ok, err = writeRecord(sock, T_FINISHED, sealRecord(session, T_FINISHED, finishedValue("server finished", h1, sig)), timeout)
  if not ok then return nil, "handshake failed: " .. tostring(err) end
  return session
end

---------------------------------------------------------------------------------------------------------------------
-- Server credentials on disk
---------------------------------------------------------------------------------------------------------------------

--- Load <dir>/<name>.crt and <dir>/<name>.key. Returns { cert, key } or nil + reason.
function M.loadCredentials(name, dir)
  dir = dir or M.DIR
  local c, err = cert.decode(vfs.readFile(dir .. "/" .. name .. ".crt"))
  if not c then return nil, "no certificate " .. dir .. "/" .. name .. ".crt (" .. tostring(err) .. ")" end
  local seed = crypto.base64Decode((vfs.readFile(dir .. "/" .. name .. ".key") or ""):gsub("%s+", ""))
  if not seed or #seed ~= 32 then return nil, "no key " .. dir .. "/" .. name .. ".key" end
  local pair = crypto.signingKey(seed)
  if pair.public ~= c.key then return nil, "the key does not belong to the certificate" end
  return { cert = c, key = pair }
end

function M.saveKey(path, pair) return vfs.writeFile(path, crypto.base64Encode(pair.secret) .. "\n") end

return M
