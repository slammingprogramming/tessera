-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A web server for the in-game network: static files with the right types, index pages, conditional and range requests, virtual hosts, password-protected
-- areas, handlers written in Lua (for APIs, status pages, forms), per-address rate limits, an access log. HTTP/1.1 with keep-alive and chunked request
-- bodies. It never serves files outside its document root, and never files or folders whose names start with a dot.
--
--   server = require("tsr.inet.http.server").new(stack, {
--     port = 80, root = "/srv/www", index = { "index.html", "index.txt" }, listing = false,
--     vhosts = { ["shop.lan"] = { root = "/srv/shop" } },
--     routes = { ["/api/time"] = function(req, res) res.body = tostring(os.epoch("utc")) end },        -- exact path or "/prefix/*"
--     auth = { { path = "/admin", realm = "Admin", users = { alice = server.hashPassword("secret") } } },
--     errors = { [404] = "/404.html" }, accessLog = "/var/log/httpd.access.log", rate = 120,
--   })
--   server:serve()                -- blocks; or parallel.waitForAny(table.unpack(server:workers()))
local msg = require("tsr.inet.http.message")
local socket = require("tsr.inet.socket")
local vfs = require("tsr.vfs")
local hash = require("tsr.hash")

local M = {}
local Server = {}
Server.__index = Server

M.SERVER_NAME = "Tessera-httpd/1.0"

--- A password hash for the `auth` configuration: "salt$sha256(salt .. password)" (iterated 1000 times).
function M.hashPassword(password, salt)
  salt = salt or require("tsr.crypto").rand.bytes(8):gsub(".", function(c) return ("%02x"):format(c:byte()) end)
  local h = salt .. password
  for _ = 1, 200 do h = hash.sha256(h .. salt) end
  return salt .. "$" .. h
end

local function checkPassword(stored, password)
  local salt = stored:match("^(.-)%$")
  if not salt then return false end
  return M.hashPassword(password, salt) == stored
end

function M.new(stack, cfg)
  cfg = cfg or {}
  local self = setmetatable({
    stack = stack, cfg = cfg, port = cfg.port or 80, root = cfg.root or "/srv/www", index = cfg.index or { "index.html", "index.txt" }, listing = cfg.listing or false,
    vhosts = cfg.vhosts or {}, routes = cfg.routes or {}, errors = cfg.errors or {}, auth = cfg.auth or {}, maxBody = cfg.maxBody or 1048576, keepAlive = cfg.keepAlive ~= false,
    timeout = cfg.timeout or 15, rate = cfg.rate, stats = { requests = 0, bytes = 0, notFound = 0, errors = 0, denied = 0, limited = 0 }, hits = {}, perIp = {}, maxPerIp = cfg.maxPerIp or 20,
    serverName = cfg.serverName or M.SERVER_NAME, accessLog = cfg.accessLog,
  }, Server)
  return self
end

---------------------------------------------------------------------------------------------------------------------
-- Request handling
---------------------------------------------------------------------------------------------------------------------

local function response(status, body, headers)
  headers = headers or {}
  return { status = status, headers = headers, body = body or "" }
end

local function errorPage(self, root, status, extra)
  local custom = self.errors[status]
  if custom then
    local data = vfs.readFile(root .. custom, true)
    if data then return response(status, data, { ["content-type"] = "text/html" }) end
  end
  local reason = msg.REASONS[status] or "Error"
  local body = ("<html><head><title>%d %s</title></head><body><h1>%d %s</h1>%s<hr><p>%s</p></body></html>\n"):format(status, reason, status, reason, extra and ("<p>" .. extra .. "</p>") or "", self.serverName)
  return response(status, body, { ["content-type"] = "text/html" })
end

