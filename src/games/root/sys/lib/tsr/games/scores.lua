-- SPDX-License-Identifier: AGPL-3.0-or-later
-- High scores, kept per game in /var/lib/tsr/games.json.
local vfs = require("tsr.vfs")

local M = {}

M.PATH = "/var/lib/tsr/games.json"

local function load() return vfs.readJSON(M.PATH) or {} end

function M.best(game) return load()[game] or 0 end

--- Record a score. Returns true when it is a new best.
function M.submit(game, score)
  local data = load()
  if score > (data[game] or 0) then
    data[game] = score
    vfs.writeJSON(M.PATH, data)
    return true
  end
  return false
end

return M
