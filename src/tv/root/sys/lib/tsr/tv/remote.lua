-- SPDX-License-Identifier: AGPL-3.0-or-later
-- TV remote control over the network.
--   On the TV computer:   the tvd service offers the "tv" service to paired computers
--   On a pocket computer: tvremote <tv name>      arrows, Enter = OK, Backspace = Back, Home; or tap the buttons
-- Pair first (`net pair`). Each button press is one signed message; the TV turns it into the event  tv_key(name).
local W = require("tsr.gui.widgets")
local theme = require("tsr.gui.theme")

local M = {}

M.KEYS = { up = true, down = true, left = true, right = true, ok = true, back = true, home = true }

--- Register the "tv" service on `node`.
function M.serve(node)
  node:serve("tv", function(_, method, a)
    if method == "key" and type(a) == "table" and M.KEYS[a.key] then
      os.queueEvent("tv_key", a.key)
      return true
    end
    error("unknown request", 0)
  end)
end

--- Send one button press. Returns true, or nil + reason.
function M.press(node, tv, key)
  if not M.KEYS[key] then return nil, "unknown key" end
  local res, err = node:call(tv, "tv", "key", { key = key }, { timeout = 2 })
  if res == nil then return nil, err end
  return true
end

local KEYCODE = { [keys.up] = "up", [keys.down] = "down", [keys.left] = "left", [keys.right] = "right", [keys.enter] = "ok",
                  [keys.backspace] = "back", [keys.home] = "home" }

--- The remote's screen. opts: term, pull (event source for tests), maxEvents. Returns when the user quits (Q) or after maxEvents.
function M.ui(node, tv, opts)
  opts = opts or {}
  local t = opts.term or term.current()
  theme.set("dark", t.isColor())
  local w, h = t.getSize()
  local root = W.root(t)
  local status = root:add(W.label({ x = 1, y = h, w = w, text = "Remote for " .. tostring(tv), role = "textDim" }))
  local function send(key)
    local ok, err = M.press(node, tv, key)
    status.text = ok and ("sent " .. key) or ("failed: " .. tostring(err))
  end
  local bw = math.max(5, math.floor(w / 3))
  local function button(x, y, text, key) root:add(W.button({ x = x, y = y, w = bw, text = text, onClick = function() send(key) end })) end
  local cx = math.floor((w - bw) / 2) + 1
  button(cx, 2, "Up", "up")
  button(cx - bw, 4, "Left", "left")
  button(cx, 4, "OK", "ok")
  button(cx + bw, 4, "Right", "right")
  button(cx, 6, "Down", "down")
  button(cx - bw, 8, "Back", "back")
  button(cx + bw, 8, "Home", "home")
  root:render()
  local pull = opts.pull or function() return os.pullEvent() end
  local count = 0
  while true do
    local ev, a, b, c = pull()
    if ev == "key" and KEYCODE[a] and not (root.focused and root.focused.cursorPos) then
      send(KEYCODE[a])
    elseif ev == "char" and a == "q" then
      break
    elseif ev == "mouse_click" or ev == "mouse_up" or ev == "mouse_drag" or ev == "mouse_scroll" or ev == "key" or ev == "key_up" then
      root:dispatch(ev, a, b, c)
    end
    root:render()
    count = count + 1
    if opts.maxEvents and count >= opts.maxEvents then break end
  end
end

function M.main(args)
  if not args[1] then print("usage: tvremote <tv name>   (Q quits)") return false end
  local node = require("tsr.net").default()
  M.ui(node, tonumber(args[1]) or args[1], {})
  term.setBackgroundColor(colors.black) term.clear() term.setCursorPos(1, 1)
  return true
end

--- The tvd service (on the TV).
function M.daemon()
  M.serve(require("tsr.net").default())
  while true do os.pullEvent("tvd_never") end
end

return M
