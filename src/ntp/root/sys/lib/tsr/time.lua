-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The system clock of a Tessera computer: UTC from the host (os.epoch) plus a correction that time synchronisation maintains,
-- time zones with daylight saving rules, date formatting and parsing, and the in-game (Minecraft) clock.
--
--   time.now()            UTC milliseconds since 1970, corrected         time.utc()    the same in seconds
--   time.format("%Y-%m-%d %H:%M:%S %Z", ms [, zone])                      time.parse("2026-10-02 14:30:00" [, zone]) -> ms
--   time.zone("Europe/Berlin")  time.setZone(...)  time.zoneName()        time.ingame() -> { day, hour, minute, second }
--   time.setOffset(ms, info)  time.offset()  time.state()                 (used by tsr.ntp and the date command)
--
-- Time zones: a compact built-in table of well known zones with their current daylight saving rule (US, EU, Australia, New Zealand,
-- none), plus "UTC+5" / "UTC-03:30" forms. Past years' rule changes are not modelled: this is for running a base, not for genealogy.
local floor = math.floor

local M = {}

M.statePath = "/var/lib/tsr/time.json"
M.clock = function() return os.epoch and os.epoch("utc") or 0 end      -- the raw host clock (replaced in tests)

---------------------------------------------------------------------------------------------------------------------
-- Civil calendar arithmetic (proleptic Gregorian, Howard Hinnant's algorithms)
---------------------------------------------------------------------------------------------------------------------

local function daysFromCivil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = floor(y / 400)
  local yoe = y - era * 400
  local doy = floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civilFromDays(z)
  z = z + 719468
  local era = floor(z / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local d = doy - floor((153 * mp + 2) / 5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  if m <= 2 then y = y + 1 end
  return y, m, d
end

local function weekday(days) return (days + 4) % 7 end          -- 0 = Sunday

local function isLeap(y) return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 end
local MDAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function daysInMonth(y, m) return (m == 2 and isLeap(y)) and 29 or MDAYS[m] end

--- Seconds since 1970 (UTC) of a calendar date and time.
function M.timegm(y, m, d, hh, mm, ss) return daysFromCivil(y, m, d) * 86400 + (hh or 0) * 3600 + (mm or 0) * 60 + (ss or 0) end

--- Calendar fields of UTC seconds: year, month, day, hour, minute, second, weekday (0 = Sunday), day of year.
function M.fields(sec)
  local days = floor(sec / 86400)
  local rem = sec - days * 86400
  local y, m, d = civilFromDays(days)
  return y, m, d, floor(rem / 3600), floor(rem / 60) % 60, floor(rem % 60), weekday(days), days - daysFromCivil(y, 1, 1) + 1
end

local function nthWeekdayOfMonth(y, m, n, wd)       -- n = 1.. or -1 for the last
  if n > 0 then
    local first = daysFromCivil(y, m, 1)
    local delta = (wd - weekday(first)) % 7
    return first + delta + (n - 1) * 7
  end
  local last = daysFromCivil(y, m, daysInMonth(y, m))
  return last - (weekday(last) - wd) % 7
end

---------------------------------------------------------------------------------------------------------------------
-- Time zones
---------------------------------------------------------------------------------------------------------------------

-- name -> { offset minutes of standard time, rule, standard abbreviation, daylight abbreviation }
local ZONES = {
  ["UTC"] = { 0, "none", "UTC" }, ["Etc/UTC"] = { 0, "none", "UTC" }, ["GMT"] = { 0, "none", "GMT" },
  ["Europe/London"] = { 0, "eu", "GMT", "BST" }, ["Europe/Dublin"] = { 0, "eu", "GMT", "IST" }, ["Europe/Lisbon"] = { 0, "eu", "WET", "WEST" },
  ["Europe/Paris"] = { 60, "eu", "CET", "CEST" }, ["Europe/Berlin"] = { 60, "eu", "CET", "CEST" }, ["Europe/Madrid"] = { 60, "eu", "CET", "CEST" },
  ["Europe/Rome"] = { 60, "eu", "CET", "CEST" }, ["Europe/Amsterdam"] = { 60, "eu", "CET", "CEST" }, ["Europe/Brussels"] = { 60, "eu", "CET", "CEST" },
  ["Europe/Vienna"] = { 60, "eu", "CET", "CEST" }, ["Europe/Zurich"] = { 60, "eu", "CET", "CEST" }, ["Europe/Stockholm"] = { 60, "eu", "CET", "CEST" },
  ["Europe/Oslo"] = { 60, "eu", "CET", "CEST" }, ["Europe/Copenhagen"] = { 60, "eu", "CET", "CEST" }, ["Europe/Warsaw"] = { 60, "eu", "CET", "CEST" },
  ["Europe/Prague"] = { 60, "eu", "CET", "CEST" }, ["Europe/Athens"] = { 120, "eu", "EET", "EEST" }, ["Europe/Helsinki"] = { 120, "eu", "EET", "EEST" },
  ["Europe/Kyiv"] = { 120, "eu", "EET", "EEST" }, ["Europe/Bucharest"] = { 120, "eu", "EET", "EEST" }, ["Europe/Moscow"] = { 180, "none", "MSK" },
  ["Europe/Istanbul"] = { 180, "none", "+03" },
  ["America/New_York"] = { -300, "us", "EST", "EDT" }, ["America/Toronto"] = { -300, "us", "EST", "EDT" }, ["America/Chicago"] = { -360, "us", "CST", "CDT" },
  ["America/Denver"] = { -420, "us", "MST", "MDT" }, ["America/Phoenix"] = { -420, "none", "MST" }, ["America/Los_Angeles"] = { -480, "us", "PST", "PDT" },
  ["America/Vancouver"] = { -480, "bc", "PST", "PDT" }, ["America/Anchorage"] = { -540, "us", "AKST", "AKDT" }, ["Pacific/Honolulu"] = { -600, "none", "HST" },
  ["America/Mexico_City"] = { -360, "none", "CST" }, ["America/Sao_Paulo"] = { -180, "none", "-03" }, ["America/Argentina/Buenos_Aires"] = { -180, "none", "-03" },
  ["Asia/Tokyo"] = { 540, "none", "JST" }, ["Asia/Seoul"] = { 540, "none", "KST" }, ["Asia/Shanghai"] = { 480, "none", "CST" }, ["Asia/Hong_Kong"] = { 480, "none", "HKT" },
  ["Asia/Singapore"] = { 480, "none", "+08" }, ["Asia/Manila"] = { 480, "none", "PST" }, ["Asia/Kolkata"] = { 330, "none", "IST" }, ["Asia/Dubai"] = { 240, "none", "+04" },
  ["Asia/Karachi"] = { 300, "none", "PKT" }, ["Asia/Bangkok"] = { 420, "none", "+07" }, ["Asia/Jakarta"] = { 420, "none", "WIB" }, ["Asia/Tehran"] = { 210, "none", "+0330" },
  ["Australia/Sydney"] = { 600, "au", "AEST", "AEDT" }, ["Australia/Melbourne"] = { 600, "au", "AEST", "AEDT" }, ["Australia/Brisbane"] = { 600, "none", "AEST" },
  ["Australia/Adelaide"] = { 570, "au", "ACST", "ACDT" }, ["Australia/Perth"] = { 480, "none", "AWST" }, ["Pacific/Auckland"] = { 720, "nz", "NZST", "NZDT" },
  ["Africa/Cairo"] = { 120, "eg", "EET", "EEST" }, ["Africa/Johannesburg"] = { 120, "none", "SAST" }, ["Africa/Lagos"] = { 60, "none", "WAT" }, ["Africa/Nairobi"] = { 180, "none", "EAT" },
}
local ALIASES = { cet = "Europe/Berlin", cest = "Europe/Berlin", est = "America/New_York", edt = "America/New_York", cst = "America/Chicago", pst = "America/Los_Angeles",
  pdt = "America/Los_Angeles", mst = "America/Denver", jst = "Asia/Tokyo", ist = "Asia/Kolkata", bst = "Europe/London", aest = "Australia/Sydney" }

local LOWER = {}
for name in pairs(ZONES) do LOWER[name:lower()] = name end

--- Names of the built-in zones, sorted.
function M.zoneNames()
  local out = {}
  for name in pairs(ZONES) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- A zone from a name ("Europe/Berlin", "berlin", "CET") or a fixed offset ("UTC+5", "GMT-03:30", "+0530"). Returns zone table or nil.
function M.zone(name)
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return nil end
  local key = LOWER[name:lower()] or ALIASES[name:lower()]
  if not key then
    for lname, full in pairs(LOWER) do
      if lname:match("/" .. name:lower():gsub("%W", "%%%0") .. "$") then key = full break end
    end
  end
  if key then
    local z = ZONES[key]
    return { name = key, offset = z[1], rule = z[2], std = z[3], dst = z[4] }
  end
  local sign, h, mm = name:upper():match("^U?T?C?G?M?T?([+-])(%d%d?):?(%d?%d?)$")
  if sign then
    local minutes = tonumber(h) * 60 + (tonumber(mm) or 0)
    if sign == "-" then minutes = -minutes end
    if math.abs(minutes) <= 14 * 60 then
      return { name = ("UTC%s%d%s"):format(sign, tonumber(h), mm ~= "" and (":" .. mm) or ""), offset = minutes, rule = "none", std = ("%s%02d%s"):format(sign, tonumber(h), mm ~= "" and mm or "") }
    end
  end
  return nil
end

local function dstActive(zone, utcSec)
  local rule = zone.rule
  if rule == "none" then return false end
  local y = M.fields(utcSec)
  local std = zone.offset * 60
  if rule == "eg" then                                                                  -- Egypt: last Friday of April .. last Thursday of October
    local start = nthWeekdayOfMonth(y, 4, -1, 5) * 86400 - std
    local stop = (nthWeekdayOfMonth(y, 10, -1, 4) + 1) * 86400 - (std + 3600)
    return utcSec >= start and utcSec < stop
  end
  if rule == "bc" then                                                                  -- British Columbia: like the US until it stays on summer time for good
    if utcSec >= M.timegm(2026, 11, 1, 9, 0, 0) then return false end
    rule = "us"
  end
  if rule == "us" then
    local start = nthWeekdayOfMonth(y, 3, 2, 0) * 86400 + 2 * 3600 - std              -- 2nd Sunday of March, 02:00 standard time
    local stop = nthWeekdayOfMonth(y, 11, 1, 0) * 86400 + 2 * 3600 - (std + 3600)      -- 1st Sunday of November, 02:00 daylight time
    return utcSec >= start and utcSec < stop
  elseif rule == "eu" then
    local start = nthWeekdayOfMonth(y, 3, -1, 0) * 86400 + 3600                        -- last Sunday of March, 01:00 UTC
    local stop = nthWeekdayOfMonth(y, 10, -1, 0) * 86400 + 3600                        -- last Sunday of October, 01:00 UTC
    return utcSec >= start and utcSec < stop
  elseif rule == "au" then                                                              -- southern hemisphere: wraps the new year
    local stop = nthWeekdayOfMonth(y, 4, 1, 0) * 86400 + 3 * 3600 - (std + 3600)       -- 1st Sunday of April, 03:00 daylight
    local start = nthWeekdayOfMonth(y, 10, 1, 0) * 86400 + 2 * 3600 - std              -- 1st Sunday of October, 02:00 standard
    return utcSec < stop or utcSec >= start
  elseif rule == "nz" then
    local stop = nthWeekdayOfMonth(y, 4, 1, 0) * 86400 + 3 * 3600 - (std + 3600)
    local start = nthWeekdayOfMonth(y, 9, -1, 0) * 86400 + 2 * 3600 - std              -- last Sunday of September, 02:00 standard
    return utcSec < stop or utcSec >= start
  end
  return false
end

--- Offset from UTC in minutes at an instant, with the abbreviation and whether daylight saving applies.
function M.offsetAt(zone, utcSec)
  if zone.rule == "bc" and utcSec >= M.timegm(2026, 11, 1, 9, 0, 0) then return -420, "MST", false end    -- permanent UTC-7 from 1 Nov 2026
  local dst = dstActive(zone, utcSec)
  return zone.offset + (dst and 60 or 0), (dst and zone.dst or zone.std) or zone.std, dst
end

---------------------------------------------------------------------------------------------------------------------
-- The system clock
---------------------------------------------------------------------------------------------------------------------

local state = nil         -- { offset = ms, mode = "auto"|"manual", source, stratum, delay, jitter, last (ms), zone }

local function load()
  if state then return state end
  state = { offset = 0, mode = "auto", zone = "UTC" }
  local ok, vfs = pcall(require, "tsr.vfs")
  if ok then
    local saved = vfs.readJSON(M.statePath)
    if type(saved) == "table" then for k, v in pairs(saved) do state[k] = v end end
  end
  return state
end

local function save()
  local ok, vfs = pcall(require, "tsr.vfs")
  if ok then pcall(vfs.writeJSON, M.statePath, state) end
end

--- Forget the in-memory state (tests; also after another process changed the file).
function M.reload() state = nil end

--- Corrected UTC time in milliseconds.
function M.now() return M.clock() + load().offset end

--- Corrected UTC time in seconds (fractions kept).
function M.utc() return M.now() / 1000 end

--- The correction currently applied to the host clock, in milliseconds.
function M.offset() return load().offset end

--- Everything known about the synchronisation: { offset, mode, source, stratum, delay, jitter, last, zone }.
function M.state()
  local s = load()
  local copy = {}
  for k, v in pairs(s) do copy[k] = v end
  return copy
end

--- Set the correction. info: mode, source, stratum, delay, jitter. Persists.
function M.setOffset(ms, info)
  local s = load()
  s.offset = ms
  for k, v in pairs(info or {}) do s[k] = v end
  s.last = M.clock() + ms
  save()
  return s
end

--- Make the clock show `utcMs` right now (manual set, like date -s). Switches to manual mode until `auto`.
function M.setNow(utcMs)
  return M.setOffset(utcMs - M.clock(), { mode = "manual", source = "manual", stratum = 16, delay = 0 })
end

--- Back to automatic synchronisation (drops a manual setting).
function M.auto()
  local s = load()
  s.mode = "auto"
  if s.source == "manual" then s.source, s.stratum = nil, nil end
  save()
  return s
end

function M.zoneName() return load().zone or "UTC" end

--- The configured zone table (default UTC).
function M.currentZone() return M.zone(load().zone or "UTC") or M.zone("UTC") end

function M.setZone(name)
  local z = M.zone(name)
  if not z then return nil, "unknown time zone '" .. tostring(name) .. "' (try Europe/Berlin, America/New_York, UTC+2, ...)" end
  load().zone = z.name
  save()
  return z
end

---------------------------------------------------------------------------------------------------------------------
-- Formatting and parsing
---------------------------------------------------------------------------------------------------------------------

local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }

--- strftime-style formatting of UTC milliseconds in `zone` (zone table or name; default the system zone).
--- Supports %Y %y %m %d %e %H %I %M %S %p %a %A %b %B %j %Z %z %s %F %T %D %R %c %x %X %%.
function M.format(fmt, ms, zone)
  ms = ms or M.now()
  if type(zone) == "string" then zone = M.zone(zone) end
  zone = zone or M.currentZone()
  local utcSec = floor(ms / 1000)
  local minutes, abbrev = M.offsetAt(zone, utcSec)
  local y, mo, d, h, mi, s, wd, yday = M.fields(utcSec + minutes * 60)
  local function z2(n) return ("%02d"):format(n) end
  local h12 = h % 12 == 0 and 12 or h % 12
  local sign = minutes < 0 and "-" or "+"
  local am = math.abs(minutes)
  local map = {
    Y = ("%d"):format(y), y = z2(y % 100), m = z2(mo), d = z2(d), e = ("%2d"):format(d), H = z2(h), I = z2(h12), M = z2(mi), S = z2(s),
    p = h < 12 and "AM" or "PM", a = DAYS[wd + 1]:sub(1, 3), A = DAYS[wd + 1], b = MONTHS[mo]:sub(1, 3), B = MONTHS[mo], j = ("%03d"):format(yday),
    Z = abbrev, z = ("%s%02d%02d"):format(sign, floor(am / 60), am % 60), s = ("%.0f"):format(utcSec), ["%"] = "%",
  }
  map.F = map.Y .. "-" .. map.m .. "-" .. map.d
  map.T = map.H .. ":" .. map.M .. ":" .. map.S
  map.D = map.m .. "/" .. map.d .. "/" .. map.y
  map.R = map.H .. ":" .. map.M
  map.c = map.a .. " " .. map.b .. " " .. map.e .. " " .. map.T .. " " .. map.Y
  map.x = map.D
  map.X = map.T
  return (fmt:gsub("%%(.)", function(c) return map[c] or ("%" .. c) end))
end

--- Default human readable form: "2026-10-02 14:30:05 CEST".
function M.stamp(ms, zone) return M.format("%Y-%m-%d %H:%M:%S %Z", ms, zone) end

--- ISO 8601 in UTC: "2026-10-02T12:30:05Z".
function M.iso(ms) return M.format("%Y-%m-%dT%H:%M:%SZ", ms, M.zone("UTC")) end

--- Parse a date/time. Accepts "YYYY-MM-DD HH:MM[:SS]", "YYYY-MM-DDTHH:MM[:SS](Z|+hh:mm)", "YYYY-MM-DD", "HH:MM[:SS]" (today) and "@seconds".
--- Naive times are read in `zone`. Returns UTC milliseconds or nil + reason.
function M.parse(text, zone)
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if type(zone) == "string" then zone = M.zone(zone) end
  zone = zone or M.currentZone()
  local at = text:match("^@(%-?%d+%.?%d*)$")
  if at then return tonumber(at) * 1000 end
  local y, mo, d, h, mi, s, tz = text:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)[T ](%d%d?):(%d%d):?(%d?%d?)%s*(.-)$")
  if not y then
    y, mo, d = text:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
    h, mi, s, tz = 0, 0, 0, ""
  end
  if not y then
    local hh, mm, ss = text:match("^(%d%d?):(%d%d):?(%d?%d?)$")
    if not hh then return nil, "cannot read '" .. text .. "' as a date (try 2026-10-02 14:30:00)" end
    local ny, nm, nd = M.fields(floor(M.now() / 1000) + M.offsetAt(zone, floor(M.now() / 1000)) * 60)
    y, mo, d, h, mi, s, tz = ny, nm, nd, hh, mm, ss, ""
  end
  y, mo, d, h, mi = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi)
  s = tonumber(s) or 0
  if mo < 1 or mo > 12 or d < 1 or d > daysInMonth(y, mo) or h > 23 or mi > 59 or s > 59 then return nil, "that is not a real date or time" end
  local naive = M.timegm(y, mo, d, h, mi, s)
  tz = tz or ""
  if tz == "Z" or tz == "z" or tz:upper() == "UTC" then return naive * 1000 end
  local sign, th, tm = tz:match("^([+-])(%d%d):?(%d%d)$")
  if sign then
    local off = (tonumber(th) * 60 + tonumber(tm)) * (sign == "-" and -1 or 1)
    return (naive - off * 60) * 1000
  end
  if tz ~= "" then
    local named = M.zone(tz)
    if not named then return nil, "unknown time zone '" .. tz .. "'" end
    zone = named
  end
  -- local time -> UTC: guess with the standard offset, then correct with the offset that applies at that instant
  local guess = naive - zone.offset * 60
  local off = M.offsetAt(zone, guess)
  local utc = naive - off * 60
  if M.offsetAt(zone, utc) ~= off then utc = naive - M.offsetAt(zone, utc) * 60 end
  return utc * 1000
end

---------------------------------------------------------------------------------------------------------------------
-- The in-game clock
---------------------------------------------------------------------------------------------------------------------

--- Minecraft's clock: day number and time of day (a game day lasts 20 real minutes). Returns { day, hour, minute, second, text }.
function M.ingame()
  local okD, day = pcall(os.day, "ingame")
  local okT, hours = pcall(os.time, "ingame")
  if not okD or type(day) ~= "number" then day = 1 end
  if not okT or type(hours) ~= "number" then hours = 0 end
  local h = floor(hours)
  local m = floor((hours - h) * 60)
  local s = floor(((hours - h) * 60 - m) * 60)
  return { day = day, hour = h, minute = m, second = s, text = ("Day %d %02d:%02d"):format(day, h, m) }
end

return M
