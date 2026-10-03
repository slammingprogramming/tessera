-- SPDX-License-Identifier: AGPL-3.0-or-later
-- home                           list the devices with their rooms and states
-- home on|off|open|close|lock|unlock|toggle <device>      switch a device
-- home scene <name>              apply a scene          home scenes     list the scenes
-- home init                      write an example settings file
local home = require("tsr.home")
local daemon = require("tsr.home.daemon")
local vfs = require("tsr.vfs")

local M = {}

local function defaultCtx(ctx)
  ctx = ctx or {}
  ctx.say = ctx.say or function(t) print(t) end
  ctx.err = ctx.err or ctx.say
  return ctx
end

local function hubOf(ctx)
  if ctx.hub then return ctx.hub end
  local cfg, err = daemon.loadConfig()
  if not cfg then return nil, err end
  local ok, hal = pcall(require, "tsr.hal")
  local okN, hub = pcall(home.new, cfg, { devices = function() return ok and hal.scan() or {} end })
  if not okN then return nil, tostring(hub) end
  return hub
end

function M.run(args, ctx)
  ctx = defaultCtx(ctx)
  local sub = table.remove(args, 1)
  if sub == "init" then
    if vfs.fs.exists(daemon.CONFIG) then ctx.err(daemon.CONFIG .. " exists already") return false end
    vfs.writeFile(daemon.CONFIG, daemon.TEMPLATE)
    ctx.say("wrote " .. daemon.CONFIG .. " - name your devices there, then: svc start homed")
    return true
  end
  local hub, err = hubOf(ctx)
  if not hub then ctx.err(tostring(err)) return false end
  if sub == nil or sub == "list" or sub == "status" then
    local list = hub:list()
    if #list == 0 then ctx.say("no devices yet: edit " .. daemon.CONFIG) end
    local room
    for _, d in ipairs(list) do
      if d.room ~= room then room = d.room ctx.say(room .. ":") end
      local state = d.state ~= nil and (tostring(d.state) .. (d.unit and d.unit ~= "assumed" and (" " .. tostring(d.unit)) or "")) or "?"
      ctx.say(("  %-18s %-9s %s"):format(d.name, d.kind, state))
    end
    return true
  elseif sub == "scenes" then
    local names = {}
    for n in pairs(hub.cfg.scenes or {}) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do ctx.say(n) end
    if #names == 0 then ctx.say("no scenes") end
    return true
  elseif sub == "scene" then
    local n, problems = hub:scene(args[1] or "")
    if not n then ctx.err(tostring(problems)) return false end
    ctx.say(("scene %s: %d device(s) set"):format(args[1], n))
    for _, p in ipairs(problems) do ctx.err(p) end
    return #problems == 0
  elseif sub == "on" or sub == "off" or sub == "open" or sub == "close" or sub == "lock" or sub == "unlock" or sub == "toggle" then
    if not args[1] then ctx.err("usage: home " .. sub .. " <device>") return false end
    local state, why = hub:set(args[1], sub)
    if not state then ctx.err(tostring(why)) return false end
    ctx.say(args[1] .. " is now " .. state)
    return true
  end
  ctx.err("usage: home [list] | on|off|open|close|lock|unlock|toggle <device> | scene <name> | scenes | init")
  return false
end

return M
