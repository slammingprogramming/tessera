# tsr.time

Package: `ntp`

The system clock of a Tessera computer: UTC from the host (os.epoch) plus a correction that time synchronisation maintains,
time zones with daylight saving rules, date formatting and parsing, and the in-game (Minecraft) clock.

  time.now()            UTC milliseconds since 1970, corrected         time.utc()    the same in seconds
  time.format("%Y-%m-%d %H:%M:%S %Z", ms [, zone])                      time.parse("2026-10-02 14:30:00" [, zone]) -> ms
  time.zone("Europe/Berlin")  time.setZone(...)  time.zoneName()        time.ingame() -> { day, hour, minute, second }
  time.setOffset(ms, info)  time.offset()  time.state()                 (used by tsr.ntp and the date command)

Time zones: a compact built-in table of well known zones with their current daylight saving rule (US, EU, Australia, New Zealand,
none), plus "UTC+5" / "UTC-03:30" forms. Past years' rule changes are not modelled: this is for running a base, not for genealogy.

## `M.timegm(y, m, d, hh, mm, ss)`

Seconds since 1970 (UTC) of a calendar date and time.

## `M.fields(sec)`

Calendar fields of UTC seconds: year, month, day, hour, minute, second, weekday (0 = Sunday), day of year.

## `M.zoneNames()`

Names of the built-in zones, sorted.

## `M.zone(name)`

A zone from a name ("Europe/Berlin", "berlin", "CET") or a fixed offset ("UTC+5", "GMT-03:30", "+0530"). Returns zone table or nil.

## `M.offsetAt(zone, utcSec)`

Offset from UTC in minutes at an instant, with the abbreviation and whether daylight saving applies.

## `M.reload()`

Forget the in-memory state (tests; also after another process changed the file).

## `M.now()`

Corrected UTC time in milliseconds.

## `M.utc()`

Corrected UTC time in seconds (fractions kept).

## `M.offset()`

The correction currently applied to the host clock, in milliseconds.

## `M.state()`

Everything known about the synchronisation: { offset, mode, source, stratum, delay, jitter, last, zone }.

## `M.setOffset(ms, info)`

Set the correction. info: mode, source, stratum, delay, jitter. Persists.

## `M.setNow(utcMs)`

Make the clock show `utcMs` right now (manual set, like date -s). Switches to manual mode until `auto`.

## `M.auto()`

Back to automatic synchronisation (drops a manual setting).

## `M.currentZone()`

The configured zone table (default UTC).

## `M.format(fmt, ms, zone)`

strftime-style formatting of UTC milliseconds in `zone` (zone table or name; default the system zone).
Supports %Y %y %m %d %e %H %I %M %S %p %a %A %b %B %j %Z %z %s %F %T %D %R %c %x %X %%.

## `M.stamp(ms, zone)`

Default human readable form: "2026-10-02 14:30:05 CEST".

## `M.iso(ms)`

ISO 8601 in UTC: "2026-10-02T12:30:05Z".

## `M.parse(text, zone)`

Parse a date/time. Accepts "YYYY-MM-DD HH:MM[:SS]", "YYYY-MM-DDTHH:MM[:SS](Z|+hh:mm)", "YYYY-MM-DD", "HH:MM[:SS]" (today) and "@seconds".
Naive times are read in `zone`. Returns UTC milliseconds or nil + reason.

## `M.ingame()`

Minecraft's clock: day number and time of day (a game day lasts 20 real minutes). Returns { day, hour, minute, second, text }.