local function safePath(rel)
  -- rel is a decoded URL path starting with "/". No "..", no hidden files, no NUL.
  if rel:find("%z") then return nil end
  local parts = {}
  for seg in rel:gmatch("[^/]+") do
    if seg == ".." or seg:sub(1, 1) == "." then return nil end
    parts[#parts + 1] = seg
  end
  return "/" .. table.concat(parts, "/")
end

local function authFor(self, path)
  local best
  for _, rule in ipairs(self.auth) do
    if path == rule.path or path:sub(1, #rule.path + 1) == rule.path:gsub("/$", "") .. "/" then
      if not best or #rule.path > #best.path then best = rule end
    end
  end
  return best
end

local function listDirectory(self, dir, urlPath)
  local names = vfs.fs.list(dir)
  table.sort(names)
  local out = { "<html><head><title>Index of " .. urlPath .. "</title></head><body><h1>Index of " .. urlPath .. "</h1><ul>" }
  if urlPath ~= "/" then out[#out + 1] = '<li><a href="../">../</a></li>' end
  for _, n in ipairs(names) do
    if n:sub(1, 1) ~= "." then
      local isDir = vfs.fs.isDir(dir .. "/" .. n)
      out[#out + 1] = ('<li><a href="%s%s">%s%s</a></li>'):format(msg.urlEncode(n), isDir and "/" or "", n, isDir and "/" or "")
    end
  end
  out[#out + 1] = "</ul></body></html>\n"
  return table.concat(out, "\n")
end

local function httpDate(t)
  return os.date and os.date("!%a, %d %b %Y %H:%M:%S GMT", t) or "Thu, 01 Jan 1970 00:00:00 GMT"
end

local function matchRoute(self, path)
  if self.routes[path] then return self.routes[path] end
  local best, bestLen
  for pattern, fn in pairs(self.routes) do
    if pattern:sub(-2) == "/*" then
      local prefix = pattern:sub(1, -2)
      if path:sub(1, #prefix) == prefix and (not bestLen or #prefix > bestLen) then best, bestLen = fn, #prefix end
    end
  end
  return best
end

--- Turn a request table { method, target, headers, body, ip } into a response table { status, headers, body }.
function Server:handle(req)
  self.stats.requests = self.stats.requests + 1
  local headers = req.headers or {}
  local host = (headers.host or ""):gsub(":%d+$", ""):lower()
  local vhost = self.vhosts[host]
  local root = (vhost and vhost.root) or self.root
  -- rate limit per client address
  if self.rate and req.ip then
    local minute = math.floor(self.stack.clock() / 60)
    local h = self.hits[req.ip]
    if not h or h.minute ~= minute then h = { minute = minute, n = 0 } self.hits[req.ip] = h end
    h.n = h.n + 1
    if h.n > self.rate then
      self.stats.limited = self.stats.limited + 1
      return errorPage(self, root, 429, "Too many requests from your address; try again in a minute.")
    end
  end
  local method = req.method
  if method == "OPTIONS" then return response(204, "", { allow = "GET, HEAD, POST, OPTIONS" }) end
  if method ~= "GET" and method ~= "HEAD" and method ~= "POST" then return errorPage(self, root, method:match("^%u+$") and 405 or 501, nil) end
  local target = req.target
  if #target > 2048 then return errorPage(self, root, 414) end
  local rawPath, query = target:match("^([^?#]*)%??([^#]*)")
  if rawPath:sub(1, 1) ~= "/" then
    -- absolute-form (proxy style): strip the origin
    local u = msg.parseUrl(target)
    if not u then return errorPage(self, root, 400) end
    rawPath, query = u.path, u.query or ""
  end
  local path = msg.urlDecode((rawPath:gsub("%+", "%%2B")))
  local path2 = safePath(path)
  if not path2 then self.stats.denied = self.stats.denied + 1 return errorPage(self, root, 403) end
  if path:sub(-1) == "/" and path2 ~= "/" then path2 = path2 .. "/" end
  -- access control
  local rule = authFor(self, path2)
  if rule then
    local user, pw = msg.parseBasicAuth(headers.authorization)
    local stored = user and rule.users[user]
    if not (stored and checkPassword(stored, pw or "")) then
      self.stats.denied = self.stats.denied + 1
      local r = errorPage(self, root, 401)
      r.headers["www-authenticate"] = ('Basic realm="%s"'):format(rule.realm or "restricted")
      return r
    end
    req.user = user
  end
  req.path, req.query, req.params = path2, query, msg.parseQuery(query)
  -- handlers written in Lua
  local handler = matchRoute(self, path2)
  if handler then
    local res = { status = 200, headers = { ["content-type"] = "text/plain" }, body = "" }
    local ok, err = pcall(handler, req, res)
    if not ok then
      self.stats.errors = self.stats.errors + 1
      return errorPage(self, root, 500, nil)
    end
    if type(err) == "string" then res.body = err end
    return res
  end
  if method == "POST" then return errorPage(self, root, 405) end
  -- files
  local full = root .. path2
  if path2:sub(-1) == "/" then full = root .. path2:sub(1, -2) end
  if not vfs.fs.exists(full) then
    self.stats.notFound = self.stats.notFound + 1
    return errorPage(self, root, 404, "The page " .. path2:gsub("[<>&]", "") .. " does not exist.")
  end
  if vfs.fs.isDir(full) then
    if path2:sub(-1) ~= "/" then return response(301, "", { location = path2 .. "/" .. (query ~= "" and ("?" .. query) or "") }) end
    for _, name in ipairs(self.index) do
      if vfs.fs.exists(full .. "/" .. name) and not vfs.fs.isDir(full .. "/" .. name) then full = full .. "/" .. name break end
    end
    if vfs.fs.isDir(full) then
      if self.listing then return response(200, listDirectory(self, full, path2), { ["content-type"] = "text/html" }) end
      return errorPage(self, root, 403, "Directory listing is off.")
    end
  end
  local data = vfs.readFile(full, true)
  if not data then return errorPage(self, root, 500) end
  local modified = fs.attributes and (function() local ok, a = pcall(fs.attributes, full) return ok and a and a.modified end)() or nil
  local etag = ('W/"%x-%s"'):format(#data, ("%.0f"):format(modified or 0))        -- %x would fail on large numbers in Cobalt
  local h = { ["content-type"] = msg.mimeOf(full), etag = etag, ["accept-ranges"] = "bytes" }
  if modified then h["last-modified"] = httpDate(math.floor(modified / 1000)) end
  if headers["if-none-match"] == etag then return response(304, "", h) end
  local range = headers.range and headers.range:match("^bytes=(%d*%-%d*)$")
  if range then
    local a, b = range:match("^(%d*)%-(%d*)$")
    local first, last
    if a == "" then first, last = math.max(0, #data - tonumber(b)), #data - 1 else first, last = tonumber(a), (b ~= "" and tonumber(b)) or (#data - 1) end
    last = math.min(last, #data - 1)
    if first > last or first >= #data then
      h["content-range"] = "bytes */" .. #data
      return response(416, "", h)
    end
    h["content-range"] = ("bytes %d-%d/%d"):format(first, last, #data)
    return response(206, data:sub(first + 1, last + 1), h)
  end
  return response(200, data, h)
end

---------------------------------------------------------------------------------------------------------------------
-- Connections
---------------------------------------------------------------------------------------------------------------------

local function readHead(conn, timeout)
  local lines, total = {}, 0
  while true do
    local line, err = conn:receive("*l", timeout)
    if not line then return nil, err end
    total = total + #line + 2
    if total > 16384 or #lines > 100 then return nil, "too large" end
    if line == "" then
      if #lines > 0 then break end
    else
      lines[#lines + 1] = line
    end
  end
  return table.concat(lines, "\r\n")
end

local function readBody(self, conn, headers)
  local te = headers["transfer-encoding"]
  if te and te:lower():find("chunked", 1, true) then
    local parts, size = {}, 0
    while true do
      local line = conn:receive("*l", self.timeout)
      local n = line and tonumber(line:match("^(%x+)"), 16)
      if not n then return nil, 400 end
      if n == 0 then repeat local t = conn:receive("*l", self.timeout) until t == nil or t == "" break end
      size = size + n
      if size > self.maxBody then return nil, 413 end
      local data = conn:receive(n, self.timeout)
      if not data then return nil, 400 end
      parts[#parts + 1] = data
      conn:receive(2, self.timeout)
    end
    return table.concat(parts)
  end
  local len = tonumber(headers["content-length"])
  if not len then return "" end
  if len > self.maxBody then return nil, 413 end
  if len == 0 then return "" end
  local data = conn:receive(len, self.timeout)
  if not data then return nil, 400 end
  return data
end

local function logAccess(self, ip, req, res)
  if not self.accessLog then return end
  local line = ('%s - %s [%s] "%s %s" %d %d\n'):format(ip, req.user or "-", os.date and os.date("%d/%b/%Y:%H:%M:%S") or "-", req.method, req.target, res.status, #res.body)
  local h = vfs.fs.open(self.accessLog, "a")
  if h then h.write(line) h.close() end
end

--- Serve one connection until it closes (keep-alive: several requests).
function Server:connection(conn)
  local ip = conn:getpeername() or "?"
  local ipNum = require("tsr.inet.bytes").ip(ip)
  self.perIp[ip] = (self.perIp[ip] or 0) + 1
  if self.perIp[ip] > self.maxPerIp then
    conn:send("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
    self.perIp[ip] = self.perIp[ip] - 1
    conn:close()
    return
  end
  local served = 0
  while served < 20 do
    local head, err = readHead(conn, served == 0 and self.timeout or 5)
    if not head then
      if err == "too large" then conn:send("HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\nContent-Length: 0\r\n\r\n") end
      break
    end
    local parsed, perr = msg.parseHead(head)
    local line = parsed and msg.parseRequestLine(parsed.start)
    local res, req
    if not line then
      res = response(400, "Bad request\n", { ["content-type"] = "text/plain" })
    elseif line.version ~= "1.1" and line.version ~= "1.0" then
      res = response(505, "HTTP version not supported\n", { ["content-type"] = "text/plain" })
    else
      local body, bad = readBody(self, conn, parsed.headers)
      if not body then res = errorPage(self, self.root, bad)
      else
        req = { method = line.method, target = line.target, headers = parsed.headers, body = body, ip = ip, version = line.version }
        res = self:handle(req)
      end
    end
    local close = not self.keepAlive or (parsed and parsed.headers.connection and parsed.headers.connection:lower() == "close") or (line and line.version == "1.0") or res.status >= 400 and res.status ~= 404
    local h = res.headers
    h.server, h.date = self.serverName, h.date or (os.date and os.date("!%a, %d %b %Y %H:%M:%S GMT") or nil)
    h["content-length"] = #res.body
    h.connection = close and "close" or "keep-alive"
    local body = (req and req.method == "HEAD") and "" or res.body
    if res.status == 204 or res.status == 304 then h["content-length"] = nil end
    local ok = conn:send(("HTTP/1.1 %d %s\r\n%s\r\n%s"):format(res.status, msg.REASONS[res.status] or "Status", msg.formatHeaders(h), body))
    self.stats.bytes = self.stats.bytes + #body
    if req then logAccess(self, ip, req, res) end
    served = served + 1
    if close or not ok then break end
  end
  self.perIp[ip] = self.perIp[ip] - 1
  conn:close()
end

--- Worker functions to run side by side (parallel.waitForAny, or sim:spawn each): `n` acceptors.
function Server:workers(n)
  if self.cfg.tls then
    -- https: the name of the certificate in /etc/tsr/inet/tls (see tlsctl), or { name = ..., dir = ... }
    local tls = require("tsr.inet.tls")
    local spec = type(self.cfg.tls) == "table" and self.cfg.tls or { name = self.cfg.tls }
    local creds, why = tls.loadCredentials(spec.name, spec.dir)
    if not creds then return nil, why end
    self.tlsCreds = creds
  end
  local l = socket.tcp(self.stack)
  l:bind(self.cfg.address, self.port)
  local ok, err = l:listen(16)
  if not ok then return nil, err end
  self.listener = l
  self.running = true
  local jobs = {}
  for _ = 1, n or 4 do
    jobs[#jobs + 1] = function()
      while self.running do
        local c = l:accept(1)
        if c and self.tlsCreds then
          local secure = require("tsr.inet.tls").server(c, self.tlsCreds)
          c = secure
        end
        if c then
          local okc, e = pcall(self.connection, self, c)
          if not okc then self.stats.errors = self.stats.errors + 1 pcall(function() c:close() end) end
        end
      end
    end
  end
  return jobs
end

function Server:stop()
  self.running = false
  if self.listener then self.listener:close() end
end

return M
