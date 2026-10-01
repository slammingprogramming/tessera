-- SPDX-License-Identifier: AGPL-3.0-or-later
-- In-game chat bot for the Advanced Peripherals chat box (peripheral "chat_box", "chatBox" before Minecraft 1.21.1).
-- The box raises  chat(username, message, uuid, isHidden)  for every chat message; messages that start with the command
-- prefix (default "!") are answered with sendMessageToPlayer.
--
--   !help            list the commands you may use
--   !status          this computer's uptime, services and warnings
--   !time            in-game time and day
--   !ping <peer>     reach a paired computer      !metrics <peer>    its vital signs
--   !svc list|start|stop|restart <name>           (administrators only)
--
-- Configuration /etc/tsr/chatbot.cfg:  { prefix = "!", name = "Tessera", admins = { "PlayerName" }, admin_uuids = { "..." } }
-- More commands: drop a file into /etc/tsr/chatbot.d/ that returns { name = { help = "...", admin = false, run = function(ctx, args) return "text" end } }.
local vfs = require("tsr.vfs")

local M = {}

M.CFG_PATH = "/etc/tsr/chatbot.cfg"
M.DIR = "/etc/tsr/chatbot.d"
M.MAX_LINE = 240
M.MAX_LINES = 3
M.COOLDOWN = 1.5

M.commands = {}
local lastUse = {}

function M.loadConfig()
  local cfg = vfs.readTable(M.CFG_PATH) or {}
  cfg.prefix = cfg.prefix or "!"
  cfg.name = cfg.name or "Tessera"
  cfg.admins = cfg.admins or {}
  cfg.admin_uuids = cfg.admin_uuids or {}
  return cfg
end

--- Add or replace a command at runtime.
function M.register(name, def) M.commands[name] = def end

local function isAdmin(cfg, user, uuid)
  for _, a in ipairs(cfg.admins) do
    if type(user) == "string" and a:lower() == user:lower() then return true end
  end
  for _, u in ipairs(cfg.admin_uuids) do
    if uuid and u == uuid then return true end
  end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- Built-in commands: run(ctx, args) returns text (or a list of lines)
---------------------------------------------------------------------------------------------------------------------

local function node() return require("tsr.net").default() end

