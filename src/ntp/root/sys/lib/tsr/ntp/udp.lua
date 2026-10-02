-- SPDX-License-Identifier: AGPL-3.0-or-later
-- NTP version 4 over UDP port 123 (RFC 5905 packet format), for networks that run the IP stack (package inet). Same maths as the in-game protocol:
--   offset = ((T2 - T1) + (T3 - T4)) / 2        delay = (T4 - T1) - (T3 - T2)
-- Servers answer every computer that asks, but ask clients to slow down ("RATE", the kiss-o'-death of RFC 5905) when they send too often, and say
-- stratum 16 (unsynchronised) when they do not know the time themselves.
local B = require("tsr.inet.bytes")

local M = {}

M.PORT = 123
M.EPOCH_OFFSET = 2208988800          -- seconds between 1900 (NTP) and 1970 (Unix)
M.MIN_INTERVAL = 1                   -- seconds between queries of one client before RATE is sent

--- Milliseconds since 1970 -> 8-byte NTP timestamp (32 bits seconds, 32 bits fraction).
function M.toNtp(ms)
  local sec = math.floor(ms / 1000) + M.EPOCH_OFFSET
  local frac = math.floor((ms % 1000) / 1000 * 4294967296)
  return B.u32(sec) .. B.u32(frac)
end

function M.fromNtp(s, pos)
  pos = pos or 1
  local sec, frac = B.rd32(s, pos), B.rd32(s, pos + 4)
  return ((sec - M.EPOCH_OFFSET) + frac / 4294967296) * 1000
end

--- Build a packet. p: mode (3 client, 4 server), stratum, poll, precision, rootDelay, rootDispersion (ms), refid (4 chars or number), reference, origin, receive, transmit (ms).
function M.encode(p)
  local li = p.leap or (p.stratum == 16 and 3 or 0)
  local refid = p.refid
  if type(refid) == "number" then refid = B.u32(refid) else refid = ((refid or "") .. "\0\0\0\0"):sub(1, 4) end
  local function ts(v) return v and M.toNtp(v) or string.rep("\0", 8) end
  return string.char(li * 64 + 4 * 8 + (p.mode or 3), p.stratum or 0, p.poll or 6, (p.precision or -10) % 256)
    .. B.u32(math.floor((p.rootDelay or 0) / 1000 * 65536)) .. B.u32(math.floor((p.rootDispersion or 0) / 1000 * 65536)) .. refid
    .. ts(p.reference) .. ts(p.origin) .. ts(p.receive) .. ts(p.transmit)
end

function M.decode(data)
  if #data < 48 then return nil, "short NTP packet" end
  local b = data:byte(1)
  local p = { leap = math.floor(b / 64), version = math.floor(b / 8) % 8, mode = b % 8, stratum = data:byte(2), poll = data:byte(3), refidRaw = data:sub(13, 16) }
  p.refid = p.stratum <= 1 and (data:sub(13, 16):gsub("%z+$", "")) or B.ipStr(B.rd32(data, 13))
  local function ts(pos)
    if data:sub(pos, pos + 7) == string.rep("\0", 8) then return nil end
    return M.fromNtp(data, pos)
  end
  p.reference, p.origin, p.receive, p.transmit = ts(17), ts(25), ts(33), ts(41)
  p.originRaw = data:sub(25, 32)
  return p
end

---------------------------------------------------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------------------------------------------------

--- One exchange. opts: clock (function -> raw UTC ms), timeout (2). Returns { offset, delay, stratum, refid, host } or nil + reason.
function M.query(stack, host, opts)
  opts = opts or {}
  local socket = require("tsr.inet.socket")
  local clock = opts.clock or function() return os.epoch("utc") end
  local ip, why = stack:resolve(host, 3)
  if not ip then return nil, why end
  local u = socket.udp(stack)
  u:connect(B.ipStr(ip), M.PORT)
  local t1 = clock()
  local sent = u:send(M.encode({ mode = 3, stratum = 0, transmit = t1 }))
  if not sent then u:close() return nil, "cannot send" end
  local deadline = stack.clock() + (opts.timeout or 2)
  while true do
    local left = deadline - stack.clock()
    if left <= 0 then u:close() return nil, "no answer from " .. host end
    local data, from, port = u:receivefrom(left)
    if not data then u:close() return nil, from == "connection refused" and "nothing listens for time on " .. host or "no answer from " .. host end
    local t4 = clock()
    local p = M.decode(data)
    if p and p.mode == 4 and p.originRaw == M.toNtp(t1) then
      u:close()
      if p.stratum == 0 then return nil, "the server asked us to slow down (" .. tostring(p.refid) .. ")" end
      if p.stratum >= 16 or p.leap == 3 then return nil, "the server is not synchronised itself" end
      local t2, t3 = p.receive, p.transmit
      return { offset = ((t2 - t1) + (t3 - t4)) / 2, delay = (t4 - t1) - (t3 - t2), stratum = p.stratum, refid = p.refid, host = host, authenticated = false }
    end
  end
end

--- Several queries; the one with the least delay wins. opts: samples (4), spacing (0.3 s), plus those of query.
function M.measure(stack, host, opts)
  opts = opts or {}
  local best, lastErr
  for i = 1, opts.samples or 4 do
    local s, err = M.query(stack, host, opts)
    if s then if not best or s.delay < best.delay then best = s end else lastErr = err end
    if i < (opts.samples or 4) then stack.wait(function() return false end, opts.spacing or 1.1) end
  end
  if not best then return nil, lastErr or "no answer" end
  return best
end

---------------------------------------------------------------------------------------------------------------------
-- Server
---------------------------------------------------------------------------------------------------------------------

--- Answer queries on UDP 123 until opts.stop. opts: clock (function -> UTC ms), stratum (function), refid (function -> text or IP number), allow (list of CIDR strings; default everybody).
--- Returns a function to run (a worker).
function M.server(stack, opts)
  opts = opts or {}
  local socket = require("tsr.inet.socket")
  local clock = opts.clock or function() return os.epoch("utc") end
  local allow
  if opts.allow then
    allow = {}
    for _, c in ipairs(opts.allow) do local n, l = B.cidr(c) if n then allow[#allow + 1] = { n, l } end end
  end
  local last = {}
  local state = { served = 0, limited = 0, refused = 0 }
  state.run = function()
    local u = socket.udp(stack)
    assert(u:bind(nil, M.PORT))
    state.socket = u
    while not state.stop do
      local data, ip, port = u:receivefrom(1)
      if data then
        local t2 = clock()
        local p = M.decode(data)
        local src = B.ip(ip)
        if p and p.mode == 3 and p.transmit then
          local permitted = true
          if allow then
            permitted = false
            for _, n in ipairs(allow) do if B.inNet(src, n[1], n[2]) then permitted = true end end
          end
          if not permitted then
            state.refused = state.refused + 1
          elseif last[ip] and stack.clock() - last[ip] < M.MIN_INTERVAL then
            state.limited = state.limited + 1
            u:sendto(M.encode({ mode = 4, stratum = 0, refid = "RATE", origin = p.transmit, transmit = clock() }), ip, port)
          else
            last[ip] = stack.clock()
            local stratum = opts.stratum and opts.stratum() or 1
            local refid = opts.refid and opts.refid() or "LOCL"
            local reply = M.encode({ mode = 4, stratum = stratum, refid = refid, reference = t2, origin = p.transmit, receive = t2, transmit = clock() })
            -- the origin must be echoed bit for bit: take it from the request
            reply = reply:sub(1, 24) .. data:sub(41, 48) .. reply:sub(33)
            u:sendto(reply, ip, port)
            state.served = state.served + 1
          end
        end
      end
    end
    u:close()
  end
  return state
end

return M
