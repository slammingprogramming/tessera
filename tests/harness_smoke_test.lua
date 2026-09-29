-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Sanity checks for the harness itself and for the emulator assumptions the rest of the test-suite relies on.

test("harness runs and asserts work", function()
  eq(1 + 1, 2)
  eq({ a = 1, b = { 2, 3 } }, { a = 1, b = { 2, 3 } })
  throws(function() error("boom") end, "boom")
end)

test("CC environment is present", function()
  ok(fs and term and os.pullEvent and textutils, "CC APIs missing")
  ok(textutils.serializeJSON and textutils.unserializeJSON, "JSON helpers missing")
  ok(os.epoch, "os.epoch missing")
end)

test("filesystem round-trip", function()
  local p = "/tmp-harness/x.txt"
  local f = fs.open(p, "w")
  f.write("hello")
  f.close()
  local r = fs.open(p, "r")
  eq(r.readAll(), "hello")
  r.close()
  fs.delete("/tmp-harness")
end)

test("event queue works on the harness coroutine", function()
  os.queueEvent("tsr_test", 42)
  local ev, v = os.pullEvent("tsr_test")
  eq(ev, "tsr_test")
  eq(v, 42)
end)
