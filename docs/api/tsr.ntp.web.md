# tsr.ntp.web

Package: `ntp`

Real-world UTC from the web, for computers whose host clock cannot be trusted. Optional and polite: it needs `http` to be
enabled, it is asked at most every 10 minutes per URL, and it only ever READS a time (nothing about this computer is sent).
Two ways to read a clock:
  kind "json"    a time API answering with JSON that has "utc_datetime" (ISO 8601, with fractions) or "unixtime" (seconds)
  kind "header"  the Date header (RFC 7231, whole seconds) of any HTTPS page: coarse, but works with almost any site
The offset is corrected by half the round trip time. Accuracy: a few hundred milliseconds with JSON, about a second with Date headers.

## `M.parseHttpDate(text)`

"Fri, 02 Oct 2026 14:30:00 GMT" -> UTC milliseconds, or nil.

## `M.parseIso(text)`

"2026-10-02T12:30:05.123456+00:00" -> UTC milliseconds, or nil.

## `M.sample(src, opts)`

One time reading from `src` ({ url, kind }). opts: get (function(url) -> body, headers | nil, nil, err), clock (raw UTC ms), force (ignore the rate limit).
Returns { offset, delay, stratum = 2, refid, host, authenticated = true } or nil + reason. offset: what to add to the raw clock.

## `M.reset()`

Forget rate-limit memory (tests).
