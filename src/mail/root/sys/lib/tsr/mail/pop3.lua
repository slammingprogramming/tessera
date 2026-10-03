-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The POP3 client: fetch mail from a server's mailbox.
--   local c, err = pop3.connect(stack, "mail.lan", { user = "alice", pass = "...", port = 110, tls = "opportunistic" | "starttls" | "pop3s", store = trustStore })
--   local count, bytes = c:stat()   local list = c:list()   local raw = c:retr(1)   c:dele(1)   c:quit()
--   local mails = pop3.fetch(stack, "mail.lan", { user, pass, delete = true })   -- everything, optionally removing it from the server
local socket = require("tsr.inet.socket")
local msg = require("tsr.mail.message")

local M = {}
local Client = {}
Client.__index = Client

M.TIMEOUT = 20

local function readLine(conn, timeout)
  local line, err = conn:receive("*l", timeout)
  if not line then return nil, err or "closed" end
  return line
end

--- Send a command and read the status line. Returns true + the text, or nil + the error text.
function Client:command(text)
  local sent, err = self.conn:send(text .. "\r\n", M.TIMEOUT)
  if not sent then return nil, err end
  local line, why = readLine(self.conn, M.TIMEOUT)
  if not line then return nil, why end
  if line:sub(1, 3) == "+OK" then return true, (line:sub(5)) end
  return nil, (line:gsub("^%-ERR%s*", ""))
end

--- The body of a multi-line reply, with dot-stuffing removed.
function Client:body()
  local lines = {}
  while true do
    local line, why = readLine(self.conn, M.TIMEOUT)
    if not line then return nil, why end
    if line == "." then return lines end
    if line:sub(1, 2) == ".." then line = line:sub(2) end
    lines[#lines + 1] = line
    if #lines > 200000 then return nil, "reply too long" end
  end
end

function Client:capabilities()
  local okC = self:command("CAPA")
  if not okC then return {} end
  local lines = self:body() or {}
  local caps = {}
  for _, l in ipairs(lines) do caps[l:upper():match("^(%S+)")] = true end
  return caps
end

function Client:stat()
  local okS, text = self:command("STAT")
  if not okS then return nil, text end
  local n, bytes = text:match("^(%d+)%s+(%d+)")
  return tonumber(n), tonumber(bytes)
end

--- { { n, size } } (or with uid when uidl is true: { n, uid }).
function Client:list(uidl)
  local okL, why = self:command(uidl and "UIDL" or "LIST")
  if not okL then return nil, why end
  local lines, err = self:body()
  if not lines then return nil, err end
  local out = {}
  for _, l in ipairs(lines) do
    local n, v = l:match("^(%d+)%s+(%S+)")
    if n then out[#out + 1] = { n = tonumber(n), size = not uidl and tonumber(v) or nil, uid = uidl and v or nil } end
  end
  return out
end

function Client:retr(n)
  local okR, why = self:command("RETR " .. n)
  if not okR then return nil, why end
  local lines, err = self:body()
  if not lines then return nil, err end
  return table.concat(lines, "\r\n") .. "\r\n"
end

function Client:top(n, count)
  local okT, why = self:command(("TOP %d %d"):format(n, count or 0))
  if not okT then return nil, why end
  local lines, err = self:body()
  if not lines then return nil, err end
  return table.concat(lines, "\r\n") .. "\r\n"
end

function Client:dele(n)
  return self:command("DELE " .. n)
end

function Client:reset() return self:command("RSET") end

--- Ends the session; messages marked with dele disappear now.
function Client:quit()
  local okQ, why = self:command("QUIT")
  self.conn:close()
  return okQ, why
end

--- Connect and log in. opts: user, pass, port, tls ("opportunistic", "starttls", "pop3s"), store, tlsName, timeout.
function M.connect(stack, host, opts)
  opts = opts or {}
  local raw = socket.tcp(stack)
  local okC, err = raw:connect(host, opts.port or (opts.tls == "pop3s" and 995 or 110), opts.timeout or M.TIMEOUT)
  if not okC then return nil, "cannot connect to " .. host .. ": " .. tostring(err) end
  local conn = raw
  local secure = false
  local tls = opts.tls
  if tls == "pop3s" then
    local c, terr, detail = require("tsr.inet.tls").client(raw, opts.tlsName or host, { store = opts.store, timeout = opts.timeout or M.TIMEOUT })
    if not c then return nil, "secure connection failed: " .. tostring(terr) .. (detail and (" (" .. detail .. ")") or "") end
    conn, secure = c, true
  end
  local self = setmetatable({ conn = conn, secure = secure, host = host }, Client)
  local greeting, why = readLine(conn, M.TIMEOUT)
  if not greeting or greeting:sub(1, 3) ~= "+OK" then conn:close() return nil, "no welcome from the server: " .. tostring(greeting or why) end
  if (tls == "starttls" or tls == "opportunistic") and not secure then
    local caps = self:capabilities()
    if caps.STLS then
      local okS, serr = self:command("STLS")
      if okS then
        local c, terr, detail = require("tsr.inet.tls").client(raw, opts.tlsName or host, { store = opts.store, timeout = opts.timeout or M.TIMEOUT })
        if not c then return nil, "secure connection failed: " .. tostring(terr) .. (detail and (" (" .. detail .. ")") or "") end
        self.conn, self.secure = c, true
      elseif tls == "starttls" then conn:close() return nil, "the server would not start TLS: " .. tostring(serr) end
    elseif tls == "starttls" then
      conn:close()
      return nil, "the server does not offer STLS"
    end
  end
  if opts.user then
    local okU, uerr = self:command("USER " .. opts.user)
    if not okU then self.conn:close() return nil, "login refused: " .. tostring(uerr) end
    local okP, perr = self:command("PASS " .. tostring(opts.pass))
    if not okP then self.conn:close() return nil, "login refused: " .. tostring(perr) end
  end
  return self
end

--- Download all messages. Returns a list of { n, uid, raw } or nil + reason. With delete = true they are removed from the server after a clean download.
function M.fetch(stack, host, opts)
  local c, err = M.connect(stack, host, opts)
  if not c then return nil, err end
  local uids = c:list(true) or {}
  local out = {}
  for _, item in ipairs(uids) do
    if not (opts.skip and opts.skip[item.uid]) then
      local raw, why = c:retr(item.n)
      if not raw then c:quit() return nil, "message " .. item.n .. ": " .. tostring(why) end
      out[#out + 1] = { n = item.n, uid = item.uid, raw = raw }
      if opts.delete then c:dele(item.n) end
    end
  end
  c:quit()
  return out
end

return M
