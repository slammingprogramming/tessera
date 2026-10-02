-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The in-game time protocol, after NTP: a client stamps a request (T1), the server stamps its arrival (T2) and its reply (T3), the
-- client stamps the arrival of the reply (T4). From the four times:
--     offset = ((T2 - T1) + (T3 - T4)) / 2        delay = (T4 - T1) - (T3 - T2)
-- Several samples are taken and the one with the smallest delay wins (the least disturbed one, as in NTP's clock filter).
--
-- Servers answer in two ways: to computers PAIRED with them through the authenticated call "ntp.query" (forged or replayed answers are
-- impossible, see tsr.net), and, if `open` is on (default), to anybody through the plain message "ntp.q" (like classic NTP: fine for
-- a trusted base network, spoofable by a hostile one). A client uses the authenticated way whenever it is paired.
-- Accuracy in the game: Minecraft delivers network events once per game tick (50 ms), so expect an error of a few tens of milliseconds.
local log = require("tsr.log").get("ntp")

local M = {}

M.MIN_INTERVAL = 0.5          -- seconds between queries from one computer before a server ignores it

local function sample(t1, t2, t3, t4)
  return { offset = ((t2 - t1) + (t3 - t4)) / 2, delay = (t4 - t1) - (t3 - t2) }
end
M.sample = sample

--- Serve time on `node`. opts: clock (function -> corrected UTC ms), stratum (function -> number), refid (function -> text), open (bool).
function M.serve(node, opts)
  opts = opts or {}
  local clock = opts.clock or function() return os.epoch("utc") end
  local last = {}
  local function answer(from, t1)
    local now = os.clock()
    if last[from] and now - last[from] < M.MIN_INTERVAL then return nil end      -- too many requests: stay quiet
    last[from] = now
    local t2 = clock()
    local stratum = opts.stratum and opts.stratum() or 1
    local refid = opts.refid and opts.refid() or "LOCL"
    return { t1 = t1, t2 = t2, t3 = clock(), stratum = stratum, refid = refid, host = node.hostname }
  end
  node:serve("ntp", function(from, method, a)
    if method ~= "query" or type(a) ~= "table" or type(a.t1) ~= "number" then error("expected query { t1 }", 0) end
    local r = answer(from, a.t1)
    if not r then error("too many requests", 0) end
    r.t3 = clock()
    return r
  end)
  node.handlers = node.handlers or {}
  if opts.open ~= false then
    node.handlers["ntp.q"] = function(self, from, msg)
      if type(msg.t1) ~= "number" or type(msg.q) ~= "string" then return end
      local r = answer(from, msg.t1)
      if not r then return end
      r.t = "ntp.r"
      r.q = msg.q
      self:send(from, r)
    end
  else
    node.handlers["ntp.q"] = nil
  end
end

--- Ask `target` (computer id, name or peer name) for the time once. opts: clock (function -> raw UTC ms), timeout, auth (true: only
--- authenticated, false: only plain, nil: authenticated when paired). Returns { offset, delay, stratum, refid, host, authenticated } or nil + reason.
function M.query(node, target, opts)
  opts = opts or {}
  local clock = opts.clock or function() return os.epoch("utc") end
  local timeout = opts.timeout or 3
  local peer = node:peer(target)
  local useAuth = opts.auth
  if useAuth == nil then useAuth = peer ~= nil end
  if useAuth and not peer then return nil, "not paired with " .. tostring(target) .. " (authenticated time needs `net pair`)" end

  if useAuth then
    local t1 = clock()
    local res, err = node:call(peer.id, "ntp", "query", { t1 = t1 }, { timeout = timeout })
    local t4 = clock()
    if not res then return nil, err end
    if type(res.t2) ~= "number" or type(res.t3) ~= "number" then return nil, "malformed answer" end
    local s = sample(t1, res.t2, res.t3, t4)
    s.stratum, s.refid, s.host, s.authenticated = res.stratum or 16, res.refid or "?", res.host or peer.name, true
    return s
  end

  local id, rerr = node:resolve(target, timeout)
  if not id then return nil, rerr end
  local q = tostring(math.floor(os.clock() * 1000)) .. tostring(math.random(1000000))
  local t1 = clock()
  node:send(id, { t = "ntp.q", q = q, t1 = t1 })
  local reply = node:await(id, function(m) return m.t == "ntp.r" and m.q == q end, timeout)
  local t4 = clock()
  if not reply then return nil, "no answer from " .. tostring(target) end
  if reply.t1 ~= t1 or type(reply.t2) ~= "number" or type(reply.t3) ~= "number" then return nil, "malformed answer" end
  local s = sample(t1, reply.t2, reply.t3, t4)
  s.stratum, s.refid, s.host, s.authenticated = reply.stratum or 16, reply.refid or "?", reply.host, false
  return s
end

--- Several queries, keep the one with the least delay. opts as for query plus samples (default 4), spacing (seconds, default 0.3).
function M.measure(node, target, opts)
  opts = opts or {}
  local best, lastErr
  for i = 1, opts.samples or 4 do
    local s, err = M.query(node, target, opts)
    if s then
      if not best or s.delay < best.delay then best = s end
    else
      lastErr = err
      if err and tostring(err):find("not paired", 1, true) then break end
    end
    if i < (opts.samples or 4) then sleep(opts.spacing or 0.3) end
  end
  if not best then return nil, lastErr or "no answer" end
  if best.stratum >= 16 then return nil, "the server is not synchronised itself (stratum " .. best.stratum .. ")" end
  return best
end

return M
