-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Cooperative yielding for long computations. CC's watchdog kills a program that runs for seconds without yielding, and
-- a cooperative scheduler needs the CPU back now and then: heavy loops call `maybe()` and it hands control back
-- at most once per `interval` seconds of CPU time.
local M = {}

M.interval = 1.5
local last = os.clock()

--- Yield to the scheduler if it has been a while. Safe to call anywhere a coroutine can yield.
function M.maybe()
  local now = os.clock()
  if now - last < M.interval and now >= last then return end
  last = now
  os.queueEvent("tsr_yield")
  os.pullEventRaw("tsr_yield")
  last = os.clock()
end

return M
