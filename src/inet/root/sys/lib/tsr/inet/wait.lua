-- SPDX-License-Identifier: AGPL-3.0-or-later
-- How a blocking socket call waits. stack.wait(cond, timeout) returns true as soon as cond() is true and false when the timeout passes.
-- The default version sleeps on ComputerCraft events; tests replace it with one that advances a simulated clock instead.
local M = {}

function M.block(stack, cond, timeout)
  local deadline = timeout and (stack.clock() + timeout) or math.huge
  while true do
    if cond() then return true end
    if not stack.daemon then stack:tick() end
    local remaining = deadline - stack.clock()
    if remaining <= 0 then return cond() end
    local timer = os.startTimer(math.min(remaining, 0.25))
    local ev, id = os.pullEvent()
    if ev ~= "timer" or id ~= timer then os.cancelTimer(timer) end
  end
end

return M
