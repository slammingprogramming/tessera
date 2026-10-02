-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Sockets, in the style of LuaSocket / BSD sockets, for programs on this computer:
--
--   local socket = require("tsr.inet.socket")
--   local c = socket.tcp()
--   assert(c:connect("mail.example", 25, 10))      -- name (via DNS/hosts) or dotted quad
--   c:send("HELO me\r\n")
--   print(c:receive("*l"))                         -- one line;  c:receive(10) = exactly 10 bytes;  c:receive("*a") = until the peer closes
--   c:close()
--
--   local s = socket.tcp(); s:bind("0.0.0.0", 8080); s:listen(8)
--   local client = s:accept()                      -- blocks (s:settimeout(5) to limit the wait)
--
--   local u = socket.udp(); u:bind(nil, 5000); u:sendto("hi", "10.0.0.2", 5000); local data, ip, port = u:receivefrom(2)
--
-- Every blocking call returns nil + a reason on failure ("timeout", "closed", "connection refused", ...).
local B = require("tsr.inet.bytes")
local tcp = require("tsr.inet.tcp")
local udp = require("tsr.inet.udp")

local M = {}

local defaultStack
function M.setDefault(stack) defaultStack = stack end
function M.default()
  if not defaultStack then error("the network stack is not running (start the inetd service or run `inetd start`)", 0) end
  return defaultStack
end

function M.resolve(host, timeout)
  return M.default():resolve(host, timeout)
end

---------------------------------------------------------------------------------------------------------------------
-- TCP
---------------------------------------------------------------------------------------------------------------------

local TCP = {}
TCP.__index = TCP

function M.tcp(stack)
  return setmetatable({ stack = stack or M.default(), buf = "", timeout = nil, bindAddr = nil, bindPort = nil, options = {} }, TCP)
end

function TCP:settimeout(t) self.timeout = t return true end

function TCP:setoption(name, value)
  self.options[name] = value
  if name == "nodelay" and self.tcb then self.tcb.noDelay = value and true or false end
  if name == "keepalive" and self.tcb then self.tcb.keepalive = value and (type(value) == "number" and value or 60) or nil end
  return true
end

function TCP:bind(addr, port)
  self.bindAddr = addr and B.ip(addr) or 0
  self.bindPort = port
  return true
end

function TCP:connect(host, port, timeout)
  local stack = self.stack
  timeout = timeout or self.timeout or 30
  local ip, why = stack:resolve(host, math.min(timeout, 5))
  if not ip then return nil, why end
  local tcb, err = tcp.connect(stack, ip, port, { src = (self.bindAddr and self.bindAddr ~= 0) and self.bindAddr or nil, sport = self.bindPort, noDelay = self.options.nodelay })
  if not tcb then return nil, err end
  self.tcb = tcb
  local ok = stack.wait(function() return tcb.state ~= "SYN_SENT" and tcb.state ~= "SYN_RCVD" end, timeout)
  if tcb.state == "ESTABLISHED" or tcb.state == "CLOSE_WAIT" then return true end
  local reason = tcb.err or (ok and "connection failed") or "timeout"
  tcp.abort(tcb)
  self.tcb = nil
  return nil, reason
end

function TCP:listen(backlog)
  local tcb, err = tcp.listen(self.stack, self.bindAddr or 0, self.bindPort or 0, backlog)
  if not tcb then return nil, err end
  tcb.noDelay = self.options.nodelay
  self.tcb = tcb
  self.listening = true
  return true
end

