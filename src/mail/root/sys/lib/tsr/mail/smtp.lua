-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The SMTP client (RFC 5321): hands one message to one mail server. Used by the mail transfer agent to deliver the queue and by mail clients to submit
-- messages (port 587 with authentication, or port 25 to the next server).
--   smtp.deliver(stack, "mail.lan", { from = "a@x.lan", rcpts = { "b@y.lan" }, data = rawMessage, helo = "x.lan", port = 25,
--                                     tls = "opportunistic" | "starttls" (required) | "smtps" (TLS from the first byte), auth = { user = "a", pass = "..." } })
-- Returns { ok, accepted = { rcpt... }, rejected = { rcpt = { code, text, permanent } }, error, tempfail, secure }.
local socket = require("tsr.inet.socket")
local hash = require("tsr.hash")
local msg = require("tsr.mail.message")

local M = {}

M.TIMEOUT = 20

--- Read a (possibly multi-line) reply. Returns code, lines or nil + reason.
function M.readReply(conn, timeout)
  local lines = {}
  while true do
    local line, err = conn:receive("*l", timeout or M.TIMEOUT)
    if not line then return nil, err or "closed" end
    local code, sep, text = line:match("^(%d%d%d)([ %-]?)(.*)$")
    if not code then return nil, "bad reply: " .. line:sub(1, 40) end
    lines[#lines + 1] = text
    if sep ~= "-" then return tonumber(code), lines end
  end
end

local function command(conn, text, timeout)
  local ok, err = conn:send(text .. "\r\n", timeout or M.TIMEOUT)
  if not ok then return nil, err end
  return M.readReply(conn, timeout)
end

local function hasExtension(lines, name)
  for _, l in ipairs(lines) do
    if l:upper() == name or l:upper():sub(1, #name + 1) == name .. " " then return l end
  end
end

local function fail(res, text, temp)
  res.ok = false
  res.error = text
  res.tempfail = temp
  return res
end

--- opts: from ("" for a bounce), rcpts, data, helo, port (25), tls, auth, timeout, store (TLS trust store), tlsName (the name the certificate must carry; default: host), size limit is taken from the server.
function M.deliver(stack, host, opts)
  local res = { ok = false, accepted = {}, rejected = {} }
  local timeout = opts.timeout or M.TIMEOUT
  local raw = socket.tcp(stack)
  local ok, err = raw:connect(host, opts.port or 25, timeout)
  if not ok then return fail(res, "cannot connect to " .. host .. ": " .. tostring(err), true) end
  local conn = raw
  if opts.tls == "smtps" then
    local tls = require("tsr.inet.tls")
    local secure, terr, detail = tls.client(raw, opts.tlsName or host, { store = opts.store, timeout = timeout })
    if not secure then return fail(res, "secure connection failed: " .. tostring(terr) .. (detail and (" (" .. detail .. ")") or ""), true) end
    conn = secure
    res.secure = true
  end
  local code, lines = M.readReply(conn, timeout)
  if not code then conn:close() return fail(res, "no greeting: " .. tostring(lines), true) end
  if code ~= 220 then conn:close() return fail(res, "the server refused the connection: " .. code .. " " .. tostring(lines[1]), code >= 400 and code < 500) end
  local helo = opts.helo or "localhost"
  code, lines = command(conn, "EHLO " .. helo, timeout)
  if code and code ~= 250 then code, lines = command(conn, "HELO " .. helo, timeout) end
  if code ~= 250 then conn:close() return fail(res, "EHLO failed: " .. tostring(code) .. " " .. tostring(lines and lines[1] or lines), code and code >= 400 and code < 500 or code == nil) end
  local caps = lines
  if (opts.tls == "starttls" or opts.tls == "opportunistic") and not res.secure and hasExtension(caps, "STARTTLS") then
    local c2, l2 = command(conn, "STARTTLS", timeout)
    if c2 == 220 then
      local tls = require("tsr.inet.tls")
      local secure, terr, detail = tls.client(raw, opts.tlsName or host, { store = opts.store, timeout = timeout })
      if not secure then return fail(res, "secure connection failed: " .. tostring(terr) .. (detail and (" (" .. detail .. ")") or ""), true) end
      conn = secure
      res.secure = true
      code, caps = command(conn, "EHLO " .. helo, timeout)
      if code ~= 250 then conn:close() return fail(res, "EHLO after STARTTLS failed", true) end
    elseif opts.tls == "starttls" then
      conn:close()
      return fail(res, "the server would not start TLS: " .. tostring(c2), true)
    end
  elseif opts.tls == "starttls" and not res.secure then
    conn:close()
    return fail(res, "the server does not offer STARTTLS", false)
  end
  if opts.auth then
    if not hasExtension(caps, "AUTH") then conn:close() return fail(res, "the server does not offer authentication", false) end
    local token = hash.base64Encode("\0" .. opts.auth.user .. "\0" .. opts.auth.pass)
    local c3, l3 = command(conn, "AUTH PLAIN " .. token, timeout)
    if c3 ~= 235 then conn:close() return fail(res, "authentication failed: " .. tostring(c3) .. " " .. tostring(l3 and l3[1]), c3 and c3 >= 400 and c3 < 500) end
  end
  local sizeExt = hasExtension(caps, "SIZE")
  local maxSize = sizeExt and tonumber(sizeExt:match("SIZE%s+(%d+)"))
  if maxSize and maxSize > 0 and #opts.data > maxSize then
    command(conn, "QUIT", 5)
    conn:close()
    return fail(res, ("the message (%d bytes) is larger than the server accepts (%d bytes)"):format(#opts.data, maxSize), false)
  end
  code, lines = command(conn, ("MAIL FROM:<%s>%s"):format(opts.from, sizeExt and (" SIZE=" .. #opts.data) or ""), timeout)
  if code ~= 250 then
    command(conn, "QUIT", 5)
    conn:close()
    return fail(res, "sender refused: " .. tostring(code) .. " " .. tostring(lines and lines[1]), code and code >= 400 and code < 500 or code == nil)
  end
  for _, rcpt in ipairs(opts.rcpts) do
    local c, l = command(conn, "RCPT TO:<" .. rcpt .. ">", timeout)
    if c == 250 or c == 251 then res.accepted[#res.accepted + 1] = rcpt
    else res.rejected[rcpt] = { code = c, text = l and l[1] or "no answer", permanent = c ~= nil and c >= 500 } end
  end
  if #res.accepted == 0 then
    command(conn, "QUIT", 5)
    conn:close()
    local anyTemp = false
    for _, r in pairs(res.rejected) do if not r.permanent then anyTemp = true end end
    return fail(res, "no recipient was accepted", anyTemp)
  end
  code, lines = command(conn, "DATA", timeout)
  if code ~= 354 then
    command(conn, "QUIT", 5)
    conn:close()
    return fail(res, "DATA refused: " .. tostring(code) .. " " .. tostring(lines and lines[1]), code and code >= 400 and code < 500 or code == nil)
  end
  conn:send(msg.dotStuff(opts.data) .. ".\r\n", timeout)
  code, lines = M.readReply(conn, math.max(timeout, 30))
  command(conn, "QUIT", 5)
  conn:close()
  if code ~= 250 then
    -- a message refused at the end of DATA is refused for all accepted recipients
    local permanent = code ~= nil and code >= 500
    for _, r in ipairs(res.accepted) do res.rejected[r] = { code = code, text = lines and lines[1] or "no answer", permanent = permanent } end
    res.accepted = {}
    return fail(res, "message refused: " .. tostring(code) .. " " .. tostring(lines and lines[1] or lines), not permanent)
  end
  res.ok = true
  res.reply = lines[1]
  return res
end

return M
