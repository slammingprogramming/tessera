-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Commands:
--   iptables [-t table] <command>        the packet filter and NAT (see tsr.inet.fw.iptables for the syntax)
--   iptables-save | iptables-restore [file]    write the rules to /etc/tsr/inet/iptables.rules (loaded at boot) / load them from a file
--   conntrack -L | -F | -C | -S          list, flush, count the tracked connections / show the tracker statistics
local B = require("tsr.inet.bytes")
local fwMod = require("tsr.inet.fw")
local iptables = require("tsr.inet.fw.iptables")
local vfs = require("tsr.vfs")

local M = {}

M.RULES = "/etc/tsr/inet/iptables.rules"

local function defaultCtx(ctx)
  ctx = ctx or {}
  if not ctx.say then
    ctx.say = function(t) print(t) end
    ctx.err = function(t) print(t) end
  end
  ctx.err = ctx.err or ctx.say
  if not ctx.stack then
    local ok, stack = pcall(function() return require("tsr.inet.socket").default() end)
    if not ok then ctx.err(tostring(stack)) return nil end
    ctx.stack = stack
  end
  if not ctx.fw then ctx.fw = ctx.stack.fw end
  if not ctx.fw then ctx.fw = fwMod.install(ctx.stack) end
  return ctx
end

local function isAdmin(ctx)
  local okAuth, auth = pcall(require, "tsr.auth")
  if not okAuth or not auth.hasUsers() then return true end
  local me = auth.current()
  if me == nil or auth.can(me, "auth.manage") then return true end
  ctx.err("only administrators can change the firewall")
  return false
end

function M.iptables(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local listing = false
  for _, a in ipairs(args) do if a == "-L" or a == "-S" or a == "--list" or a == "--list-rules" then listing = true end end
  if not listing and not isAdmin(ctx) then return false end
  return iptables.exec(ctx.fw, args, ctx)
end

function M.save(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  if not isAdmin(ctx) then return false end
  local text = iptables.save(ctx.fw)
  if args[1] == "-" or args[1] == "--print" then ctx.say(text) return true end
  local ok, err = vfs.writeFile(M.RULES, "# Saved by iptables-save; loaded when the netfilter service starts.\n" .. text)
  if not ok then ctx.err("could not save: " .. tostring(err)) return false end
  ctx.say("rules saved to " .. M.RULES)
  return true
end

function M.restore(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  if not isAdmin(ctx) then return false end
  local text = vfs.readFile(args[1] and vfs.normalize(args[1]) or M.RULES)
  if not text then ctx.err("cannot read " .. tostring(args[1] or M.RULES)) return false end
  ctx.fw:flush("filter") ctx.fw:flush("nat")
  local problems = iptables.load(ctx.fw, text)
  for _, p in ipairs(problems) do ctx.err(p) end
  return #problems == 0
end

local function tupleText(t) return ("%s:%d > %s:%d"):format(B.ipStr(t.src), t.sport, B.ipStr(t.dst), t.dport) end

function M.conntrack(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local fw = ctx.fw
  local what = args[1] or "-L"
  if what == "-L" then
    for _, f in ipairs(fw:flows()) do
      ctx.say(("%-4s %-11s %4ds  %s   reply %s%s%s"):format(f.proto, f.state, f.expires, tupleText(f.orig), tupleText(f.reply),
        f.snat and ("  snat " .. B.ipStr(f.snat.ip) .. ":" .. f.snat.port) or "", f.dnat and ("  dnat " .. B.ipStr(f.dnat.ip) .. ":" .. f.dnat.port) or ""))
    end
    return true
  elseif what == "-C" then
    ctx.say(tostring(fw.ct.count))
    return true
  elseif what == "-F" then
    if not isAdmin(ctx) then return false end
    for _, e in ipairs(fw.ct:list()) do fw.ct:remove(e) end
    ctx.say("flushed")
    return true
  elseif what == "-S" then
    local s = fw.ct.stats
    ctx.say(("entries %d, created %d, expired %d, evicted %d, invalid %d"):format(fw.ct.count, s.created, s.expired, s.evicted, s.invalid))
    ctx.say(("packets accepted %d, dropped %d, rejected %d, translated flows %d"):format(fw.stats.accepted, fw.stats.dropped, fw.stats.rejected, fw.stats.nat))
    return true
  end
  ctx.err("usage: conntrack -L | -C | -F | -S")
  return false
end

return M
