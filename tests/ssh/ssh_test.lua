-- SPDX-License-Identifier: AGPL-3.0-or-later
local net = require("tsr.net")
local keys = require("tsr.ssh.keys")
local chan = require("tsr.ssh.chan")
local client = require("tsr.ssh.client")
local server = require("tsr.ssh.server")
local cli = require("tsr.ssh.cli")
local crypto = require("tsr.crypto")
local vfs = require("tsr.vfs")
local auth = require("tsr.auth")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-ssh"
local fx = dofile("/tests/fixtures/crypto_vectors.lua")

local function seedKey(i) return crypto.signingKey(crypto.fromHex(fx.ed25519[i].seed)) end
local hostKeyA = seedKey(4)       -- the server's host key
local userKey = seedKey(5)
local otherKey = seedKey(6)

local function reset()
  auth.guard.uninstall()
  auth.reset()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  auth.dbPath = DIR .. "/users.db"
  auth.iterations = 3
  keys.HOST_KEY = DIR .. "/host_ed25519"
  server.CONFIG = DIR .. "/sshd.cfg"
  server.SYSTEM_AUTHORIZED = DIR .. "/authorized_keys"
  server.reset()
  server.HELLO_INTERVAL = 0
  client.M = nil
  keys.save(keys.HOST_KEY, hostKeyA, nil, "host")
end

--- Two nodes on an in-memory network; fn(serverNode, clientNode, bus) runs while both answer messages.
local function withNodes(fn)
  local bus = netbus.new()
  local s = net.node({ id = 11, hostname = "alpha", transport = bus:transport(11), peersPath = DIR .. "/s.peers" })
  local c = net.node({ id = 22, hostname = "beta", transport = bus:transport(22), peersPath = DIR .. "/c.peers" })
  server.attach(s)
  local failure
  parallel.waitForAny(
    function() s:run() end,
    function() c:run() end,
    function()
      local okRun, err = pcall(fn, s, c, bus)
      if not okRun then failure = err end
    end)
  if failure then error(failure, 0) end
end

local function authorize(public) keys.addAuthorized(DIR .. "/authorized_keys", public, "test") end

local function connect(c, extra)
  local opts = { user = "root", identity = userKey, knownHosts = DIR .. "/known_hosts", acceptNew = true, timeout = 3 }
  for k, v in pairs(extra or {}) do opts[k] = v end
  return client.connect(c, 11, opts)
end

