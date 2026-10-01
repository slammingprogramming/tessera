-- SPDX-License-Identifier: AGPL-3.0-or-later
local net = require("tsr.net")
local crypto = require("tsr.net.crypto")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-net"

--- Two nodes (ids 11 and 22) on one bus with their daemons running; `fn(a, b, bus)` is the test body.
local function withNodes(fn, setup)
  if fs.exists(DIR) then fs.delete(DIR) end
  local bus = netbus.new()
  local a = net.node({ id = 11, hostname = "alpha", transport = bus:transport(11), peersPath = DIR .. "/a.peers" })
  local b = net.node({ id = 22, hostname = "beta", transport = bus:transport(22), peersPath = DIR .. "/b.peers" })
  if setup then setup(a, b, bus) end
  local failure
  parallel.waitForAny(
    function() a:run() end,
    function() b:run() end,
    function()
      local ok, err = pcall(fn, a, b, bus)
      if not ok then failure = err end
    end)
  if failure then error(failure, 0) end
end

--- Pair a and b using a known code (b's side runs in a helper coroutine).
local function pair(a, b)
  local result
  parallel.waitForAll(
    function() result = a:pairListen({ code = "ABCDE-FGHJK", timeout = 10 }) end,
    function()
      sleep(0.2)
      local peer, err = b:pairConnect(11, "ABCDE-FGHJK", 5)
      ok(peer, err)
    end)
  ok(result, "listener did not finish")
end

test("crypto: random, streams, encryption and codes", function()
  eq(#crypto.random(40), 40)
  ok(crypto.randomHex(16) ~= crypto.randomHex(16))
  eq(#crypto.randomHex(16), 32)
  eq(crypto.stream("k", "n", 100), crypto.stream("k", "n", 100))
  ok(crypto.stream("k", "n", 20) ~= crypto.stream("k", "m", 20))
  eq(#crypto.stream("k", "n", 1000), 1000)
  local plain = "hello, wörld \0 binary \255 data"
  local c = crypto.encrypt("key", "nonce1", plain)
  ok(not c:find("hello", 1, true))
  eq(crypto.decrypt("key", "nonce1", c), plain)
  ok(crypto.decrypt("other", "nonce1", c) ~= plain)
  ok(crypto.equal("abc", "abc"))
  ok(not crypto.equal("abc", "abd"))
  ok(not crypto.equal("abc", "ab"))
  local code = crypto.pairingCode()
  ok(code:match("^[A-Z2-9]+%-[A-Z2-9]+$") and #code == 11, code)
  ok(code ~= crypto.pairingCode())
  eq(crypto.cleanCode(" abcde-fghjk "), "ABCDEFGHJK")
  crypto.addEntropy("x", 1, 2)
end)

test("discovery finds computers by service and by name", function()
  withNodes(function(a, b)
    b:serve("files", function() end)
    local all = a:lookup(nil, 0.3)
    eq(#all, 1)
    eq(all[1].host, "beta")
    eq(all[1].id, 22)
    eq(all[1].services, { "files" })
    eq(#a:lookup("files", 0.3), 1)
    eq(#a:lookup("nothing", 0.3), 0)
    eq(a:resolve("beta"), 22)
    eq(a:resolve(7), 7)
    local id, err = a:resolve("ghost", 0.2)
    ok(id == nil and err:find("ghost"))
    eq(#a:lookup(nil, 0.3, "gamma"), 0)
  end)
end)

test("ping and time", function()
  withNodes(function(a, b)
    local rtt, host = a:ping(22, 1)
    ok(rtt and rtt >= 0 and host == "beta")
    local nothing, err = a:ping(99, 0.3)
    ok(nothing == nil and err:find("no answer"))
    local t = a:time(22, 1)
    ok(t and type(t.utc) == "number" and type(t.offset) == "number")
    ok(math.abs(t.offset) < 5000, "same machine, same clock: " .. t.offset)
  end)
end)

test("pairing stores the same key on both sides", function()
  withNodes(function(a, b)
    pair(a, b)
    local pa, pb = a:peer("beta"), b:peer("alpha")
    ok(pa and pb)
    eq(pa.key, pb.key)
    eq(#pa.key, 64)
    eq(pa.id, 22)
    eq(pb.id, 11)
    eq(a:peers()[1].name, "beta")
    -- the key never crosses the wire in clear
    -- (the bus log is checked in the eavesdropping test below)
  end)
end)

test("pairing never exposes the key to an eavesdropper", function()
  withNodes(function(a, b, bus)
    pair(a, b)
    local key = a:peer("beta").key
    for _, entry in ipairs(bus.log) do
      ok(not textutils.serialize(entry.msg):lower():find(key, 1, true), "key visible in " .. entry.msg.t)
    end
  end)
end)

test("pairing with a wrong code fails silently and the listener gives up", function()
  withNodes(function(a, b)
    local result, why
    parallel.waitForAll(
      function() result, why = a:pairListen({ code = "AAAAA-BBBBB", timeout = 10, attempts = 2 }) end,
      function()
        sleep(0.2)
        for _ = 1, 2 do
          local peer, err = b:pairConnect(11, "ZZZZZ-YYYYY", 0.4)
          ok(peer == nil and err:find("no answer"), tostring(err))
        end
      end)
    ok(result == nil and why:find("too many"), tostring(why))
    ok(a:peer("beta") == nil and b:peer("alpha") == nil)
  end)
end)

test("pairing times out when nobody connects, and rejects malformed codes", function()
  withNodes(function(a, b)
    local r, why = a:pairListen({ code = "AAAAA-BBBBB", timeout = 0.5 })
    ok(r == nil and why == "timed out")
    r, why = b:pairConnect(11, "short", 1)
    ok(r == nil and why:find("10 characters"))
  end)
end)

test("authenticated calls", function()
  withNodes(function(a, b)
    pair(a, b)
    b:serve("math", function(from, method, args)
      if method == "add" then return args.x + args.y end
      error("unknown method " .. tostring(method), 0)
    end)
    eq(a:call("beta", "math", "add", { x = 2, y = 40 }), 42)
    eq(a:call(22, "math", "add", { x = 1, y = 1 }), 2)
    local r, err = a:call("beta", "math", "nope", {})
    ok(r == nil and err:find("unknown method nope"), tostring(err))
    r, err = a:call("beta", "ghost", "x", {})
    ok(r == nil and err:find("no such service"))
    -- calls the other way round work too
    a:serve("hello", function(from) return "hi " .. from end)
    eq(b:call("alpha", "hello", "x"), "hi 22")
    -- unpaired
    r, err = a:call("stranger", "math", "add", {})
    ok(r == nil and err:find("not paired"))
  end)
end)

test("service access can be restricted per peer", function()
  withNodes(function(a, b)
    pair(a, b)
    b:serve("admin", function() return "secret" end, { allow = function(peer) return peer.name == "someone-else" end })
    local r, err = a:call("beta", "admin", "x", nil)
    ok(r == nil and err == "not allowed", tostring(err))
  end)
end)

test("calls are not forgeable, tamperable or replayable", function()
  withNodes(function(a, b, bus)
    pair(a, b)
    local runs = 0
    b:serve("count", function() runs = runs + 1 return runs end)
    eq(a:call("beta", "count", "go"), 1)
    -- replay the captured request verbatim
    local captured
    for _, e in ipairs(bus.log) do if e.msg.t == "rpc" then captured = e end end
    ok(captured)
    bus.deliver(captured.from, captured.to, captured.msg)
    sleep(0.3)
    eq(runs, 1, "a replayed request must not run again")
    -- tamper with the payload in flight: no answer, nothing runs
    bus.filter = function(from, to, msg)
      if msg.t == "rpc" then msg.p = msg.p .. " " end
      return msg
    end
    local r, err = a:call("beta", "count", "go", nil, { timeout = 0.5 })
    ok(r == nil and err:find("no answer"))
    eq(runs, 1)
    bus.filter = nil
    -- a stranger cannot call at all (no pairing, no key)
    local stranger = net.node({ id = 33, hostname = "eve", transport = bus:transport(33), peersPath = DIR .. "/e.peers" })
    stranger:addPeer(22, "beta", crypto.randomHex(32))      -- guesses a key
    local res, e2 = stranger:call("beta", "count", "go", nil, { timeout = 0.5 })
    ok(res == nil)
    eq(runs, 1)
    -- a forged reply is detected by the caller
    bus.filter = function(from, to, msg)
      if msg.t == "rpc.r" then msg.mac = string.rep("0", 64) end
      return msg
    end
    res, e2 = a:call("beta", "count", "go", nil, { timeout = 1 })
    ok(res == nil and e2:find("bad signature"), tostring(e2))
  end)
end)

test("encrypted calls hide their contents", function()
  withNodes(function(a, b, bus)
    pair(a, b)
    b:serve("vault", function(from, method, args) return "reply:" .. args.secret end)
    local res = a:call("beta", "vault", "put", { secret = "swordfish" }, { encrypt = true })
    eq(res, "reply:swordfish")
    for _, e in ipairs(bus.log) do
      if e.msg.t == "rpc" or e.msg.t == "rpc.r" then
        ok(not textutils.serialize(e.msg):find("swordfish", 1, true), "plaintext leaked in " .. e.msg.t)
      end
    end
    -- plain calls are readable (authenticated only), which is why encryption is opt-in per call
    a:call("beta", "vault", "put", { secret = "visible" })
    local seen = false
    for _, e in ipairs(bus.log) do
      if e.msg.t == "rpc" and textutils.serialize(e.msg):find("visible", 1, true) then seen = true end
    end
    ok(seen)
  end)
end)

test("peers persist and can be removed", function()
  withNodes(function(a, b)
    pair(a, b)
    local a2 = net.node({ id = 11, hostname = "alpha", transport = { send = function() end, broadcast = function() end, receive = function() end },
                          peersPath = DIR .. "/a.peers" })
    ok(a2:peer("beta"))
    ok(a:removePeer("beta"))
    ok(a:peer("beta") == nil)
    local r, err = a:removePeer("beta")
    ok(r == nil and err:find("not paired"))
  end)
end)

test("the net command", function()
  withNodes(function(a, b)
    local function run(node, ...)
      local out = { said = {}, errs = {} }
      function out.say(t) out.said[#out.said + 1] = t end
      function out.err(t) out.errs[#out.errs + 1] = t end
      out.ok = out.say
      local cli = require("tsr.net.cli")
      local result = cli.run({ ... }, out, node)
      return result, table.concat(out.said, " / "), table.concat(out.errs, " / ")
    end
    local r, text = run(a, "status")
    ok(r and text:find("alpha", 1, true) and text:find("peers:    0", 1, true), text)
    b:serve("files", function() end)
    r, text = run(a, "lookup")
    ok(r and text:find("beta", 1, true) and text:find("files", 1, true), text)
    r, text = run(a, "ping", "22")
    ok(r and text:find("beta: ", 1, true), text)
    r, text = run(a, "time", "22")
    ok(r and text:find("clock offset", 1, true), text)
    local bad, _, err = run(a, "ping", "99")
    ok(bad == false and err:find("no answer"), err)
    -- pair through the command line
    parallel.waitForAll(
      function() local pr, t = run(a, "pair", "listen") ok(pr, t) end,
      function()
        sleep(0.3)
        -- the listener printed its code to its output; we use the same generated code via the pairing state
        local code = a.pairing and a.pairing.code
        ok(code, "listener has a code")
        local pr, t, e = run(b, "pair", "11", code)
        ok(pr, e)
      end)
    r, text = run(a, "peers")
    ok(text:find("beta", 1, true), text)
    r = run(a, "unpair", "beta")
    ok(r)
    r, text = run(a, "peers")
    ok(text:find("Not paired", 1, true), text)
    local nm = run(a, "name", "bad name!")
    eq(nm, false)
    eq(run(a, "bogus"), false)
  end)
end)
