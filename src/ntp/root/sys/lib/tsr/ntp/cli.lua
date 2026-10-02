-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Commands for the clock:
--   date [+format] [-u] [--ingame]            show the time (system zone; -u for UTC; --ingame for Minecraft's day and time)
--   date -s "2026-10-02 14:30:00"             set the clock by hand (administrators); same as `ntp set`
--   ntp status                                how this computer's clock is doing (source, stratum, offset, zone)
--   ntp sync [--force]                        synchronise now          ntp auto   leave manual mode
--   ntp set <time>                            set the clock by hand    ntp tz [zone]   show / set the time zone
--   ntp servers | add peer <host> | add http [url [json|header]] | add local | remove <n> | up <n>
--   ntp serve on|off [--closed]               make this computer a time server for others (--closed: paired computers only)
--   ntpdate <server>                          ask a time server and show the offset without changing the clock
local ntp = require("tsr.ntp")
local time = require("tsr.time")
local web = require("tsr.ntp.web")

local M = {}

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  return io
end

local function needAdmin(io)
  local okAuth, auth = pcall(require, "tsr.auth")
  if not okAuth or not auth.hasUsers() then return true end
  local me = auth.current()
  if me == nil or auth.can(me, "auth.manage") then return true end
  io.err("only administrators can change the clock or its settings")
  return false
end

local function fmtMs(ms) return ("%+.0f ms"):format(ms) end

local function sourceText(src)
  if src.type == "peer" then return "peer " .. tostring(src.host) .. (src.auth == false and " (plain)" or "") end
  if src.type == "http" then return ("http %s (%s)"):format(tostring(src.url), tostring(src.kind or "header")) end
  return "local clock"
end

local function flagsOf(args)
  local flags, words = {}, {}
  for _, a in ipairs(args) do
    if a:sub(1, 2) == "--" then flags[a:sub(3)] = true
    elseif a == "-u" or a == "-s" then flags[a:sub(2)] = true
    else words[#words + 1] = a end
  end
  return flags, words
end

---------------------------------------------------------------------------------------------------------------------
-- date
---------------------------------------------------------------------------------------------------------------------

function M.date(args, io)
  io = io or defaultIO()
  local flags, words = flagsOf(args)
  if flags.ingame then
    io.say(time.ingame().text)
    return true
  end
  if flags.s then
    if not needAdmin(io) then return false end
    local ms, err = time.parse(table.concat(words, " "))
    if not ms then io.err(tostring(err)) return false end
    time.setNow(ms)
    io.say(time.stamp(time.now()) .. "  (manual mode: `ntp auto` returns to synchronisation)")
    return true
  end
  local fmt = words[1] and words[1]:match("^%+(.*)$")
  local zone = flags.u and time.zone("UTC") or nil
  io.say(time.format(fmt or "%a %b %e %H:%M:%S %Z %Y", time.now(), zone))
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- ntp
---------------------------------------------------------------------------------------------------------------------

local function status(io)
  local s = time.state()
  local c = ntp.config()
  io.say("Local time:      " .. time.stamp(time.now()))
  io.say("Universal time:  " .. time.iso(time.now()))
  io.say("Host clock:      " .. time.iso(time.clock()) .. (s.offset ~= 0 and ("   (corrected by " .. fmtMs(s.offset) .. ")") or ""))
  io.say("Time zone:       " .. time.currentZone().name .. " (" .. select(2, time.offsetAt(time.currentZone(), math.floor(time.utc()))) .. ")")
  io.say("In-game time:    " .. time.ingame().text)
  if s.mode == "manual" then
    io.say("Mode:            MANUAL: the clock was set by hand; `ntp auto` resumes synchronisation")
  elseif s.source then
    io.say(("Synchronised:    yes, to %s (stratum %s%s)"):format(tostring(s.source), tostring(s.stratum), s.delay and (", delay " .. ("%.0f"):format(s.delay) .. " ms") or ""))
    io.say("Last sync:       " .. (s.last and time.stamp(s.last) or "never"))
  else
    io.say("Synchronised:    not yet (using the host clock)")
  end
  io.say("Serving time:    " .. (c.serve and ("yes" .. (c.open and "" or " (paired computers only)")) or "no"))
  io.say("Sources:         " .. #c.servers .. " (`ntp servers`)")
  return true
end

local function servers(io)
  local c = ntp.config()
  for i, src in ipairs(c.servers) do io.say(("%d. %s"):format(i, sourceText(src))) end
  return true
end

function M.ntp(args, io, node)
  io = io or defaultIO()
  local flags, words = flagsOf(args)
  local sub = words[1] or "status"

  if sub == "status" then return status(io) end
  if sub == "servers" then return servers(io) end

  if sub == "sync" then
    if not needAdmin(io) then return false end
    local res = ntp.sync({ force = flags.force, node = node })
    if not res.ok then io.err("sync failed: " .. tostring(res.error)) return false end
    io.say(("Synchronised to %s: offset %s, delay %.0f ms, stratum %d (%s)."):format(res.source, fmtMs(res.offset), res.delay, res.stratum, res.how))
    return true
  elseif sub == "auto" then
    if not needAdmin(io) then return false end
    time.auto()
    io.say("Automatic synchronisation is on again. Run `ntp sync` to apply it now.")
    return true
  elseif sub == "set" then
    if not needAdmin(io) then return false end
    local text = table.concat(words, " ", 2)
    local ms, err = time.parse(text)
    if not ms then io.err(tostring(err)) return false end
    time.setNow(ms)
    io.say("Clock set to " .. time.stamp(time.now()) .. " (manual mode).")
    return true
  elseif sub == "tz" then
    if words[2] then
      if not needAdmin(io) then return false end
      local z, err = time.setZone(words[2])
      if not z then io.err(err) return false end
      io.say("Time zone is now " .. z.name .. ": " .. time.stamp(time.now()))
    else
      io.say(time.currentZone().name)
    end
    return true
  elseif sub == "zones" then
    io.say(table.concat(time.zoneNames(), "\n"))
    return true
  elseif sub == "add" then
    if not needAdmin(io) then return false end
    local c = ntp.config()
    local kind = words[2]
    if kind == "peer" and words[3] then c.servers[#c.servers + 1] = { type = "peer", host = words[3], auth = flags.plain and false or nil }
    elseif kind == "http" then
      if words[3] then c.servers[#c.servers + 1] = { type = "http", url = words[3], kind = words[4] or "header" }
      else for _, d in ipairs(web.DEFAULTS) do c.servers[#c.servers + 1] = { type = d.type, kind = d.kind, url = d.url } end end
    elseif kind == "local" then c.servers[#c.servers + 1] = { type = "local" }
    else io.err("usage: ntp add peer <host> | add http [url [json|header]] | add local") return false end
    ntp.saveConfig(c)
    return servers(io)
  elseif sub == "remove" or sub == "up" then
    if not needAdmin(io) then return false end
    local c = ntp.config()
    local n = tonumber(words[2])
    if not n or not c.servers[n] then io.err("usage: ntp " .. sub .. " <number from `ntp servers`>") return false end
    if sub == "remove" then table.remove(c.servers, n)
    elseif n > 1 then c.servers[n], c.servers[n - 1] = c.servers[n - 1], c.servers[n] end
    if #c.servers == 0 then c.servers = { { type = "local" } } end
    ntp.saveConfig(c)
    return servers(io)
  elseif sub == "serve" then
    if not needAdmin(io) then return false end
    local c = ntp.config()
    if words[2] ~= "on" and words[2] ~= "off" then io.err("usage: ntp serve on|off [--closed]") return false end
    c.serve = words[2] == "on"
    c.open = not flags.closed
    ntp.saveConfig(c)
    io.say(c.serve and ("This computer will serve time" .. (c.open and "" or " to paired computers only") .. " once the ntpd service (re)starts: svc restart ntpd") or "This computer will no longer serve time (restart ntpd).")
    return true
  end
  io.err("usage: ntp status | sync | auto | set <time> | tz [zone] | zones | servers | add ... | remove <n> | up <n> | serve on|off")
  return false
end

function M.ntpdate(args, io, node)
  io = io or defaultIO()
  local flags, words = flagsOf(args)
  local target = words[1]
  if not target then io.err("usage: ntpdate <server>   (shows the offset, does not change the clock)") return false end
  local proto = require("tsr.ntp.proto")
  node = node or require("tsr.net").default()
  local s, err = proto.measure(node, target, { clock = time.clock, samples = 4 })
  if not s then io.err(tostring(err)) return false end
  io.say(("server %s, stratum %d (%s), offset %s, delay %.0f ms%s"):format(tostring(s.host or target), s.stratum, tostring(s.refid), fmtMs(s.offset), s.delay, s.authenticated and ", authenticated" or ", NOT authenticated"))
  return true
end

return M
