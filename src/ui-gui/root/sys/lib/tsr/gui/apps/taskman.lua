-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Task manager: running processes and services, with "End task".
local W = require("tsr.gui.widgets")

local M = {}

function M.rows(kernel)
  local rows = {}
  for _, p in ipairs(kernel.list()) do
    rows[#rows + 1] = { pid = p.pid, name = p.name, session = p.session, focused = p.focused }
  end
  return rows
end

--- opts: kernel (for tests)
function M.build(root, win, desktop, opts)
  opts = opts or {}
  local kernel = opts.kernel or require("tsr.kernel")
  local list = root:add(W.list({ x = 1, y = 1, w = root.w, h = root.h - 3 }))
  local status = root:add(W.label({ x = 1, y = root.h - 1, w = root.w, text = "", role = "textDim" }))
  local me = kernel.current and kernel.current()

  local function refresh()
    local items = {}
    for i, r in ipairs(M.rows(kernel)) do
      items[i] = { text = ("%3d  %-22s%s"):format(r.pid, r.name, r.session and "  session" or ""), pid = r.pid, name = r.name }
    end
    list:setItems(items, true)
    status.text = #items .. " processes"
  end

  local x = 1
  local endBtn = root:add(W.button({ x = x, y = root.h, text = "End task", onClick = function()
    local item = list:selectedItem()
    if not item then return end
    if item.pid == me then status.text = "The desktop cannot end itself (use the start menu)." return end
    kernel.terminate(item.pid)
    if kernel.get(item.pid) then kernel.kill(item.pid) end
    refresh()
  end }))
  root:add(W.button({ x = endBtn.w + 2, y = root.h, text = "Refresh", onClick = refresh }))
  refresh()
  list:focus()
  -- processes come and go: the desktop loop calls this about once a second while the window is open
  win.onTick = refresh
  return { list = list, refresh = refresh, status = status }
end

return M
