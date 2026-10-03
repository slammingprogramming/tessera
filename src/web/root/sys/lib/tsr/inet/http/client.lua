-- SPDX-License-Identifier: AGPL-3.0-or-later
-- An HTTP/1.1 client for the in-game network (plain http:// to servers that run on computers of this world; names come from the stack's DNS and hosts).
--   local http = require("tsr.inet.http.client")
--   local r = http.get("http://info.lan/news.txt")           -- { status, reason, headers, body, url }
--   local r = http.request{ method = "POST", url = "http://api.lan/x", body = "a=1", headers = { ["content-type"] = "application/x-www-form-urlencoded" }, timeout = 5 }
-- Redirects are followed (up to 5), chunked and Content-Length bodies are decoded, a body without either is read until the server closes.
local msg = require("tsr.inet.http.message")
local socket = require("tsr.inet.socket")

local M = {}

M.MAX_REDIRECTS = 5
M.MAX_BODY = 4 * 1024 * 1024
M.USER_AGENT = "Tessera-http/1.0"

local function readHead(conn, timeout)
  local lines = {}
  local total = 0
  while true do
    local line, err = conn:receive("*l", timeout)
    if not line then return nil, err end
    total = total + #line + 2
    if total > 65536 then return nil, "response header too large" end
    if line == "" and #lines > 0 then break end
    if line ~= "" or #lines > 0 then lines[#lines + 1] = line end
  end
  return table.concat(lines, "\r\n")
end

local function readBody(conn, headers, method, status, timeout)
  if method == "HEAD" or status == 204 or status == 304 or (status >= 100 and status < 200) then return "" end
  local te = headers["transfer-encoding"]
  if te and te:lower():find("chunked", 1, true) then
    local parts, size = {}, 0
    while true do
      local line, err = conn:receive("*l", timeout)
      if not line then return nil, err end
      local n = tonumber(line:match("^(%x+)"), 16)
      if not n then return nil, "bad chunk size" end
      if n == 0 then
        -- trailers up to the blank line
        repeat local t = conn:receive("*l", timeout) until t == nil or t == ""
        break
      end
      size = size + n
      if size > M.MAX_BODY then return nil, "response too large" end
      local data, err2 = conn:receive(n, timeout)
      if not data then return nil, err2 end
      parts[#parts + 1] = data
      conn:receive(2, timeout)                            -- the CRLF after the chunk
    end
    return table.concat(parts)
  end
  local len = tonumber(headers["content-length"])
  if len then
    if len > M.MAX_BODY then return nil, "response too large" end
    if len == 0 then return "" end
    local data, err = conn:receive(len, timeout)
    if not data then return nil, err or "connection closed before the end of the body" end
    return data
  end
  local data, err = conn:receive("*a", timeout)
  if not data then return nil, err end
  return data
end

--- opts: url, method (GET), headers, body, timeout (10), follow (true), stack, maxRedirects, user, password.
function M.request(opts)
  local url = opts.url
  local method = (opts.method or "GET"):upper()
  local redirects = 0
  while true do
    local u, why = msg.parseUrl(url)
    if not u then return nil, why end
    if u.scheme ~= "http" and u.scheme ~= "https" then return nil, u.scheme .. ":// is not available here (http:// and https:// of the in-game web)" end
    local c = socket.tcp(opts.stack)
    local timeout = opts.timeout or 10
    local ok, err = c:connect(u.host, u.port, timeout)
    if not ok then return nil, "cannot connect to " .. u.host .. ":" .. u.port .. ": " .. tostring(err) end
    if u.scheme == "https" then
      local okT, tls = pcall(require, "tsr.inet.tls")
      if not okT then c:close() return nil, "https needs the tls package" end
      local secure, terr, detail = tls.client(c, u.host, { store = opts.tlsStore, timeout = timeout })
      if not secure then return nil, "secure connection to " .. u.host .. " failed: " .. tostring(terr) .. (detail and (" (" .. detail .. ")") or "") end
      c = secure
    end
    local headers = { host = u.host .. ((u.port ~= (u.scheme == "https" and 443 or 80)) and (":" .. u.port) or ""), connection = "close", ["user-agent"] = M.USER_AGENT, accept = "*/*" }
    for k, v in pairs(opts.headers or {}) do headers[k:lower()] = v end
    local user, pw = opts.user or u.user, opts.password or u.password
    if user and not headers.authorization then headers.authorization = msg.basicAuth(user, pw) end
    local body = opts.body
    if body then headers["content-length"] = #body elseif method == "POST" or method == "PUT" then headers["content-length"] = 0 end
    local target = u.path .. (u.query and ("?" .. u.query) or "")
    c:send(("%s %s HTTP/1.1\r\n%s\r\n%s"):format(method, target, msg.formatHeaders(headers), body or ""), timeout)
    local head, herr = readHead(c, timeout)
    if not head then c:close() return nil, "no response: " .. tostring(herr) end
    local parsed, perr = msg.parseHead(head)
    local status = parsed and msg.parseStatusLine(parsed.start)
    if not status then c:close() return nil, "bad response: " .. tostring(perr or parsed and parsed.start) end
    local data, berr = readBody(c, parsed.headers, method, status.status, timeout)
    c:close()
    if not data then return nil, "response interrupted: " .. tostring(berr) end
    local resp = { status = status.status, reason = status.reason, headers = parsed.headers, body = data, url = url, version = status.version }
    local loc = parsed.headers.location
    if opts.follow ~= false and loc and (status.status == 301 or status.status == 302 or status.status == 303 or status.status == 307 or status.status == 308) then
      redirects = redirects + 1
      if redirects > (opts.maxRedirects or M.MAX_REDIRECTS) then return nil, "too many redirects" end
      url = msg.resolve(u, loc)
      if status.status == 303 or ((status.status == 301 or status.status == 302) and method == "POST") then method, opts.body = "GET", nil end
    else
      resp.redirects = redirects
      return resp
    end
  end
end

function M.get(url, opts)
  opts = opts or {}
  opts.url = url
  return M.request(opts)
end

function M.post(url, body, opts)
  opts = opts or {}
  opts.url, opts.method, opts.body = url, "POST", body
  return M.request(opts)
end

return M
