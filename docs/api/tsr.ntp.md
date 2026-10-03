# tsr.ntp

Package: `ntp`

Time synchronisation for Tessera computers.

Where a computer gets its time (config /etc/tsr/ntp.cfg, tried in order, the first source that answers wins):
  { type = "local" }                          the host's own clock (the game server's UTC): offset 0, stratum 1     (the default)
  { type = "peer", host = "ntp1" }            an in-game time server (a computer running `ntp serve on`), see tsr.ntp.proto
  { type = "udp", host = "ntp.lan" }          an NTP server on the in-game IP network (UDP 123, package inet), see tsr.ntp.udp
  { type = "http", kind = "json"|"header", url = "https://..." }   real-world UTC from the web (opt-in, read-only, see tsr.ntp.web)
or by hand: `ntp set <time>` makes this computer's clock whatever you say (a manual setting is also what in-game time servers can
hand out, e.g. for a role-play calendar) until `ntp auto`.

Discipline: a measured correction bigger than `step` (default 0.5 s) is applied at once, a smaller one only half (smoothing the
noise of a 50 ms tick network). A correction bigger than `panic` (default 1 hour) after the first sync is refused as suspicious
unless forced: a lying time server must not be able to throw a base's schedules around.

## `M.config()`

The configuration with defaults filled in.

## `M.identity()`

What to tell clients about this computer: stratum and reference id.

## `M.sampleSource(src, opts)`

Obtain one sample from a source. opts: node (a tsr.net node), get (HTTP fetcher), clock, force. Returns sample or nil + reason.

## `M.apply(sample, src, force)`

Apply a measured correction with the step/slew policy. Returns "step", "slew", "refused" or "none", plus a note.

## `M.sync(opts)`

Synchronise once. opts: node, get, clock, force. Returns { ok, how, source, offset, delay, stratum } or { ok = false, error }.

## `M.serve(node)`

The time server part: answer queries from other computers (needs the net package).

## `M.daemon()`

The ntpd service: sync now, then every `poll` seconds (backing off while sources are unreachable); serve time if configured.
