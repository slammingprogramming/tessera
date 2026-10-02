-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Time synchronisation for Tessera computers.
--
-- Where a computer gets its time (config /etc/tsr/ntp.cfg, tried in order, the first source that answers wins):
--   { type = "local" }                          the host's own clock (the game server's UTC): offset 0, stratum 1     (the default)
--   { type = "peer", host = "ntp1" }            an in-game time server (a computer running `ntp serve on`), see tsr.ntp.proto
--   { type = "udp", host = "ntp.lan" }          an NTP server on the in-game IP network (UDP 123, package inet), see tsr.ntp.udp
--   { type = "http", kind = "json"|"header", url = "https://..." }   real-world UTC from the web (opt-in, read-only, see tsr.ntp.web)
-- or by hand: `ntp set <time>` makes this computer's clock whatever you say (a manual setting is also what in-game time servers can
-- hand out, e.g. for a role-play calendar) until `ntp auto`.
--
-- Discipline: a measured correction bigger than `step` (default 0.5 s) is applied at once, a smaller one only half (smoothing the
-- noise of a 50 ms tick network). A correction bigger than `panic` (default 1 hour) after the first sync is refused as suspicious
-- unless forced: a lying time server must not be able to throw a base's schedules around.
local time = require("tsr.time")
local proto = require("tsr.ntp.proto")
local web = require("tsr.ntp.web")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("ntp")

local M = { proto = proto, web = web, time = time }

M.CONFIG = "/etc/tsr/ntp.cfg"

--- The configuration with defaults filled in.
function M.config()
  local c = vfs.readTable(M.CONFIG) or {}
  c.servers = c.servers or { { type = "local" } }
  c.poll = c.poll or 600
  c.step = c.step or 500
  c.panic = c.panic or 3600000
  if c.serve == nil then c.serve = false end
  if c.open == nil then c.open = true end
  return c
end

function M.saveConfig(c) return vfs.writeTable(M.CONFIG, c) end

--- What to tell clients about this computer: stratum and reference id.
function M.identity()
  local s = time.state()
  if s.mode == "manual" then return 1, "MANU" end
  if s.stratum then return s.stratum, s.refid or "SYNC" end
  return 1, "LOCL"
end

--- Obtain one sample from a source. opts: node (a tsr.net node), get (HTTP fetcher), clock, force. Returns sample or nil + reason.
function M.sampleSource(src, opts)
  opts = opts or {}
  if src.type == "local" then
    return { offset = 0, delay = 0, stratum = 1, refid = "LOCL", host = "this computer", authenticated = true }
  elseif src.type == "peer" then
    local node = opts.node
    if not node then
      local ok, net = pcall(require, "tsr.net")
      if not ok then return nil, "the net package is not installed" end
      node = net.default()
    end
    local s, err = proto.measure(node, src.host, { clock = opts.clock or time.clock, auth = src.auth, samples = src.samples or 4, timeout = opts.timeout })
    if not s then return nil, err end
    s.stratum = s.stratum + 1
    return s
  elseif src.type == "udp" then
    -- real NTPv4 over UDP 123 on the in-game IP network (package inet)
    local okI, socket = pcall(require, "tsr.inet.socket")
    if not okI then return nil, "the inet package is not installed" end
    local okS, stack = pcall(socket.default)
    if not okS then return nil, "the network stack is not running" end
    local s, err = require("tsr.ntp.udp").measure(stack, src.host, { clock = opts.clock or time.clock, samples = src.samples or 3, timeout = opts.timeout })
    if not s then return nil, err end
    s.stratum = s.stratum + 1
    return s
  elseif src.type == "http" then
    return web.sample(src, opts)
  end
  return nil, "unknown source type " .. tostring(src.type)
end

--- Apply a measured correction with the step/slew policy. Returns "step", "slew", "refused" or "none", plus a note.
function M.apply(sample, src, force)
  local c = M.config()
  local s = time.state()
  local current = s.offset or 0
  local delta = sample.offset - current
  if s.last and not force and math.abs(delta) > c.panic then
    return "refused", ("the correction of %.1f s is bigger than the panic limit (%.0f s): not applied (use `ntp sync --force` if it is right)"):format(delta / 1000, c.panic / 1000)
  end
  local how, newOffset
  if math.abs(delta) >= c.step or not s.last or s.source == "manual" then how, newOffset = "step", sample.offset
  else how, newOffset = "slew", current + delta / 2 end
  time.setOffset(newOffset, { mode = "auto", source = src.type == "peer" and src.host or (src.url or src.type), stratum = sample.stratum, refid = sample.refid, delay = sample.delay, measured = sample.offset })
  return how
end

--- Synchronise once. opts: node, get, clock, force. Returns { ok, how, source, offset, delay, stratum } or { ok = false, error }.
function M.sync(opts)
  opts = opts or {}
  if time.state().mode == "manual" and not opts.force then
    return { ok = false, error = "the clock was set by hand (manual mode); use `ntp auto` first" }
  end
  local c = M.config()
  local errors = {}
  for _, src in ipairs(c.servers) do
    local sample, err = M.sampleSource(src, opts)
    if sample then
      if time.state().mode == "manual" then time.auto() end
      local how, note = M.apply(sample, src, opts.force)
      if how == "refused" then errors[#errors + 1] = note
      else
        log.info("time sync: %s offset %.0f ms delay %.0f ms stratum %d (%s)", src.host or src.url or src.type, sample.offset, sample.delay, sample.stratum, how)
        return { ok = true, how = how, source = src.host or src.url or src.type, offset = sample.offset, delay = sample.delay, stratum = sample.stratum }
      end
    else
      errors[#errors + 1] = (src.host or src.url or src.type) .. ": " .. tostring(err)
    end
  end
  return { ok = false, error = table.concat(errors, "; ") }
end

--- The time server part: answer queries from other computers (needs the net package).
function M.serve(node)
  proto.serve(node, {
    clock = time.now,
    stratum = function() return (M.identity()) end,
    refid = function() return select(2, M.identity()) end,
    open = M.config().open,
  })
end

--- The ntpd service: sync now, then every `poll` seconds (backing off while sources are unreachable); serve time if configured.
function M.daemon()
  local c = M.config()
  if c.serve then
    local ok, net = pcall(require, "tsr.net")
    if ok then M.serve(net.default()) log.info("serving time to the network") end
  end
  if c.serveUdp then
    -- also answer NTP queries on the IP network (UDP 123)
    local okI, socket = pcall(require, "tsr.inet.socket")
    if okI then
      local okS, stack = pcall(socket.default)
      if okS then
        local server = require("tsr.ntp.udp").server(stack, { clock = time.now, stratum = function() return (M.identity()) end, refid = function() return select(2, M.identity()) end, allow = c.allow })
        log.info("serving time on UDP 123")
        return parallel.waitForAny(server.run, function() M.pollLoop(c) end)
      end
    end
  end
  M.pollLoop(c)
end

function M.pollLoop(c)
  local interval = c.poll
  while true do
    c = M.config()
    local res = M.sync({})
    if res.ok then interval = c.poll
    else
      if not (res.error or ""):find("manual mode", 1, true) then log.warn("time sync failed: %s", tostring(res.error)) end
      interval = math.min((interval or c.poll) * 2, 3600)
    end
    sleep(interval)
  end
end

return M
