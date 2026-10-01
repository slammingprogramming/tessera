-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Package source type "lan": read registry files from a paired computer that runs the pkg-mirror service.
--   { name = "lan-store", type = "lan", peer = "store" }
-- (The pkg module loads this file on demand when it meets a source of this type.)
local hash = require("tsr.hash")
local source = require("tsr.pkg.source")

local M = {}

--- Test hook: use another node than the shared one.
M.node = nil

local function node()
  return M.node or require("tsr.net").default()
end

source.fetchers.lan = {
  read = function(src, rel)
    local n = node()
    local parts, offset = {}, 0
    while true do
      local res, err = n:call(src.peer, "pkgmirror", "read", { rel = rel, offset = offset }, { timeout = src.timeout or 8 })
      if res == nil then return nil, tostring(err) end
      local chunk = hash.base64Decode(res.data) or ""
      parts[#parts + 1] = chunk
      offset = offset + #chunk
      if res.eof or #chunk == 0 then break end
    end
    return table.concat(parts)
  end,
}

return M
