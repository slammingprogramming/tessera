-- SPDX-License-Identifier: AGPL-3.0-or-later
local net = require("tsr.net")
local webgw = require("tsr.webgw")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-webgw"

local function fresh()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  webgw.CFG_PATH = DIR .. "/cfg"
end

local function node(id, name, bus)
  return net.node({ id = id, hostname = name, transport = bus:transport(id), peersPath = DIR .. "/" .. name .. ".peers" })
end

test("ping and list", function()
  fresh()
  local bus = netbus.new()
  local n = node(11, "hub", bus)
  local cfg = { expose = { "metrics" } }
  local r = webgw.handle({ id = 1, op = "ping" }, n, cfg)
  eq({ r.id, r.ok, r.result.host }, { 1, true, "hub" })
  r = webgw.handle({ id = 2, op = "list" }, n, cfg)
  eq(r.result.expose, { "metrics" })
  r = webgw.handle({ id = 3, op = "dance" }, n, cfg)
  eq({ r.ok, r.error }, { false, "unknown op" })
end)

test("only exposed services can be called", function()
  fresh()
  local bus = netbus.new()
  local n = node(11, "hub", bus)
  n:serve("metrics", function(from, method, args) return { method = method, args = args, from = from } end)
  n:serve("secret", function() return "classified" end)
  local cfg = { expose = { "metrics" } }
  local r = webgw.handle({ id = 1, op = "call", service = "metrics", method = "get", args = { x = 1 } }, n, cfg)
  ok(r.ok, tostring(r.error))
  eq(r.result.method, "get")
  eq(r.result.args, { x = 1 })
  r = webgw.handle({ id = 2, op = "call", service = "secret", method = "get" }, n, cfg)
  eq({ r.ok, r.error }, { false, "service 'secret' is not exposed" })
  -- even when asking for "local" explicitly
  r = webgw.handle({ id = 3, op = "call", service = "secret", method = "get", target = "local" }, n, cfg)
  eq(r.ok, false)
  r = webgw.handle({ id = 4, op = "call", service = "metrics" }, n, cfg)
  ok(r.ok == false and r.error:find("required"))
  cfg.expose = { "ghost" }
  r = webgw.handle({ id = 5, op = "call", service = "ghost", method = "x" }, n, cfg)
  ok(r.ok == false and r.error:find("no such service"))
  -- handler errors become error replies
  n:serve("boom", function() error("it broke", 0) end)
  cfg.expose = { "boom" }
  r = webgw.handle({ id = 6, op = "call", service = "boom", method = "x" }, n, cfg)
  eq({ r.ok, r.error }, { false, "it broke" })
end)

test("calls can be forwarded to a paired peer", function()
  fresh()
  local bus = netbus.new()
  local hub, far = node(11, "hub", bus), node(22, "far", bus)
  local failure
  parallel.waitForAny(
    function() hub:run() end,
    function() far:run() end,
    function()
      local okRun, err = pcall(function()
        parallel.waitForAll(
          function() ok(far:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
          function() sleep(0.2) ok(hub:pairConnect(22, "ABCDE-FGHJK", 5)) end)
        far:serve("metrics", function() return { host = "far-metrics" } end)
        local cfg = { expose = { "metrics" } }
        local r = webgw.handle({ id = 1, op = "call", service = "metrics", method = "get", target = "far" }, hub, cfg)
        ok(r.ok, tostring(r.error))
        eq(r.result.host, "far-metrics")
        r = webgw.handle({ id = 2, op = "call", service = "metrics", method = "get", target = "stranger" }, hub, cfg)
        ok(r.ok == false and r.error:find("not paired"))
        eq(webgw.handle({ id = 3, op = "list" }, hub, cfg).result.peers, { "far" })
      end)
      if not okRun then failure = err end
    end)
  if failure then error(failure, 0) end
end)

test("a session answers JSON messages in order and survives garbage", function()
  fresh()
  local bus = netbus.new()
  local n = node(11, "hub", bus)
  n:serve("metrics", function() return { up = 1 } end)
  local cfg = { expose = { "metrics" } }
  local inbox = {
    textutils.serializeJSON({ id = 1, op = "ping" }),
    "this is not json",
    textutils.serializeJSON({ id = 2, op = "call", service = "metrics", method = "get" }),
  }
  local sent = {}
  local i = 0
  local ws = {
    receive = function() i = i + 1 return inbox[i] end,
    send = function(t) sent[#sent + 1] = textutils.unserializeJSON(t) end,
    close = function() end,
  }
  local result = webgw.session(ws, n, cfg, function() return i >= #inbox end)
  eq(result, "stopped")
  eq(#sent, 3)
  eq({ sent[1].id, sent[1].ok }, { 1, true })
  eq({ sent[2].ok, sent[2].error }, { false, "bad json" })
  eq({ sent[3].id, sent[3].ok, sent[3].result.up }, { 2, true, 1 })
end)

test("the daemon connects with credentials and reconnects", function()
  fresh()
  local bus = netbus.new()
  local n = node(11, "hub", bus)
  webgw.saveConfig({ url = "ws://gw.example:8080/ws", token = "0123456789abcdef", expose = { "metrics" } })
  local seen = {}
  local attempts = 0
  local connect = function(url, headers)
    attempts = attempts + 1
    seen[#seen + 1] = { url = url, headers = headers }
    if attempts == 1 then return false, "refused" end
    -- second attempt: a socket that raises when closed after one message
    local sent = false
    return {
      receive = function()
        if not sent then sent = true return textutils.serializeJSON({ id = 1, op = "ping" }) end
        error("websocket closed", 0)
      end,
      send = function(t) seen.reply = textutils.unserializeJSON(t) end,
      close = function() end,
    }
  end
  local realSleep = sleep
  local slept = {}
  _G.sleep = function(t) slept[#slept + 1] = t if #slept >= 3 then error("stop-test", 0) end end
  local okRun, err = pcall(webgw.run, n, connect)
  _G.sleep = realSleep
  eq(err, "stop-test")
  ok(attempts >= 2, "reconnected after the first failure")
  eq(seen[1].url, "ws://gw.example:8080/ws")
  eq(seen[1].headers.Authorization, "Bearer 0123456789abcdef")
  eq(seen[1].headers["X-Computer"], "hub")
  ok(seen.reply and seen.reply.ok)
  eq(slept[1], 5)
  ok(slept[2] >= slept[1], "backoff grows")
end)

test("the webgw command", function()
  fresh()
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = webgw.cli({ ... }, io)
    return r, table.concat(io.said, " / "), table.concat(io.errs, " / ")
  end
  local r, text = run("status")
  ok(r and text:find("not set up", 1, true), text)
  eq(run("setup", "http://wrong", "0123456789abcdef"), false)
  eq(run("setup", "ws://x/ws", "short"), false)
  ok(run("setup", "ws://gw:8080/ws", "0123456789abcdef"))
  eq(webgw.loadConfig().expose, { "metrics" })
  ok(run("expose", "metrics", "storage"))
  eq(webgw.loadConfig().expose, { "metrics", "storage" })
  r, text = run("status")
  ok(text:find("storage", 1, true))
  ok(run("setup", "ws://gw:8080/ws", "0123456789abcdef", "a", "b"))
  eq(webgw.loadConfig().expose, { "a", "b" })
  eq(run("nonsense"), false)
end)
