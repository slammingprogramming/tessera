# tsr.inet.socket

Package: `inet`

Sockets, in the style of LuaSocket / BSD sockets, for programs on this computer:

  local socket = require("tsr.inet.socket")
  local c = socket.tcp()
  assert(c:connect("mail.example", 25, 10))      -- name (via DNS/hosts) or dotted quad
  c:send("HELO me\r\n")
  print(c:receive("*l"))                         -- one line;  c:receive(10) = exactly 10 bytes;  c:receive("*a") = until the peer closes
  c:close()

  local s = socket.tcp(); s:bind("0.0.0.0", 8080); s:listen(8)
  local client = s:accept()                      -- blocks (s:settimeout(5) to limit the wait)

  local u = socket.udp(); u:bind(nil, 5000); u:sendto("hi", "10.0.0.2", 5000); local data, ip, port = u:receivefrom(2)

Every blocking call returns nil + a reason on failure ("timeout", "closed", "connection refused", ...).

## `TCP:receive(pattern, timeout)`

receive(pattern, timeout): a number = exactly that many bytes, "*l" a line without its line end, "*a" everything until the peer closes,
"*any" whatever is available (at least one byte).

## `TCP:reset()`

Abort with a reset instead of an orderly close.

## `UDP:receivefrom(timeout)`

Returns data, source address (text), source port, and a table with more (dst, iface, ttl, broadcast); or nil + reason.
