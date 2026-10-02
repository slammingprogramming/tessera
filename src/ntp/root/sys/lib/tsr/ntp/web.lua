-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Real-world UTC from the web, for computers whose host clock cannot be trusted. Optional and polite: it needs `http` to be
-- enabled, it is asked at most every 10 minutes per URL, and it only ever READS a time (nothing about this computer is sent).
-- Two ways to read a clock:
--   kind "json"    a time API answering with JSON that has "utc_datetime" (ISO 8601, with fractions) or "unixtime" (seconds)
--   kind "header"  the Date header (RFC 7231, whole seconds) of any HTTPS page: coarse, but works with almost any site
-- The offset is corrected by half the round trip time. Accuracy: a few hundred milliseconds with JSON, about a second with Date headers.
local time = require("tsr.time")

local M = {}

M.MIN_INTERVAL_MS = 10 * 60 * 1000
M.DEFAULTS = {
  { type = "http", kind = "json", url = "https://worldtimeapi.org/api/timezone/Etc/UTC" },
  { type = "http", kind = "header", url = "https://github.com" },
}

local lastAsk = {}

local MONTHS = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

--- "Fri, 02 Oct 2026 14:30:00 GMT" -> UTC milliseconds, or nil.
function M.parseHttpDate(text)
  local d, mon, y, h, mi, s = tostring(text or ""):match("(%d+) (%a%a%a) (%d%d%d%d) (%d%d):(%d%d):(%d%d)")
  if not d or not MONTHS[mon] then return nil end
  return time.timegm(tonumber(y), MONTHS[mon], tonumber(d), tonumber(h), tonumber(mi), tonumber(s)) * 1000
end

--- "2026-10-02T12:30:05.123456+00:00" -> UTC milliseconds, or nil.
function M.parseIso(text)
  local y, mo, d, h, mi, s, frac, sign, th, tm = tostring(text or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(%.?%d*)([Zz+-]?)(%d?%d?):?(%d?%d?)$")
  if not y then return nil end
  local ms = time.timegm(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)) * 1000
  if frac ~= "" then ms = ms + math.floor(tonumber("0" .. frac) * 1000) end
  if (sign == "+" or sign == "-") and th ~= "" then
    local off = (tonumber(th) * 60 + (tonumber(tm) or 0)) * 60000
    ms = ms - (sign == "-" and -off or off)
  end
  return ms
end

local function header(headers, name)
  for k, v in pairs(headers or {}) do
    if tostring(k):lower() == name then return v end
  end
end

--- Default fetcher: http.get with a timeout. Returns body, headers or nil + reason.
local function defaultGet(url)
  if not rawget(_G, "http") then return nil, nil, "HTTP is disabled on this computer" end
  local ok, why = http.checkURL(url)
  if not ok then return nil, nil, "URL not allowed: " .. tostring(why) end
  local h, err = http.get({ url = url, timeout = 10, binary = true })
  if not h then return nil, nil, tostring(err) end
  local body = h.readAll()
  local headers = h.getResponseHeaders and h.getResponseHeaders() or {}
  h.close()
  return body, headers
end

--- One time reading from `src` ({ url, kind }). opts: get (function(url) -> body, headers | nil, nil, err), clock (raw UTC ms), force (ignore the rate limit).
--- Returns { offset, delay, stratum = 2, refid, host, authenticated = true } or nil + reason. offset: what to add to the raw clock.
function M.sample(src, opts)
  opts = opts or {}
  local clock = opts.clock or time.clock
  local nowMs = clock()
  if not opts.force and lastAsk[src.url] and nowMs - lastAsk[src.url] < M.MIN_INTERVAL_MS then return nil, "asked recently; waiting (be polite to web services)" end
  lastAsk[src.url] = nowMs
  local t1 = clock()
  local body, headers, err = (opts.get or defaultGet)(src.url)
  local t4 = clock()
  if not body and not headers then return nil, tostring(err or "no answer") end
  local serverMs, resolution
  if src.kind == "json" then
    local doc = textutils.unserializeJSON(body or "")
    if type(doc) ~= "table" then return nil, "the page is not JSON" end
    serverMs = M.parseIso(doc.utc_datetime or doc.datetime or "")
    resolution = 50
    if not serverMs and tonumber(doc.unixtime) then serverMs, resolution = tonumber(doc.unixtime) * 1000 + 500, 500 end   -- whole seconds: the middle of that second
  else
    local date = header(headers, "date")
    serverMs = M.parseHttpDate(date)
    resolution = 500
    if serverMs then serverMs = serverMs + 500 end
  end
  if not serverMs then return nil, "could not read a time from " .. src.url end
  local delay = t4 - t1
  local host = src.url:match("^https?://([^/]+)") or src.url
  return { offset = serverMs + delay / 2 - t4, delay = delay, stratum = 2, refid = "WEB", host = host, authenticated = true, resolution = resolution }
end

--- Forget rate-limit memory (tests).
function M.reset() lastAsk = {} end

return M
