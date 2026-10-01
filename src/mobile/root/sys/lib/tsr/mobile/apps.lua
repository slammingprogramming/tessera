-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Screens of the built-in phone apps. Each builder is function(root, phone, env): it fills `root` (the content area).
-- `env` is optional and lets tests replace network, gps and configuration.
local W = require("tsr.gui.widgets")
local theme = require("tsr.gui.theme")

local M = {}

---------------------------------------------------------------------------------------------------------------------
-- Notifications
---------------------------------------------------------------------------------------------------------------------

function M.notifications(root, phone, env)
  env = env or {}
  local notify = env.notify or phone.notify
  local items = {}
  for i, n in ipairs(notify.list()) do
    items[i] = { text = ((n.level == "error" and "!! ") or (n.level == "warn" and "!  ") or "   ") .. n.time .. " " .. n.title, n = n }
  end
  if #items == 0 then
    root:add(W.label({ x = 1, y = 2, w = root.w, text = "No notifications", align = "center", role = "textDim" }))
  else
    local list = root:add(W.list({ x = 1, y = 1, w = root.w, h = root.h - 5, items = items }))
    local detail = root:add(W.label({ x = 1, y = root.h - 3, w = root.w, h = 3, wrap = true, text = items[1].n.text }))
    list.onSelect = function(_, item) detail.text = item.n.text end
    root:add(W.button({ x = 1, y = root.h - 4, w = root.w, text = "Clear all", onClick = function()
      notify.clear()
      phone:show(phone:current())
    end }))
    list:focus()
  end
  notify.markRead()
end

---------------------------------------------------------------------------------------------------------------------
-- Messages between computers (needs the net package and a paired computer running the "msg" service)
---------------------------------------------------------------------------------------------------------------------

M.MESSAGE_LOG = "/var/lib/tsr/messages.json"

