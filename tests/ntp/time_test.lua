-- SPDX-License-Identifier: AGPL-3.0-or-later
local time = require("tsr.time")
local vfs = require("tsr.vfs")

local function fresh()
  time.statePath = "/tmp-time-state.json"
  if fs.exists(time.statePath) then fs.delete(time.statePath) end
  time.reload()
  time.clock = function() return os.epoch("utc") end
end

test("calendar arithmetic: epoch, leap years, weekdays, a known instant", function()
  eq(time.timegm(1970, 1, 1), 0)
  eq(time.timegm(2000, 3, 1) - time.timegm(2000, 2, 28), 2 * 86400, "2000 is a leap year")
  eq(time.timegm(2100, 3, 1) - time.timegm(2100, 2, 28), 86400, "2100 is not")
  local y, m, d, h, mi, s, wd, yday = time.fields(1700000000)
  eq({ y, m, d, h, mi, s, wd, yday }, { 2023, 11, 14, 22, 13, 20, 2, 318 })
  eq(select(7, time.fields(time.timegm(2024, 2, 29))), 4, "29 Feb 2024 is a Thursday")
  y, m, d = time.fields(-86400)
  eq({ y, m, d }, { 1969, 12, 31 })
  for _, t in ipairs({ 0, 951782400, 1700000000, 4102444800, 253402300799 }) do
    local fy, fm, fd, fh, fmi, fs2 = time.fields(t)
    eq(time.timegm(fy, fm, fd, fh, fmi, fs2), t)
  end
end)

