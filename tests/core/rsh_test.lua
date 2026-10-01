-- SPDX-License-Identifier: AGPL-3.0-or-later
local net = require("tsr.net")
local rsh = require("tsr.rsh")
local K = require("tsr.kernel")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-rsh"

local function setupNodes()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  rsh.ALLOW_PATH = DIR .. "/allow"
  local bus = netbus.new()
  local server = net.node({ id = 11, hostname = "alpha", transport = bus:transport(11), peersPath = DIR .. "/a.peers" })
  local client = net.node({ id = 22, hostname = "beta", transport = bus:transport(22), peersPath = DIR .. "/b.peers" })
  return server, client
end

local function pair(server, client)
  parallel.waitForAll(
    function() ok(server:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
    function() sleep(0.2) ok(client:pairConnect(11, "ABCDE-FGHJK", 5)) end)
end

local function cli(client, ...)
  local io = { said = {}, errs = {}, out = {} }
  function io.say(t) io.said[#io.said + 1] = t end
  function io.err(t) io.errs[#io.errs + 1] = t end
  function io.write(t) io.out[#io.out + 1] = t end
  local result = rsh.run({ ... }, io, client)
  return result, table.concat(io.out), table.concat(io.said, " / "), table.concat(io.errs, " / ")
end

local function withPair(fn)
  local server, client = setupNodes()
  rsh.reset()
  local failure
  parallel.waitForAny(
    function() server:run() end,
    function() client:run() end,
    function()
      local okRun, err = pcall(function()
        pair(server, client)
        rsh.serve(server)
        fn(server, client)
      end)
      if not okRun then failure = err end
    end)
  if failure then error(failure, 0) end
end

test("nobody may run commands until allowed", function()
  withPair(function(server, client)
    local r, out, _, err = cli(client, "alpha", "echo", "hi")
    ok(r == false and err:find("not allowed"), err)
    -- allowing is done on the server
    local sr, _, said = cli(server, "allow", "beta")
    ok(sr, said)
    eq(rsh.allowed(), { "beta" })
    r, out = cli(client, "alpha", "echo", "hi")
    ok(r)
    ok(out:find("hi", 1, true), out)
    cli(server, "deny", "beta")
    r, _, _, err = cli(client, "alpha", "echo", "again")
    ok(r == false and err:find("not allowed"))
    local _, _, listing = cli(server, "allowed")
    ok(listing:find("Nobody", 1, true), listing)
  end)
end)

test("commands keep their shell state per remote computer", function()
  withPair(function(server, client)
    cli(server, "allow", "beta")
    fs.makeDir(DIR .. "/work")
    local r, out = cli(client, "alpha", "cd", DIR .. "/work")
    ok(r)
    r, out = cli(client, "alpha", "pwd")
    ok(out:find(DIR .. "/work", 1, true), out)
    cli(client, "alpha", "GREETING=hello")
    r, out = cli(client, "alpha", "echo", "$GREETING")
    ok(out:find("hello", 1, true), out)
    -- pipes work remotely
    r, out = cli(client, "alpha", "echo abc | echo")
    ok(r)
    -- failures come back as a status
    r = cli(client, "alpha", "false")
    eq(r, false)
    r, _, _, _ = cli(client, "alpha", "nosuchcommand")
    eq(r, false)
  end)
end)

test("an interactive session prompts with the remote directory", function()
  withPair(function(server, client)
    cli(server, "allow", "beta")
    local lines = { "echo from-remote", "", "pwd", "exit" }
    local i = 0
    local io = { said = {}, errs = {}, out = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    function io.write(t) io.out[#io.out + 1] = t end
    function io.readLine() i = i + 1 return lines[i] end
    ok(rsh.run({ "alpha" }, io, client))
    local text = table.concat(io.out)
    ok(text:find("alpha:/> ", 1, true), text)
    ok(text:find("from-remote", 1, true), text)
    ok(io.said[1]:find("Connected to alpha", 1, true))
  end)
end)

test("huge output is truncated", function()
  withPair(function(server, client)
    cli(server, "allow", "beta")
    local h = fs.open(DIR .. "/big.lua", "w")
    h.write([[ for i = 1, 3000 do print(string.rep("x", 40)) end ]])
    h.close()
    local res = rsh.exec(client, "alpha", "/" .. DIR .. "/big.lua")
    ok(res)
    eq(res.truncated, true)
    eq(#res.output, rsh.MAX_OUTPUT)
  end)
end)

test("under the kernel a stuck command is stopped by the time limit", function()
  K.reset()
  local server, client = setupNodes()
  local result = {}
  K.init({ term = window.create(term.current(), 1, 1, 30, 10, false) })
  K.spawn({ name = "serverd", window = false, daemon = true, fn = function() server:run() end })
  K.spawn({ name = "clientd", window = false, daemon = true, fn = function() client:run() end })
  K.spawn({ name = "test", window = false, fn = function()
    local okRun, err = pcall(function()
      pair(server, client)
      rsh.serve(server)
      cli(server, "allow", "beta")
      -- a program that waits for a key that never comes
      local h = fs.open(DIR .. "/stuck.lua", "w")
      h.write([[ print("before") os.pullEvent("never_comes") print("after") ]])
      h.close()
      local res, e = rsh.exec(client, "alpha", "/" .. DIR .. "/stuck.lua", { timeout = 1 })
      result.stuck = res
      result.stuckErr = e
      -- the server is still alive afterwards
      local res2 = rsh.exec(client, "alpha", "echo alive")
      result.alive = res2
    end)
    result.err = (not okRun) and err or nil
    K.stop("craftos")
  end })
  K.run()
  eq(result.err, nil)
  ok(result.stuck, tostring(result.stuckErr))
  eq(result.stuck.timedOut, true)
  ok(result.stuck.output:find("before", 1, true))
  ok(not result.stuck.output:find("after", 1, true))
  ok(result.alive and result.alive.output:find("alive", 1, true))
end)