--- Register the "msg" service: incoming messages become notifications and are kept in the message log.
function M.serveMessages(node, env)
  env = env or {}
  local vfs = require("tsr.vfs")
  node:serve("msg", function(from, method, a)
    if method ~= "post" or type(a) ~= "table" or type(a.text) ~= "string" then error("bad message", 0) end
    local peer = node:peer(from)
    local name = peer and peer.name or tostring(from)
    local log = vfs.readJSON(env.logPath or M.MESSAGE_LOG) or {}
    log[#log + 1] = { from = name, text = a.text:sub(1, 200), time = textutils.formatTime(os.time("local"), true), mine = false }
    while #log > 100 do table.remove(log, 1) end
    vfs.writeJSON(env.logPath or M.MESSAGE_LOG, log)
    local okN, notify = pcall(require, "tsr.notify")
    if okN then notify.push("Message from " .. name, a.text:sub(1, 120), { source = "msg" }) end
    return true
  end)
end

function M.messages(root, phone, env)
  env = env or {}
  local okNet, net = pcall(require, "tsr.net")
  local node = env.node or (okNet and net.default())
  if not node then
    root:add(W.label({ x = 1, y = 2, w = root.w, h = 4, wrap = true, text = "Install the net package to send messages.", role = "textDim" }))
    return
  end
  local peers = node:peers()
  if #peers == 0 then
    root:add(W.label({ x = 1, y = 2, w = root.w, h = 4, wrap = true, text = "No paired computers yet. Pair one with: net pair", role = "textDim" }))
    return
  end
  local items = {}
  for i, p in ipairs(peers) do items[i] = { text = p.name, peer = p } end
  local list = root:add(W.list({ x = 1, y = 1, w = root.w, h = root.h, items = items,
    onActivate = function(_, item) M.conversation(root, phone, env, node, item.peer) end }))
  list:focus()
end

function M.conversation(root, phone, env, node, peer)
  phone:push(peer.name, function(r, ph)
    local vfs = require("tsr.vfs")
    local log = vfs.readJSON(env.logPath or M.MESSAGE_LOG) or {}
    local lines = {}
    for _, m in ipairs(log) do
      if m.mine and m.to == peer.name then lines[#lines + 1] = "me: " .. m.text
      elseif not m.mine and m.from == peer.name then lines[#lines + 1] = m.from .. ": " .. m.text end
    end
    local list = r:add(W.list({ x = 1, y = 1, w = r.w, h = r.h - 3, items = lines }))
    if #lines > 0 then list:select(#lines) end
    local status = r:add(W.label({ x = 1, y = r.h - 2, w = r.w, text = "", role = "textDim" }))
    local input
    local function send()
      if input.text == "" then return end
      local res, err = node:call(peer.name, "msg", "post", { text = input.text }, { timeout = 4 })
      if res then
        local l = vfs.readJSON(env.logPath or M.MESSAGE_LOG) or {}
        l[#l + 1] = { mine = true, to = peer.name, text = input.text, time = "" }
        vfs.writeJSON(env.logPath or M.MESSAGE_LOG, l)
        lines[#lines + 1] = "me: " .. input.text
        list:setItems(lines)
        list:select(#lines)
        input:setText("")
        status.text = ""
      else
        status.text = tostring(err)
        status.role = "danger"
      end
    end
    input = r:add(W.input({ x = 1, y = r.h - 1, w = r.w - 5, placeholder = "message", onSubmit = send }))
    r:add(W.button({ x = r.w - 4, y = r.h - 1, w = 5, text = "Send", onClick = send }))
    input:focus()
  end)
end

---------------------------------------------------------------------------------------------------------------------
-- Location
---------------------------------------------------------------------------------------------------------------------

function M.location(root, phone, env)
  env = env or {}
  local locate = env.locate or function() return gps.locate(2) end
  local label = root:add(W.label({ x = 1, y = 2, w = root.w, h = 5, text = "Press Locate", align = "center" }))
  local function update()
    local x, y, z = locate()
    if x then
      label.text = ("x %.0f\ny %.0f\nz %.0f"):format(x, y, z)
    else
      label.text = "No GPS signal.\nA GPS host must be\nwithin range."
    end
  end
  root:add(W.button({ x = 2, y = 9, w = root.w - 2, text = "Locate", primary = true, onClick = update }))
  update()
end

---------------------------------------------------------------------------------------------------------------------
-- Remote: paired computers, ping and a remote shell
---------------------------------------------------------------------------------------------------------------------

function M.remote(root, phone, env)
  env = env or {}
  local okNet, net = pcall(require, "tsr.net")
  local node = env.node or (okNet and net.default())
  if not node then
    root:add(W.label({ x = 1, y = 2, w = root.w, h = 3, wrap = true, text = "Install the net package.", role = "textDim" }))
    return
  end
  local peers = node:peers()
  if #peers == 0 then
    root:add(W.label({ x = 1, y = 2, w = root.w, h = 4, wrap = true, text = "No paired computers. Pair one with: net pair", role = "textDim" }))
    return
  end
  local items = {}
  for i, p in ipairs(peers) do items[i] = { text = p.name, peer = p } end
  local list = root:add(W.list({ x = 1, y = 1, w = root.w, h = root.h - 4, items = items }))
  local status = root:add(W.label({ x = 1, y = root.h - 3, w = root.w, h = 2, wrap = true, text = "", role = "textDim" }))
  root:add(W.button({ x = 1, y = root.h, w = 8, text = "Ping", onClick = function()
    local item = list:selectedItem()
    if not item then return end
    local rtt, host = node:ping(item.peer.name, 2)
    status.text = rtt and (("%s: %d ms"):format(host or item.peer.name, math.floor(rtt * 1000))) or "no answer"
  end }))
  root:add(W.button({ x = 10, y = root.h, w = root.w - 10, text = "Shell", onClick = function()
    local item = list:selectedItem()
    if item then (env.runProgram or function(l) phone:runProgram(l) end)("rsh " .. item.peer.name) end
  end }))
  list:focus()
end

---------------------------------------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------------------------------------

function M.settings(root, phone, env)
  env = env or {}
  local config = env.config or require("tsr.config")
  root:add(W.label({ x = 1, y = 1, text = "Theme", role = "accent" }))
  local items = {}
  for i, n in ipairs(theme.order) do items[i] = { text = n, name = n } end
  local list = root:add(W.list({ x = 1, y = 2, w = root.w, h = #items, items = items }))
  for i, n in ipairs(theme.order) do if n == theme.currentName then list.selected = i end end
  list.onSelect = function(_, item)
    theme.set(item.name, phone.t.isColor())
    config.set("ui.theme", item.name, "system")
    phone:show(phone:current())
  end
  root:add(W.checkbox({ x = 1, y = #items + 3, text = "Phone mode at boot", checked = config.get("ui.default", "shell") == "mobile",
    onChange = function(v) config.set("ui.default", v and "mobile" or "shell", "system") end }))
  root:add(W.button({ x = 1, y = #items + 5, w = root.w, text = "Exit to shell", onClick = function() phone.exitAction = "shell" end }))
  root:add(W.button({ x = 1, y = #items + 6, w = root.w, text = "Shut down", onClick = function() phone.exitAction = "shutdown" end }))
  root:add(W.button({ x = 1, y = #items + 7, w = root.w, text = "Restart", onClick = function() phone.exitAction = "reboot" end }))
  list:focus()
end

return M