test("every built-in zone matches the real tz database around every daylight saving change 2024-2030", function()
  local vectors = dofile("/tests/fixtures/tz_vectors.lua")
  local checked, bad, badZones = 0, {}, {}
  for _, z in ipairs(vectors) do
    local zone = assert(time.zone(z.zone), z.zone)
    for _, p in ipairs(z.points) do
      local off = time.offsetAt(zone, p[1])
      checked = checked + 1
      if off ~= p[2] then
        bad[#bad + 1] = ("%s at %d: got %d want %d"):format(z.zone, p[1], off, p[2])
        badZones[z.zone] = true
      end
    end
  end
  ok(checked > 2000, "checked " .. checked)
  local names = {}
  for n in pairs(badZones) do names[#names + 1] = n end
  table.sort(names)
  eq(#bad, 0, "zones that differ: " .. table.concat(names, ", ") .. " | " .. table.concat(bad, " ; ", 1, math.min(#bad, 3)))
end)

test("zone names: full names, short names, aliases, fixed offsets", function()
  eq(time.zone("Europe/Berlin").offset, 60)
  eq(time.zone("berlin").name, "Europe/Berlin")
  eq(time.zone("europe/berlin").name, "Europe/Berlin")
  eq(time.zone("EST").name, "America/New_York")
  eq(time.zone("UTC+5").offset, 300)
  eq(time.zone("UTC-03:30").offset, -210)
  eq(time.zone("GMT+2").offset, 120)
  eq(time.zone("+0530").offset, 330)
  eq(time.zone("Mars/Olympus"), nil)
  eq(time.zone(""), nil)
  ok(#time.zoneNames() > 40)
  local ok1 = time.zone("UTC+15")
  eq(ok1, nil, "beyond +14:00 is not a zone")
end)

test("format: strftime fields in several zones", function()
  local ms = time.timegm(2026, 7, 4, 15, 5, 9) * 1000
  local utc, ny, berlin = time.zone("UTC"), time.zone("America/New_York"), time.zone("Europe/Berlin")
  eq(time.format("%Y-%m-%d %H:%M:%S", ms, utc), "2026-07-04 15:05:09")
  eq(time.format("%F %T %Z %z", ms, ny), "2026-07-04 11:05:09 EDT -0400")
  eq(time.format("%H:%M %Z", ms, berlin), "17:05 CEST")
  eq(time.format("%a %A %b %B %e %j", ms, utc), "Sat Saturday Jul July  4 185")
  eq(time.format("%I:%M %p", ms, utc), "03:05 PM")
  eq(time.format("%I %p", time.timegm(2026, 1, 1, 0, 0, 0) * 1000, utc), "12 AM")
  eq(time.format("%s", ms, utc), tostring(ms / 1000))
  eq(time.format("100%% %q", ms, utc), "100% %q")
  eq(time.iso(ms), "2026-07-04T15:05:09Z")
  eq(time.stamp(ms, berlin), "2026-07-04 17:05:09 CEST")
end)

test("parse: several forms, zones, offsets and mistakes", function()
  local berlin = time.zone("Europe/Berlin")
  eq(time.parse("2026-10-02 14:30:00", "UTC"), time.timegm(2026, 10, 2, 14, 30, 0) * 1000)
  eq(time.parse("2026-10-02 14:30", berlin), time.timegm(2026, 10, 2, 12, 30, 0) * 1000, "CEST is +2")
  eq(time.parse("2026-01-02 14:30", berlin), time.timegm(2026, 1, 2, 13, 30, 0) * 1000, "CET is +1")
  eq(time.parse("2026-10-02T14:30:00Z", berlin), time.timegm(2026, 10, 2, 14, 30, 0) * 1000)
  eq(time.parse("2026-10-02T14:30:00+05:30", "UTC"), time.timegm(2026, 10, 2, 9, 0, 0) * 1000)
  eq(time.parse("2026-10-02 14:30:00 America/New_York", "UTC"), time.timegm(2026, 10, 2, 18, 30, 0) * 1000)
  eq(time.parse("2026-10-02", "UTC"), time.timegm(2026, 10, 2, 0, 0, 0) * 1000)
  eq(time.parse("@1700000000"), 1700000000000)
  local rt = time.parse(time.stamp(1700000000000, berlin):gsub(" CET$", ""), berlin)
  eq(rt, 1700000000000, "format then parse round-trips")
  local bad, why = time.parse("tomorrow-ish")
  ok(bad == nil and why:find("cannot read", 1, true), tostring(why))
  bad, why = time.parse("2026-13-40 10:00")
  ok(bad == nil and why:find("not a real", 1, true), tostring(why))
  bad, why = time.parse("2026-02-30 10:00")
  ok(bad == nil)
  bad, why = time.parse("2026-10-02 10:00 Narnia/Cair")
  ok(bad == nil and why:find("unknown time zone", 1, true))
end)

test("the system clock: correction, manual mode, zone, persistence", function()
  fresh()
  local fake = 1000000000000
  time.clock = function() return fake end
  eq(time.now(), fake)
  time.setOffset(2500, { mode = "auto", source = "peer a", stratum = 2 })
  eq(time.now(), fake + 2500)
  eq(time.state().source, "peer a")
  fake = fake + 1000
  eq(time.now(), fake + 2500, "the correction keeps applying as the host clock advances")
  ok(fs.exists(time.statePath))
  time.reload()
  eq(time.offset(), 2500, "persisted")
  time.setNow(time.timegm(2030, 1, 1) * 1000)
  eq(time.now(), time.timegm(2030, 1, 1) * 1000)
  eq(time.state().mode, "manual")
  time.auto()
  eq(time.state().mode, "auto")
  local z = time.setZone("Europe/Berlin")
  eq(z.name, "Europe/Berlin")
  eq(time.zoneName(), "Europe/Berlin")
  ok(select(2, time.setZone("Nowhere")) ~= nil)
  time.reload()
  eq(time.zoneName(), "Europe/Berlin", "the zone is persisted too")
  fresh()
end)

test("the in-game clock is readable", function()
  local g = time.ingame()
  ok(type(g.day) == "number" and g.hour >= 0 and g.hour < 24 and g.minute >= 0 and g.minute < 60)
  ok(g.text:match("^Day %d+ %d%d:%d%d$"), g.text)
end)
