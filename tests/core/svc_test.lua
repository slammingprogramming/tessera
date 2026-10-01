-- SPDX-License-Identifier: AGPL-3.0-or-later
local K = require("tsr.kernel")
local svc = require("tsr.svc")

local DIR = "/tmp-svc"

local function flush()
  os.queueEvent("tsr_flush")
  repeat local e = os.pullEventRaw() until e == "tsr_flush"
end

local function setup()
  K.reset()
  flush()
  if fs.exists(DIR) then fs.delete(DIR) end
  svc.reset()
  svc.dir = DIR .. "/defs"
  svc.statePath = DIR .. "/state"
  K.init({ term = window.create(term.current(), 1, 1, 20, 5, false) })
end

local function forever() while true do os.pullEvent("svc_test_never") end end

test("definitions are validated", function()
  setup()
  ok(not svc.define({ name = "bad name!", run = forever }))
  ok(not svc.define({ name = "x" }))
  ok(not svc.define({ name = "x", run = forever, restart = "sometimes" }))
  ok(svc.define({ name = "x", run = forever }))
end)

test("start and stop a service", function()
  setup()
  svc.define({ name = "a", run = forever, description = "service a" })
  ok(svc.start("a"))
  local st = svc.status("a")
  eq(st.state, "running")
  ok(st.pid and K.get(st.pid))
  ok(svc.start("a"), "starting twice is fine")
  eq(#K.list(), 1)
  ok(svc.stop("a"))
  eq(svc.status("a").state, "stopped")
  eq(#K.list(), 0)
  local bad, err = svc.start("nope")
  ok(bad == nil and err:find("no such"))
end)

test("a service that ignores terminate is killed", function()
  setup()
  svc.define({ name = "stubborn", run = function()
    while true do
      local ok = pcall(os.pullEventRaw)
    end
  end })
  svc.start("stubborn")
  svc.stop("stubborn")
  eq(#K.list(), 0)
end)

test("dependencies start first and stop last", function()
  setup()
  local order = {}
  local function mk(name, requires)
    svc.define({ name = name, requires = requires, run = function() order[#order + 1] = name forever() end })
  end
  mk("net", nil)
  mk("web", { "net" })
  mk("bot", { "web" })
  svc.start("bot")
  eq(order, { "net", "web", "bot" })
  -- stopping a dependency stops what needs it
  svc.stop("net")
  eq(svc.status("web").state, "stopped")
  eq(svc.status("bot").state, "stopped")
  -- loops and unknown requirements are reported
  svc.define({ name = "l1", requires = { "l2" }, run = forever })
  svc.define({ name = "l2", requires = { "l1" }, run = forever })
  local r, err = svc.start("l1")
  ok(r == nil and err:find("loop"), err)
  svc.define({ name = "orphan", requires = { "ghost" }, run = forever })
  r, err = svc.start("orphan")
  ok(r == nil and err:find("ghost"), err)
end)

test("path and module services run", function()
  setup()
  fs.makeDir(DIR)
  local h = fs.open(DIR .. "/prog.lua", "w")
  h.write([[ fs.open("/tmp-svc/ran", "w").close() while true do os.pullEvent("svc_test_never") end ]])
  h.close()
  svc.define({ name = "p", path = DIR .. "/prog.lua" })
  ok(svc.start("p"))
  ok(fs.exists(DIR .. "/ran"))
  svc.define({ name = "bad", path = DIR .. "/missing.lua" })
  local r, err = svc.start("bad")
  ok(r == nil)
  eq(svc.status("bad").state, "failed")
end)

test("failures are restarted with backoff and eventually given up on", function()
  setup()
  local clock = 0
  svc.setClock(function() return clock end)
  svc.define({ name = "f", run = function() error("kaput", 0) end, max_restarts = 3, window = 60 })
  svc.start("f")
  local rec = svc.get("f")
  svc.onExit(rec.pid, false, "kaput")
  eq(svc.status("f").state, "backoff")
  eq(svc.status("f").restarts, 1)
  eq(rec.failures, 1)
  svc.onTimer(rec.backoffTimer)          -- restarts (and dies again at once)
  ok(rec.pid, "restarted")
  svc.onExit(rec.pid, false, "kaput")
  eq(svc.status("f").state, "backoff")
  eq(rec.failures, 2)
  svc.onTimer(rec.backoffTimer)
  svc.onExit(rec.pid, false, "kaput")    -- third start inside the window: give up
  eq(svc.status("f").state, "failed")
  ok(rec.failedPermanently)
  eq(svc.status("f").lastError, "kaput")
  -- a manual start clears the failure
  svc.setClock(function() return 1000 end)
  svc.define({ name = "g", run = forever })
  svc.setClock(function() return os.epoch and os.epoch("utc") / 1000 or os.clock() end)
end)

test("restart policies", function()
  setup()
  svc.define({ name = "never", run = function() error("x", 0) end, restart = "never" })
  svc.start("never")
  svc.onExit(svc.get("never").pid, false, "x")
  eq(svc.status("never").state, "failed")

  svc.define({ name = "clean", run = function() end })    -- on-failure: a clean exit stays stopped
  svc.start("clean")
  svc.onExit(svc.get("clean").pid, true)
  eq(svc.status("clean").state, "stopped")

  svc.define({ name = "always", run = function() end, restart = "always" })
  svc.start("always")
  svc.onExit(svc.get("always").pid, true)
  eq(svc.status("always").state, "backoff")

  -- an explicit stop is never undone by the supervisor
  svc.define({ name = "wanted", run = forever, restart = "always" })
  svc.start("wanted")
  local pid = svc.get("wanted").pid
  svc.stop("wanted")
  svc.onExit(pid, false, "killed")
  eq(svc.status("wanted").state, "stopped")
end)

test("enable and disable persist and drive autostart, respecting profiles", function()
  setup()
  local started = {}
  local function mk(name, extra)
    local def = { name = name, run = function() started[#started + 1] = name forever() end }
    for k, v in pairs(extra or {}) do def[k] = v end
    svc.define(def)
  end
  mk("boot", { autostart = true })
  mk("manual", {})
  mk("optout", { autostart = true })
  mk("elsewhere", { autostart = true, profiles = { "no-such-profile" } })
  svc.disable("optout")
  svc.enable("manual")
  eq(svc.enabled("boot"), true)
  eq(svc.enabled("manual"), true)
  eq(svc.enabled("optout"), false)
  local names = svc.autostart()
  table.sort(names)
  eq(names, { "boot", "manual" })
  local bad, err = svc.enable("ghost")
  ok(bad == nil)
  -- persisted
  ok(fs.exists(DIR .. "/state"))
  svc.reset()
  svc.define({ name = "manual", run = forever })
  eq(svc.enabled("manual"), true)
end)

test("definition files are loaded and bad ones reported", function()
  setup()
  fs.makeDir(DIR .. "/defs")
  local function put(name, text)
    local h = fs.open(DIR .. "/defs/" .. name, "w")
    h.write(text)
    h.close()
  end
  put("good.lua", [[return { description = "fine", run = function() end, autostart = true }]])
  put("named.lua", [[return { name = "other", run = function() end }]])
  put("broken.lua", [[return { run = ]])
  put("noaction.lua", [[return { description = "nothing to run" }]])
  put("ignored.txt", "x")
  local n, problems = svc.load()
  eq(n, 2)
  eq(#problems, 2)
  eq(svc.names(), { "good", "other" })
  eq(svc.status("good").description, "fine")
  eq(svc.status("good").enabled, true)
end)

test("the supervisor restarts a service that crashes", function()
  setup()
  local runs, seen = 0, nil
  svc.define({ name = "flaky", autostart = true, run = function()
    runs = runs + 1
    if runs == 1 then error("first run fails", 0) end
    forever()
  end })
  K.spawn({ name = "supervisor", window = false, fn = function() svc.supervise() end })
  K.spawn({ name = "judge", window = false, fn = function()
    sleep(2)
    seen = svc.status("flaky")
    K.stop("craftos")
  end })
  K.run()
  eq(runs, 2)
  eq(seen.state, "running")
  eq(seen.restarts, 1)
end)
