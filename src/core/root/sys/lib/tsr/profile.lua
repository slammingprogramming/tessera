-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Device profile detection. A profile is chosen from what the computer physically is; the user may override it with
-- config key `system.profile` (e.g. "server", "tv", "node"). Colour vs. monochrome is NOT a profile: it is a runtime
-- capability (see M.capabilities) so one code base serves both.
local config = require("tsr.config")

local M = {}

M.KNOWN = { "client-lite", "client", "server", "turtle", "pocket", "tv", "node", "command" }

--- What the hardware alone suggests.
function M.detect()
  if rawget(_G, "turtle") then return "turtle" end
  if rawget(_G, "pocket") then return "pocket" end
  if rawget(_G, "commands") then return "command" end
  if term.isColor() then return "client" end
  return "client-lite"
end

--- The active profile: user override if valid, otherwise detected.
function M.get()
  local override = config.get("system.profile")
  if override then
    for _, p in ipairs(M.KNOWN) do
      if p == override then return override end
    end
  end
  return M.detect()
end

--- Runtime capability flags used by UI and driver selection.
function M.capabilities()
  local w, h = term.getSize()
  return {
    color = term.isColor(),
    mouse = term.isColor(),
    width = w,
    height = h,
    turtle = rawget(_G, "turtle") ~= nil,
    pocket = rawget(_G, "pocket") ~= nil,
    commands = rawget(_G, "commands") ~= nil,
    http = rawget(_G, "http") ~= nil,
  }
end

return M
