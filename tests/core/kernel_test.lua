-- SPDX-License-Identifier: AGPL-3.0-or-later
local K = require("tsr.kernel")
local log = require("tsr.log")

local function flush()
  os.queueEvent("tsr_flush")
  repeat local e = os.pullEventRaw() until e == "tsr_flush"
end

local function setup()
  K.reset()
  flush()
  local root = window.create(term.current(), 1, 1, 20, 5, false)
  K.init({ term = root })
  return root
end

test("a process runs to completion and the loop exits", function()
  setup()
  local ran = false
  K.spawn({ name = "p", fn = function() ran = true end })
  ok(ran, "spawn should run the process up to its first yield")
  eq(K.run(), "craftos")
  eq(#K.list(), 0)
end)

test("events are broadcast to processes with matching filters", function()
  setup()
  local got = { a = {}, b = {} }
  K.spawn({ name = "a", fn = function()
    local e, v = os.pullEvent("ping")
    got.a[#got.a + 1] = v
  end })
  K.spawn({ name = "b", fn = function()
    local e, v = os.pullEvent("pong")
    got.b[#got.b + 1] = v
  end })
  os.queueEvent("ping", 1)
  os.queueEvent("pong", 2)
  K.run()
  eq(got, { a = { 1 }, b = { 2 } })
end)

test("input goes only to the focused process", function()
  setup()
  local got = { a = 0, b = 0 }
  K.spawn({ name = "a", fn = function() os.pullEvent("char") got.a = got.a + 1 end })
  local pb = K.spawn({ name = "b", focus = true, fn = function() os.pullEvent("char") got.b = got.b + 1 end })
  eq(K.getFocus(), pb)
  os.queueEvent("char", "x")
  os.queueEvent("tsr_stop_now")
  K.spawn({ name = "closer", window = false, fn = function() os.pullEvent("tsr_stop_now") K.stop() end })
  K.run()
  eq(got, { a = 0, b = 1 })
end)

test("terminate always reaches the focused process, whatever its filter", function()
  setup()
  local status
  K.spawn({ name = "t", focus = true, fn = function()
    local ok, err = pcall(os.pullEvent, "never_happens") -- os.pullEvent turns terminate into an error
    status = { ok = ok, err = err }
  end })
  os.queueEvent("terminate")
  K.run()
  eq(status.ok, false)
  eq(status.err, "Terminated")
end)

test("crashes are logged, reported via tsr_proc_exit and do not stop others", function()
  setup()
  log.clear()
  local exitInfo
  local survivor = false
  K.spawn({ name = "watcher", window = false, fn = function()
    local _, pid, ok, err = os.pullEvent("tsr_proc_exit")
    exitInfo = { ok = ok, err = tostring(err):match("boom") }
    os.pullEvent("late")
    survivor = true
  end })
  K.spawn({ name = "crasher", fn = function() error("boom") end })
  os.queueEvent("late")
  K.run()
  eq(exitInfo, { ok = false, err = "boom" })
  ok(survivor)
  local found = false
  for _, l in ipairs(log.tail()) do if l:find("crashed") and l:find("boom") then found = true end end
  ok(found, "crash should be logged")
end)

test("process output lands in its own window, not the root terminal", function()
  local root = setup()
  K.spawn({ name = "writer", focus = true, fn = function()
    term.setCursorPos(1, 1)
    term.write("hello")
    os.pullEvent("never")
  end })
  local line = root.getLine(1)
  ok(line:find("hello", 1, true), "root should show the focused window's content: " .. line)
  K.stop() -- a pending stop makes run() return right after starting
  K.run()
end)

test("focus switches with Alt+number and restores on exit", function()
  setup()
  local p1 = K.spawn({ name = "s1", session = true, focus = true, fn = function() os.pullEvent("never") end })
  local p2 = K.spawn({ name = "s2", session = true, fn = function() os.pullEvent("never") end })
  eq(K.getFocus(), p1)
  os.queueEvent("key", keys.leftAlt, false)
  os.queueEvent("key", keys.two, false)
  os.queueEvent("key_up", keys.two)
  os.queueEvent("key_up", keys.leftAlt)
  os.queueEvent("tsr_check")
  K.spawn({ name = "checker", window = false, fn = function()
    os.pullEvent("tsr_check")
    eq(K.getFocus(), p2)
    K.kill(p2)
    eq(K.getFocus(), p1)
    K.stop()
  end })
  K.run()
end)

test("custom hotkeys fire and consume the key", function()
  setup()
  local fired, seen = 0, false
  K.hotkey("ctrl+q", function() fired = fired + 1 end)
  K.spawn({ name = "p", focus = true, fn = function()
    while true do
      local e, k = os.pullEvent("key")
      if k == keys.q then seen = true end
    end
  end })
  os.queueEvent("key", keys.leftCtrl, false)
  os.queueEvent("key", keys.q, false)
  os.queueEvent("tsr_end")
  K.spawn({ name = "end", window = false, fn = function() os.pullEvent("tsr_end") K.stop() end })
  K.run()
  eq(fired, 1)
  ok(not seen, "hotkey must be consumed")
end)

test("stop() runs hooks, kills processes, returns the action", function()
  setup()
  local hooked = false
  K.onStop(function() hooked = true end)
  K.spawn({ name = "forever", fn = function() while true do os.pullEvent() end end })
  K.spawn({ name = "stopper", window = false, fn = function() K.stop("reboot") end })
  eq(K.run(), "reboot")
  ok(hooked)
  eq(#K.list(), 0)
end)

test("wait() returns the exit status of another process", function()
  setup()
  local result
  local child = K.spawn({ name = "child", fn = function() os.pullEvent("go") error("failed") end })
  K.spawn({ name = "parent", window = false, fn = function()
    local ok, err = K.wait(child)
    result = { ok = ok, has = tostring(err):find("failed") ~= nil }
  end })
  os.queueEvent("go")
  K.run()
  eq(result, { ok = false, has = true })
end)

test("path programs load with the shared require", function()
  setup()
  fs.makeDir("/tmp-k")
  local h = fs.open("/tmp-k/prog.lua", "w")
  h.write("local util = require('tsr.util')\nRESULT_MARK = util.trim('  ok  ')\nreturn true")
  h.close()
  local pid, proc = K.spawn({ name = "prog", path = "/tmp-k/prog.lua", window = false })
  ok(pid, "spawn failed")
  ok(rawget(_G, "RESULT_MARK") == nil, "program globals must not leak into _G")
  K.run()
  fs.delete("/tmp-k")
  local nopid, err = K.spawn({ name = "bad", path = "/nonexistent.lua" })
  ok(nopid == nil and err)
end)

test("kill removes a process at once", function()
  setup()
  local pid = K.spawn({ name = "victim", fn = function() while true do os.pullEvent() end end })
  eq(#K.list(), 1)
  K.kill(pid)
  eq(#K.list(), 0)
end)