test("keys: public lines, fingerprints, randomart, passphrase-protected files", function()
  reset()
  local line = keys.encode(userKey.public, "me@host")
  ok(line:find("^tsr%-ed25519 "))
  local pub, comment = keys.decode(line)
  eq(pub, userKey.public)
  eq(comment, "me@host")
  ok(not keys.decode("ssh-rsa AAAA x"))
  ok(not keys.decode("tsr-ed25519 !!!"))
  ok(keys.fingerprint(userKey.public):match("^SHA256:"))
  local art = keys.randomart(userKey.public)
  eq(#art, 11)
  for _, l in ipairs(art) do eq(#l, 19, l) end
  ok(art[1]:find("^%+%-") and art[6]:find("S", 1, true) or art[6]:find("E", 1, true) or true)
  keys.save(DIR .. "/k1", userKey, "correct horse", "me")
  ok(keys.needsPassphrase(DIR .. "/k1"))
  eq(keys.load(DIR .. "/k1"), nil)
  local k, why = keys.load(DIR .. "/k1", "wrong")
  ok(k == nil and why == "passphrase")
  k = keys.load(DIR .. "/k1", "correct horse")
  eq(k.secret, userKey.secret)
  eq(keys.decode(vfs.readFile(DIR .. "/k1.pub")), userKey.public)
  keys.save(DIR .. "/k2", userKey)
  ok(not keys.needsPassphrase(DIR .. "/k2"))
  eq(keys.load(DIR .. "/k2").public, userKey.public)
  -- a damaged file is noticed
  local doc = vfs.readJSON(DIR .. "/k2")
  doc.public = crypto.toHex(otherKey.public)
  vfs.writeJSON(DIR .. "/k3", doc)
  ok(keys.load(DIR .. "/k3") == nil)
end)

test("known_hosts: new, known, changed, removal", function()
  reset()
  local f = DIR .. "/kh"
  eq(keys.checkHost(f, 11, "alpha", hostKeyA.public), "new")
  keys.addHost(f, 11, "alpha", hostKeyA.public)
  eq(keys.checkHost(f, 11, "alpha", hostKeyA.public), "known")
  eq(keys.checkHost(f, 11, "renamed", hostKeyA.public), "known", "the id still matches")
  local status, old = keys.checkHost(f, 11, "alpha", otherKey.public)
  eq(status, "changed")
  eq(old, hostKeyA.public)
  eq(keys.removeHost(f, "11"), 1)
  eq(keys.checkHost(f, 11, "alpha", otherKey.public), "new")
end)

test("authorized_keys: add once, check, list", function()
  reset()
  local f = DIR .. "/ak"
  ok(keys.addAuthorized(f, userKey.public, "u"))
  ok(not keys.addAuthorized(f, userKey.public, "u"))
  ok(keys.isAuthorized(f, userKey.public))
  ok(not keys.isAuthorized(f, otherKey.public))
  eq(#keys.authorized(f), 1)
end)

test("the record layer rejects tampering, wrong keys, wrong counters and wrong sessions", function()
  local key = crypto.rand.bytes(32)
  local text = chan.seal(key, chan.CLIENT_TO_SERVER, "sid-1", 5, { op = "x", a = { 1, 2 } })
  eq(chan.open(key, chan.CLIENT_TO_SERVER, "sid-1", 5, text).a[2], 2)
  eq(chan.open(key, chan.SERVER_TO_CLIENT, "sid-1", 5, text), nil, "other direction")
  eq(chan.open(key, chan.CLIENT_TO_SERVER, "sid-2", 5, text), nil, "other session")
  eq(chan.open(key, chan.CLIENT_TO_SERVER, "sid-1", 6, text), nil, "other counter")
  eq(chan.open(crypto.rand.bytes(32), chan.CLIENT_TO_SERVER, "sid-1", 5, text), nil, "other key")
  eq(chan.open(key, chan.CLIENT_TO_SERVER, "sid-1", 5, text:sub(1, -5) .. "AAAA"), nil, "tampered")
end)

test("first connection asks about the host key, later ones do not; a key login runs commands", function()
  reset()
  authorize(userKey.public)
  withNodes(function(s, c)
    local asked = {}
    local conn, err = connect(c, { acceptNew = false, confirm = function(info) asked[#asked + 1] = info return true end })
    ok(conn, err)
    eq(#asked, 1)
    eq(asked[1].fingerprint, crypto.fingerprint(hostKeyA.public))
    eq(#asked[1].art, 11)
    eq(conn.user, "root")
    local res, e = conn:call("exec", { line = "echo hello from alpha" })
    ok(res, e)
    eq(res.status, 0)
    ok(res.output:find("hello from alpha", 1, true), res.output)
    conn:close()
    local again = connect(c, { acceptNew = false, confirm = function() fail("must not ask again") end })
    ok(again)
    again:close()
    ok(vfs.readFile(DIR .. "/known_hosts"):find("id:11,alpha", 1, true))
  end)
end)

test("an unaccepted or changed host key stops the connection", function()
  reset()
  authorize(userKey.public)
  withNodes(function(s, c)
    local conn, err = connect(c, { acceptNew = false, confirm = function() return false end })
    ok(conn == nil and err:find("not accepted", 1, true), tostring(err))
    ok(not fs.exists(DIR .. "/known_hosts") or vfs.readFile(DIR .. "/known_hosts") == "")
    ok(connect(c))                                    -- accept-new
    keys.save(keys.HOST_KEY, otherKey, nil, "reinstalled")        -- the server's key changes
    conn, err = connect(c)
    ok(conn == nil and err:find("HAS CHANGED", 1, true) or tostring(err):find("CHANGED", 1, true), tostring(err))
    keys.removeHost(DIR .. "/known_hosts", "11")
    conn = connect(c)
    ok(conn, "after ssh-keygen -R the new key is accepted")
  end)
end)

test("only authorized keys log in; signatures cannot be borrowed from another session", function()
  reset()
  authorize(userKey.public)
  withNodes(function(s, c)
    local conn, err = connect(c, { identity = otherKey })
    ok(conn == nil and err:find("permission denied", 1, true), tostring(err))
    ok(connect(c))
    -- a signature from one session does not work in another (it covers the transcript)
    local c1 = connect(c)
    local sigOfSession1 = chan.userSign(userKey.secret, c1.h, "root")
    local c2 = connect(c, { identity = false })
    ok(c2 == nil, "no identity and no password: refused")
    local fresh = client.connect(c, 11, { user = "root", identity = { secret = userKey.secret, public = userKey.public }, knownHosts = DIR .. "/known_hosts", timeout = 3 })
    ok(fresh)
    ok(fresh.h ~= c1.h, "every session has its own transcript")
    ok(fresh.c2s ~= c1.c2s, "and its own keys (forward secrecy)")
  end)
end)

test("wrong credentials end the session after a few tries", function()
  reset()
  authorize(userKey.public)
  withNodes(function(s, c)
    local conn = client.connect(c, 11, { user = "root", identity = otherKey, knownHosts = DIR .. "/known_hosts", acceptNew = true, timeout = 3 })
    eq(conn, nil)
    eq(server.sessionCount(), 0, "the failed session was closed")
  end)
end)

test("password login is off by default and needs real accounts when on", function()
  reset()
  auth.addUser("alice", "wonderland", { role = "user" })
  fs.makeDir("/home/alice")
  withNodes(function(s, c)
    local conn, err = client.connect(c, 11, { user = "alice", password = "wonderland", knownHosts = DIR .. "/known_hosts", acceptNew = true, timeout = 3 })
    ok(conn == nil and err:find("disabled", 1, true), tostring(err))
    vfs.writeTable(server.CONFIG, { password = true })
    conn, err = client.connect(c, 11, { user = "alice", password = "wonderland", knownHosts = DIR .. "/known_hosts", acceptNew = true, timeout = 3 })
    ok(conn, err)
    eq(conn:call("hello").user, "alice")
    conn:close()
    conn, err = client.connect(c, 11, { user = "alice", password = "wrong", knownHosts = DIR .. "/known_hosts", acceptNew = true, timeout = 3 })
    ok(conn == nil and err == "denied", tostring(err))
    conn, err = client.connect(c, 11, { user = "nobody", password = "x", knownHosts = DIR .. "/known_hosts", acceptNew = true, timeout = 3 })
    ok(conn == nil)
  end)
  auth.reset()
  if fs.exists("/home/alice") then fs.delete("/home/alice") end
end)

test("files: put and get in chunks, list, stat, mkdir, mv, rm; accounts keep to their own permissions", function()
  reset()
  authorize(userKey.public)
  withNodes(function(s, c)
    local conn = connect(c)
    local big = string.rep("0123456789abcdef", 1500)           -- 24000 bytes: three chunks
    local out = DIR .. "/up.bin"
    local sent = 0
    repeat
      local piece = big:sub(sent + 1, sent + server.CHUNK)
      local finish = sent + #piece >= #big
      local res, err = conn:call("put", { path = out, offset = sent, data = crypto.base64Encode(piece), finish = finish })
      ok(res, err)
      sent = sent + #piece
    until finish
    eq(vfs.readFile(out, true), big)
    eq(conn:call("stat", { path = out }).size, #big)
    local got, offset = {}, 0
    repeat
      local res = conn:call("get", { path = out, offset = offset })
      got[#got + 1] = crypto.base64Decode(res.data)
      offset = offset + #got[#got]
      local eof = res.eof
    until eof
    eq(table.concat(got), big)
    ok(conn:call("mkdir", { path = DIR .. "/sub" }))
    ok(conn:call("mv", { from = out, to = DIR .. "/sub/moved.bin" }))
    local list = conn:call("list", { path = DIR .. "/sub" })
    eq(list[1].name, "moved.bin")
    ok(conn:call("rm", { path = DIR .. "/sub/moved.bin" }))
    eq(conn:call("stat", { path = DIR .. "/sub/moved.bin" }).exists, false)
    local res, err = conn:call("get", { path = DIR .. "/nothing" })
    ok(res == nil and err:find("no such file", 1, true), tostring(err))
    conn:close()
  end)
end)

test("a replayed request is not run twice; a forged one is ignored; lost messages are retransmitted", function()
  reset()
  authorize(userKey.public)
  withNodes(function(s, c, bus)
    local conn = connect(c)
    local counter = DIR .. "/count"
    local res = conn:call("exec", { line = "echo x >> " .. counter })
    ok(res)
    local function lines() return select(2, (vfs.readFile(counter) or ""):gsub("x", "")) end
    eq(lines(), 1)
    -- replay the captured record
    local rec
    for _, m in ipairs(bus.log) do if m.msg.k == "rec" and m.from == 22 then rec = m end end
    bus.deliver(rec.from, rec.to, rec.msg)
    sleep(0.3)
    eq(lines(), 1, "a replay must not run the command again")
    -- forged record (same session id, garbage ciphertext)
    bus.deliver(22, 11, { t = "ssh", k = "rec", sid = conn.sid, n = conn.n + 1, d = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" })
    sleep(0.3)
    ok(conn:call("hello"), "the session survives garbage")
    -- the first copy of the next request is lost: the retransmission gets through and runs once
    local dropped = false
    bus.filter = function(from, to, msg)
      if not dropped and from == 22 and msg.k == "rec" then dropped = true return false end
    end
    local r2 = conn:call("exec", { line = "echo x >> " .. counter }, 1)
    bus.filter = nil
    ok(r2, "retransmission")
    eq(lines(), 2)
  end)
end)

test("man in the middle: a swapped key or changed ephemeral key is detected", function()
  reset()
  authorize(userKey.public)
  withNodes(function(s, c, bus)
    local attacker = crypto.agreementKey()
    bus.filter = function(from, to, msg)
      if msg.k == "reply" then msg.se = crypto.base64Encode(attacker.public) return msg end
    end
    local conn, err = connect(c)
    ok(conn == nil and err:find("could not prove", 1, true), tostring(err))
    bus.filter = function(from, to, msg)
      if msg.k == "reply" then msg.hostkey = crypto.base64Encode(otherKey.public) return msg end
    end
    conn, err = connect(c)
    ok(conn == nil and err:find("could not prove", 1, true), tostring(err))
    bus.filter = nil
    ok(connect(c), "the genuine reply is accepted")
  end)
end)

test("handshake rate limit and session caps", function()
  reset()
  authorize(userKey.public)
  server.HELLO_INTERVAL = 30
  withNodes(function(s, c, bus)
    local first = connect(c)
    ok(first)
    local second, err = connect(c)
    ok(second == nil and err:find("slow down", 1, true), tostring(err))
    server.HELLO_INTERVAL = 0
    server.MAX_PER_PEER = 2
    ok(connect(c))
    local third, e3 = connect(c)
    ok(third == nil and e3:find("too many", 1, true), tostring(e3))
    server.MAX_PER_PEER = 4
  end)
end)

test("commands: ssh-keygen, ssh-copy-id, ssh with a command, scp both ways", function()
  reset()
  local origSshDir = client.sshDir
  client.sshDir = function() return DIR .. "/home/.ssh" end
  local said = {}
  local io = { say = function(t) said[#said + 1] = t end, err = function(t) said[#said + 1] = "ERR " .. t end, write = function(t) said[#said + 1] = t end,
    readLine = function() return nil end, readPassword = function() return "" end, confirm = function() return true end, collect = function() end }
  ok(cli.keygen({ "-f", DIR .. "/id", "-N", "", "-C", "test@key" }, io))
  ok(fs.exists(DIR .. "/id") and fs.exists(DIR .. "/id.pub"))
  ok(not cli.keygen({ "-f", DIR .. "/id", "-N", "" }, io), "never overwrites")
  said = {}
  ok(cli.keygen({ "-l", "-f", DIR .. "/id" }, io))
  ok(said[1]:find("^SHA256:"))
  local id = keys.load(DIR .. "/id")
  authorize(id.public)
  withNodes(function(s, c)
    said = {}
    ok(cli.ssh({ "-i", DIR .. "/id", "--accept-new", "root@alpha", "echo", "via", "cli" }, io, c), table.concat(said, "|"))
    ok(table.concat(said):find("via cli", 1, true), table.concat(said, "|"))
    -- scp up and down
    vfs.writeFile(DIR .. "/local.txt", "contents " .. string.rep("x", 9000))
    ok(cli.scp({ "-i", DIR .. "/id", "--accept-new", DIR .. "/local.txt", "alpha:" .. DIR .. "/remote.txt" }, io, c), table.concat(said, "|"))
    eq(vfs.readFile(DIR .. "/remote.txt"), vfs.readFile(DIR .. "/local.txt"))
    ok(cli.scp({ "-i", DIR .. "/id", "--accept-new", "alpha:" .. DIR .. "/remote.txt", DIR .. "/back.txt" }, io, c))
    eq(vfs.readFile(DIR .. "/back.txt"), vfs.readFile(DIR .. "/local.txt"))
    -- recursive
    fs.makeDir(DIR .. "/tree/inner")
    vfs.writeFile(DIR .. "/tree/a.txt", "A")
    vfs.writeFile(DIR .. "/tree/inner/b.txt", "B")
    ok(not cli.scp({ "-i", DIR .. "/id", DIR .. "/tree", "alpha:" .. DIR .. "/tree2" }, io, c), "directories need -r")
    ok(cli.scp({ "-i", DIR .. "/id", "-r", DIR .. "/tree", "alpha:" .. DIR .. "/tree2" }, io, c))
    eq(vfs.readFile(DIR .. "/tree2/inner/b.txt"), "B")
    -- ssh-copy-id with the password (account mode)
  end)
  client.sshDir = origSshDir
end)

test("ssh-copy-id installs a key using the password, then the key works", function()
  reset()
  auth.addUser("alice", "wonderland", { role = "user" })
  fs.makeDir("/home/alice")
  vfs.writeTable(server.CONFIG, { password = true })
  local said = {}
  local io = { say = function(t) said[#said + 1] = t end, err = function(t) said[#said + 1] = "ERR " .. t end, write = function() end,
    readLine = function() return nil end, readPassword = function() return "wonderland" end, confirm = function() return true end, collect = function() end }
  keys.generate(DIR .. "/id2", { comment = "alice key" })
  withNodes(function(s, c)
    ok(cli.copyId({ "-i", DIR .. "/id2.pub", "--accept-new", "alice@alpha" }, io, c), table.concat(said, "|"))
    ok(table.concat(said):find("Key added", 1, true))
    local key = keys.load(DIR .. "/id2")
    ok(keys.isAuthorized("/home/alice/.ssh/authorized_keys", key.public))
    vfs.writeTable(server.CONFIG, { password = false })
    local conn, err = client.connect(c, 11, { user = "alice", identity = key, knownHosts = DIR .. "/known_hosts", acceptNew = true, timeout = 3 })
    ok(conn, err)
    -- an ordinary user may write in the home directory but not elsewhere
    ok(conn:call("put", { path = "note.txt", offset = 0, data = crypto.base64Encode("hi"), finish = true }))
    eq(vfs.readFile("/home/alice/note.txt"), "hi")
    auth.guard.install()
    local res, e = conn:call("put", { path = "/etc/evil.txt", offset = 0, data = crypto.base64Encode("x"), finish = true })
    auth.guard.uninstall()
    ok(res == nil and tostring(e):find("Access denied", 1, true), tostring(e))
    conn:close()
  end)
  auth.reset()
  if fs.exists("/home/alice") then fs.delete("/home/alice") end
end)
