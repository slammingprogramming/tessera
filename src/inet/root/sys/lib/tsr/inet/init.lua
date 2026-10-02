-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Entry point of the network stack package:
--   local inet = require("tsr.inet")
--   inet.stack()      -- the running stack (error with a hint if inetd is not running)
--   inet.running()    -- true | false
--   inet.socket       -- tsr.inet.socket
-- The stack itself is started by the inetd service (tsr.inet.daemon).
local socket = require("tsr.inet.socket")

local M = { socket = socket }

function M.running()
  local ok = pcall(socket.default)
  return ok
end

function M.stack() return socket.default() end

return M