M.register("help", { help = "list the commands", run = function(ctx)
  local names = {}
  for name, def in pairs(M.commands) do
    if not def.admin or ctx.admin then names[#names + 1] = ctx.prefix .. name end
  end
  table.sort(names)
  return "Commands: " .. table.concat(names, " ")
end })

M.register("status", { help = "uptime, services, warnings", run = function()
  local g = require("tsr.metrics").collect()
  local parts = { g.host, ("up %dm"):format(math.floor(g.uptime / 60)) }
  if g.services_running then parts[#parts + 1] = ("%d services (%d failed)"):format(g.services_running, g.services_failed or 0) end
  parts[#parts + 1] = ("%d warnings, %d errors"):format(g.log_warn, g.log_error)
  return table.concat(parts, ", ")
end })

M.register("time", { help = "in-game time", run = function()
  return ("Day %d, %s"):format(os.day("ingame"), textutils.formatTime(os.time("ingame"), true))
end })

M.register("ping", { help = "ping <peer>", run = function(_, args)
  if not args[1] then return "usage: ping <peer>" end
  local rtt, host = node():ping(tonumber(args[1]) or args[1], 2)
  if not rtt then return "no answer from " .. args[1] end
  return ("%s answered in %d ms"):format(host or args[1], math.floor(rtt * 1000))
end })

M.register("metrics", { help = "metrics <peer>", run = function(_, args)
  if not args[1] then return "usage: metrics <peer>" end
  local g, err = node():call(tonumber(args[1]) or args[1], "metrics", "get", nil, { timeout = 4 })
  if not g then return tostring(err) end
  return ("%s: up %dm, %d processes, %d warnings"):format(tostring(g.host), math.floor((g.uptime or 0) / 60), g.processes or 0, g.log_warn or 0)
end })

M.register("svc", { help = "svc list|start|stop|restart <name>", admin = true, run = function(_, args)
  local svc = require("tsr.svc")
  if #svc.names() == 0 then svc.load() end
  local action, name = args[1], args[2]
  if action == "list" or action == nil then
    local out = {}
    for _, s in ipairs(svc.list()) do out[#out + 1] = s.name .. "=" .. s.state end
    return #out > 0 and table.concat(out, " ") or "no services"
  elseif (action == "start" or action == "stop" or action == "restart") and name then
    local ok, err = svc[action](name)
    return ok and (action .. " " .. name .. ": ok") or tostring(err)
  end
  return "usage: svc list|start|stop|restart <name>"
end })

--- Load extra command files from M.DIR.
function M.loadExtras()
  if not fs.isDir(M.DIR) then return 0 end
  local n = 0
  for _, f in ipairs(fs.list(M.DIR)) do
    if f:match("%.lua$") then
      local chunk = loadfile(M.DIR .. "/" .. f, "t", setmetatable({}, { __index = _G }))
      local ok, defs = false, nil
      if chunk then ok, defs = pcall(chunk) end
      if ok and type(defs) == "table" then
        for name, def in pairs(defs) do
          if type(def) == "table" and type(def.run) == "function" then M.register(name, def) n = n + 1 end
        end
      end
    end
  end
  return n
end

---------------------------------------------------------------------------------------------------------------------
-- Handling messages
---------------------------------------------------------------------------------------------------------------------

local function split(text)
  local out = {}
  for w in text:gmatch("%S+") do out[#out + 1] = w end
  return out
end

--- Cut a reply into at most MAX_LINES chat lines.
local function lines(text)
  if type(text) == "table" then text = table.concat(text, " | ") end
  text = tostring(text):gsub("[\r\n]+", " ")
  local out = {}
  while #text > 0 and #out < M.MAX_LINES do
    out[#out + 1] = text:sub(1, M.MAX_LINE)
    text = text:sub(M.MAX_LINE + 1)
  end
  if #text > 0 then out[#out] = out[#out]:sub(1, M.MAX_LINE - 3) .. "..." end
  return out
end

function M.send(box, cfg, user, text)
  for _, line in ipairs(lines(text)) do
    local ok = box.sendMessageToPlayer and pcall(box.sendMessageToPlayer, line, user, cfg.name)
    if not ok and box.sendMessage then pcall(box.sendMessage, "@" .. tostring(user) .. " " .. line, cfg.name) end
  end
end

--- Process one chat event. Returns true when it was a command (answered or refused).
function M.handle(box, cfg, user, message, uuid, now)
  if type(message) ~= "string" or message:sub(1, #cfg.prefix) ~= cfg.prefix then return false end
  local words = split(message:sub(#cfg.prefix + 1))
  local name = table.remove(words, 1)
  if not name then return false end
  now = now or os.clock()
  local key = uuid or user
  if lastUse[key] and now - lastUse[key] < M.COOLDOWN then return true end    -- too fast: ignore quietly
  lastUse[key] = now
  local def = M.commands[name:lower()]
  if not def then
    M.send(box, cfg, user, "Unknown command. Try " .. cfg.prefix .. "help")
    return true
  end
  local admin = isAdmin(cfg, user, uuid)
  if def.admin and not admin then
    M.send(box, cfg, user, "Only administrators can use " .. cfg.prefix .. name)
    return true
  end
  local ok, res = pcall(def.run, { user = user, uuid = uuid, admin = admin, prefix = cfg.prefix }, words)
  M.send(box, cfg, user, ok and res or ("That failed: " .. tostring(res)))
  return true
end

function M.resetCooldowns() lastUse = {} end

function M.findBox()
  return peripheral.find("chat_box") or peripheral.find("chatBox")
end

--- The chatbotd service: wait for a chat box, answer commands.
function M.daemon()
  M.loadExtras()
  while true do
    local box = M.findBox()
    if not box then
      os.pullEvent("peripheral")
    else
      local cfg = M.loadConfig()
      local ev, user, message, uuid = os.pullEvent("chat")
      pcall(M.handle, box, cfg, user, message, uuid)
    end
  end
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

--- chatbot admin add|remove <player> | prefix <p> | status
function M.cli(args, io)
  io = io or defaultIO()
  local cfg = M.loadConfig()
  local cmd = args[1] or "status"
  if cmd == "admin" and args[2] and args[3] then
    local kept = {}
    for _, a in ipairs(cfg.admins) do if a:lower() ~= args[3]:lower() then kept[#kept + 1] = a end end
    if args[2] == "add" then kept[#kept + 1] = args[3] elseif args[2] ~= "remove" then io.err("usage: chatbot admin add|remove <player>") return false end
    cfg.admins = kept
    vfs.writeTable(M.CFG_PATH, cfg)
    io.say("Administrators: " .. (#kept > 0 and table.concat(kept, ", ") or "nobody"))
    return true
  elseif cmd == "prefix" and args[2] and #args[2] <= 3 then
    cfg.prefix = args[2]
    vfs.writeTable(M.CFG_PATH, cfg)
    io.say("Commands now start with " .. args[2])
    return true
  elseif cmd == "status" then
    io.say("chat box: " .. (M.findBox() and "found" or "not attached (needs Advanced Peripherals)"))
    io.say("prefix: " .. cfg.prefix .. "   administrators: " .. (#cfg.admins > 0 and table.concat(cfg.admins, ", ") or "nobody"))
    return true
  end
  io.err("usage: chatbot status | admin add|remove <player> | prefix <p>")
  return false
end

function M.main(args) return M.cli(args) end

return M