function TCP:accept(timeout)
  local tcb = self.tcb
  if not (tcb and self.listening) then return nil, "not listening" end
  timeout = timeout or self.timeout
  if #tcb.acceptQ == 0 then
    self.stack.wait(function() return #tcb.acceptQ > 0 or tcb.state == "CLOSED" end, timeout)
  end
  if #tcb.acceptQ == 0 then return nil, tcb.state == "CLOSED" and "closed" or "timeout" end
  local child = table.remove(tcb.acceptQ, 1)
  local sock = setmetatable({ stack = self.stack, buf = "", timeout = nil, tcb = child, options = {} }, TCP)
  return sock
end

function TCP:send(data, timeout)
  local tcb = self.tcb
  if not tcb then return nil, "not connected" end
  timeout = timeout or self.timeout
  local sent = 0
  local deadline = timeout and (self.stack.clock() + timeout)
  while sent < #data do
    local n, err = tcp.write(tcb, data:sub(sent + 1))
    if not n then return nil, err, sent end
    sent = sent + n
    if sent < #data then
      local left = deadline and math.max(0, deadline - self.stack.clock()) or nil
      local ok = self.stack.wait(function() return #tcb.sendBuf < tcb.sendMax or tcb.state == "CLOSED" or tcb.err ~= nil end, left)
      if not ok then return nil, "timeout", sent end
      if tcb.state == "CLOSED" then return nil, tcb.err or "closed", sent end
    end
  end
  return sent
end

--- Pull whatever the connection has into the local buffer; waits until there is something, the peer closed or the time is up.
local function fill(self, deadline)
  local tcb = self.tcb
  local stack = self.stack
  local function ready() return tcb.rcvLen > 0 or tcb.finRcvd or tcb.state == "CLOSED" or tcb.err ~= nil end
  if not ready() then
    local left = deadline and math.max(0, deadline - stack.clock()) or nil
    stack.wait(ready, left)
  end
  local data, err = tcp.read(tcb, 65536)
  if data and #data > 0 then self.buf = self.buf .. data return true end
  if data == "" then return nil, "timeout" end
  return nil, err or "closed"
end

--- receive(pattern, timeout): a number = exactly that many bytes, "*l" a line without its line end, "*a" everything until the peer closes,
--- "*any" whatever is available (at least one byte).
function TCP:receive(pattern, timeout)
  if not self.tcb then return nil, "not connected" end
  pattern = pattern or "*l"
  timeout = timeout or self.timeout
  local deadline = timeout and (self.stack.clock() + timeout)
  if type(pattern) == "number" then
    while #self.buf < pattern do
      local ok, err = fill(self, deadline)
      if not ok then
        local partial = self.buf
        self.buf = ""
        return nil, err, partial
      end
    end
    local out = self.buf:sub(1, pattern)
    self.buf = self.buf:sub(pattern + 1)
    return out
  elseif pattern == "*l" or pattern == "l" then
    while true do
      local nl = self.buf:find("\n", 1, true)
      if nl then
        local line = self.buf:sub(1, nl - 1)
        self.buf = self.buf:sub(nl + 1)
        return (line:gsub("\r$", ""))
      end
      local ok, err = fill(self, deadline)
      if not ok then
        local partial = self.buf
        self.buf = ""
        return nil, err, partial
      end
    end
  elseif pattern == "*a" or pattern == "a" then
    while true do
      local ok, err = fill(self, deadline)
      if not ok then
        if err == "closed" then local all = self.buf self.buf = "" return all end
        local partial = self.buf
        self.buf = ""
        return nil, err, partial
      end
    end
  elseif pattern == "*any" or pattern == "any" then
    if #self.buf == 0 then
      local ok, err = fill(self, deadline)
      if not ok then return nil, err end
    end
    local out = self.buf
    self.buf = ""
    return out
  end
  return nil, "bad receive pattern"
end

function TCP:shutdown(how)
  if not self.tcb then return nil, "not connected" end
  if how == "send" or how == "both" then tcp.shutdownWrite(self.tcb) end
  return true
end

function TCP:close()
  local tcb = self.tcb
  if not tcb then return true end
  tcp.close(tcb)
  return true
end

--- Abort with a reset instead of an orderly close.
function TCP:reset()
  if self.tcb then tcp.abort(self.tcb) end
  return true
end

function TCP:getpeername()
  local t = self.tcb
  if not t or not t.raddr or t.raddr == 0 then return nil end
  return B.ipStr(t.raddr), t.rport
end

function TCP:getsockname()
  local t = self.tcb
  if not t then return B.ipStr(self.bindAddr or 0), self.bindPort or 0 end
  return B.ipStr(t.laddr), t.lport
end

function TCP:state() return self.tcb and self.tcb.state or "CLOSED" end
function TCP:error() return self.tcb and self.tcb.err end

---------------------------------------------------------------------------------------------------------------------
-- UDP
---------------------------------------------------------------------------------------------------------------------

local UDP = {}
UDP.__index = UDP

function M.udp(stack)
  stack = stack or M.default()
  return setmetatable({ stack = stack, s = udp.new(stack), timeout = nil }, UDP)
end

function UDP:settimeout(t) self.timeout = t return true end

function UDP:setoption(name, value)
  if name == "broadcast" then self.s.broadcast = value and true or false
  elseif name == "reuse" then self.s.reuse = value and true or false
  elseif name == "iface" then self.s.iface = value
  elseif name == "ttl" then self.s.ttl = value
  else return nil, "unknown option" end
  return true
end

function UDP:bind(addr, port)
  return udp.bind(self.s, addr, port)
end

function UDP:connect(host, port)
  local ip, why = self.stack:resolve(host)
  if not ip then return nil, why end
  self.s.raddr, self.s.rport = ip, port
  if not self.s.lport then local ok, err = udp.bind(self.s, 0, 0) if not ok then return nil, err end end
  return true
end

function UDP:sendto(data, host, port, opts)
  local ip, why = self.stack:resolve(host)
  if not ip then return nil, why end
  return udp.sendto(self.s, data, ip, port, opts)
end

function UDP:send(data)
  if not self.s.raddr then return nil, "not connected" end
  return udp.sendto(self.s, data, self.s.raddr, self.s.rport)
end

--- Returns data, source address (text), source port, and a table with more (dst, iface, ttl, broadcast); or nil + reason.
function UDP:receivefrom(timeout)
  local d, err = udp.receive(self.s, timeout or self.timeout)
  if not d then return nil, err end
  return d.data, B.ipStr(d.src), d.sport, d
end

function UDP:receive(timeout)
  local data, a, b = self:receivefrom(timeout)
  return data, a
end

function UDP:getsockname() return B.ipStr(self.s.laddr), self.s.lport end

function UDP:close() udp.close(self.s) return true end

return M
