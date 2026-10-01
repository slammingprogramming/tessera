-- SPDX-License-Identifier: AGPL-3.0-or-later
local net = require("tsr.net")
local rscreen = require("tsr.rscreen")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-rscreen"

local function setup()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  rscreen.ALLOW_PATH = DIR .. "/allow"
  rscreen.forget()
  local bus = netbus.new()
  local server = net.node({ id = 11, hostname = "alpha", transport = bus:transport(11), peersPath = DIR .. "/a.peers" })
  local client = net.node({ id = 22, hostname = "beta", transport = bus:transport(22), peersPath = DIR .. "/b.peers" })
  return server, client
end

local function withPair(fn)
  local server, client = setup()
  local failure
  parallel.waitForAny(
    function() server:run() end,
    function() client:run() end,
    function()
      local okRun, err = pcall(function()
        parallel.waitForAll(
          function() ok(server:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
          function() sleep(0.2) ok(client:pairConnect(11, "ABCDE-FGHJK", 5)) end)
        rscreen.serve(server)
        fn(server, client)
      end)
      if not okRun then failure = err end
    end)
  rscreen.source = nil
  rscreen.deliver = function(...) os.queueEvent(...) end
  if failure then error(failure, 0) end
end

local function newWindow(w, h)
  return window.create(term.current(), 1, 1, w or 20, h or 5, false)
end

local function lineText(win, y) return (win.getLine(y)) end

test("snapshots and diffs only carry what changed", function()
  rscreen.forget()
  local win = newWindow(10, 3)
  win.setCursorPos(1, 1) win.write("hello")
  win.setCursorPos(3, 3) win.write("x")
  local s1 = rscreen.snapshot(win)
  eq({ s1.w, s1.h }, { 10, 3 })
  local d1 = rscreen.diff(5, s1, false)
  eq(d1.changed, 3, "first frame is complete")
  local d2 = rscreen.diff(5, rscreen.snapshot(win), false)
  eq(d2.changed, 0)
  win.setCursorPos(1, 2) win.write("new")
  local d3 = rscreen.diff(5, rscreen.snapshot(win), false)
  eq(d3.changed, 1)
  ok(d3.lines[2] and d3.lines[2][1]:sub(1, 3) == "new")
  eq(rscreen.diff(5, rscreen.snapshot(win), true).changed, 3, "a full frame on request")
  -- a different peer has its own history
  eq(rscreen.diff(6, rscreen.snapshot(win), false).changed, 3)
  -- colours count as changes too
  win.setCursorPos(1, 1) win.setTextColor(colors.red) win.write("h")
  eq(rscreen.diff(5, rscreen.snapshot(win), false).changed, 1)
end)

test("rendering reproduces the remote screen", function()
  local remote = newWindow(12, 4)
  remote.setCursorPos(2, 2)
  remote.setBackgroundColor(colors.blue)
  remote.write("blue")
  remote.setCursorPos(5, 4)
  local local_ = newWindow(12, 4)
  local state = rscreen.render(local_, rscreen.diff(1, rscreen.snapshot(remote), true), nil)
  for y = 1, 4 do
    eq({ local_.getLine(y) }, { remote.getLine(y) })
  end
  eq({ local_.getCursorPos() }, { 5, 4 })
  -- an incremental frame only touches the changed line but the picture stays whole
  remote.setCursorPos(1, 1) remote.setBackgroundColor(colors.black) remote.write("top")
  rscreen.render(local_, rscreen.diff(1, rscreen.snapshot(remote), false), state)
  eq(lineText(local_, 1):sub(1, 3), "top")
  eq(lineText(local_, 2), lineText(remote, 2))
  -- a smaller local screen clips instead of failing
  local small = newWindow(6, 2)
  rscreen.render(small, rscreen.diff(2, rscreen.snapshot(remote), true), nil)
  eq(lineText(small, 1):sub(1, 3), "top")
end)

test("only allowed peers can watch", function()
  withPair(function(server, client)
    local shared = newWindow(10, 3)
    shared.setCursorPos(1, 1) shared.write("secret")
    rscreen.source = function() return shared end
    local frame, err = rscreen.fetch(client, "alpha", true)
    ok(frame == nil and tostring(err):find("not allowed"), tostring(err))
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    ok(rscreen.run({ "allow", "beta" }, io, server))
    frame, err = rscreen.fetch(client, "alpha", true)
    ok(frame, tostring(err))
    eq(frame.w, 10)
    ok(frame.lines[1][1]:sub(1, 6) == "secret")
    ok(rscreen.run({ "deny", "beta" }, io, server))
    frame = rscreen.fetch(client, "alpha", true)
    eq(frame, nil)
  end)
end)

test("input is validated and delivered", function()
  withPair(function(server, client)
    rscreen.run({ "allow", "beta" }, { say = function() end, err = function() end }, server)
    local got = {}
    rscreen.deliver = function(...) got[#got + 1] = table.pack(...) end
    local n = rscreen.sendInput(client, "alpha", {
      { "char", "a" }, { "key", 28, false }, { "mouse_click", 1, 5, 6 },
      { "terminate" },                -- not allowed
      { "os_command", "rm" },         -- not allowed
      { "char", { 1 } },              -- wrong argument type
      { "paste", "pasted text" },
    })
    eq(n, 4)
    eq(#got, 4)
    eq({ got[1][1], got[1][2] }, { "char", "a" })
    eq({ got[3][1], got[3][2], got[3][3], got[3][4] }, { "mouse_click", 1, 5, 6 })
    -- a flood is capped
    got = {}
    local many = {}
    for i = 1, 100 do many[i] = { "char", "x" } end
    eq(rscreen.sendInput(client, "alpha", many), rscreen.MAX_EVENTS)
    -- malformed requests fail cleanly
    local r, e = client:call("alpha", "screen", "input", { events = "nope" })
    ok(r == nil and e:find("bad request"))
  end)
end)

test("the viewer shows frames and forwards keys, F12 leaves", function()
  withPair(function(server, client)
    rscreen.run({ "allow", "beta" }, { say = function() end, err = function() end }, server)
    local shared = newWindow(10, 3)
    shared.setCursorPos(1, 1) shared.write("one")
    rscreen.source = function() return shared end
    local delivered = {}
    rscreen.deliver = function(...) delivered[#delivered + 1] = table.pack(...) end
    local view = newWindow(10, 3)
    local result
    parallel.waitForAll(
      function() result = { rscreen.view(client, "alpha", { term = view }) } end,
      function()
        sleep(0.1)
        eq(lineText(view, 1):sub(1, 3), "one")
        shared.setCursorPos(1, 1) shared.write("two")
        os.queueEvent("char", "z")
        sleep(rscreen.POLL + 0.6)
        eq(lineText(view, 1):sub(1, 3), "two")
        ok(#delivered >= 1 and delivered[1][1] == "char" and delivered[1][2] == "z")
        os.queueEvent("key", keys.f12)
      end)
    ok(result[1], tostring(result[2]))
  end)
end)

test("the viewer reports when the other side refuses", function()
  withPair(function(server, client)
    local ok1, err = rscreen.view(client, "alpha", { term = newWindow() })
    ok(ok1 == nil and tostring(err):find("not allowed"), tostring(err))
  end)
end)
