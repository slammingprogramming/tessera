-- SPDX-License-Identifier: AGPL-3.0-or-later
-- HTTP/1.1 messages (RFC 9110, 9112): URLs, request and status lines, headers, Content-Length and chunked bodies, percent-encoding, MIME types.
local M = {}

---------------------------------------------------------------------------------------------------------------------
-- URLs
---------------------------------------------------------------------------------------------------------------------

--- "http://user:pw@host:8080/path?query#frag" -> { scheme, host, port, path, query, fragment, user, password }. Returns nil + reason for what is not a URL.
function M.parseUrl(text)
  local scheme, rest = tostring(text):match("^(%a[%w+.-]*)://(.*)$")
  if not scheme then return nil, "not a URL (it needs http:// in front)" end
  scheme = scheme:lower()
  local authority, tail = rest:match("^([^/?#]*)(.*)$")
  local user, password
  local at = authority:find("@", 1, true)
  if at then
    local cred = authority:sub(1, at - 1)
    authority = authority:sub(at + 1)
    user, password = cred:match("^([^:]*):?(.*)$")
  end
  local host, port = authority:match("^(.-):(%d+)$")
  if not host then host = authority end
  if host == "" then return nil, "no host in the URL" end
  local path, query, fragment = tail, nil, nil
  local hash = path:find("#", 1, true)
  if hash then fragment = path:sub(hash + 1) path = path:sub(1, hash - 1) end
  local q = path:find("?", 1, true)
  if q then query = path:sub(q + 1) path = path:sub(1, q - 1) end
  if path == "" then path = "/" end
  return { scheme = scheme, host = host:lower(), port = tonumber(port) or (scheme == "https" and 443 or 80), path = path, query = query, fragment = fragment, user = user, password = password }
end

function M.formatUrl(u)
  local default = (u.scheme == "https" and 443 or 80)
  return u.scheme .. "://" .. u.host .. (u.port ~= default and (":" .. u.port) or "") .. u.path .. (u.query and ("?" .. u.query) or "")
end

--- Resolve `ref` (absolute URL, "/path", "page.html", "?q") against the page `base` (a parsed URL). Returns a URL string.
function M.resolve(base, ref)
  if ref:match("^%a[%w+.-]*://") then return ref end
  if ref:sub(1, 2) == "//" then return base.scheme .. ":" .. ref end
  local origin = M.formatUrl({ scheme = base.scheme, host = base.host, port = base.port, path = "" }):gsub("/$", "")
  if ref:sub(1, 1) == "/" then return origin .. M.normalizePath(ref) end
  if ref:sub(1, 1) == "?" then return origin .. base.path .. ref end
  if ref:sub(1, 1) == "#" then return origin .. base.path .. (base.query and ("?" .. base.query) or "") .. ref end
  local dir = base.path:match("^(.*/)") or "/"
  return origin .. M.normalizePath(dir .. ref)
end

--- Collapse "." and ".." segments. The result never climbs above the root.
function M.normalizePath(path)
  local query = ""
  local q = path:find("[?#]")
  if q then query = path:sub(q) path = path:sub(1, q - 1) end
  local out = {}
  for seg in path:gmatch("[^/]*") do
    if seg == ".." then if #out > 0 then table.remove(out) end
    elseif seg ~= "." and seg ~= "" then out[#out + 1] = seg end
  end
  local result = "/" .. table.concat(out, "/")
  if path:sub(-1) == "/" and result ~= "/" then result = result .. "/" end
  return result .. query
end

function M.urlDecode(s)
  s = s:gsub("%+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function M.urlEncode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

--- "a=1&b=two%20words" -> { a = "1", b = "two words" }
function M.parseQuery(q)
  local t = {}
  for pair in (q or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    t[M.urlDecode(k)] = M.urlDecode(v)
  end
  return t
end

---------------------------------------------------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------------------------------------------------

M.REASONS = {
  [200] = "OK", [201] = "Created", [204] = "No Content", [206] = "Partial Content", [301] = "Moved Permanently", [302] = "Found", [303] = "See Other", [304] = "Not Modified",
  [307] = "Temporary Redirect", [308] = "Permanent Redirect", [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden", [404] = "Not Found", [405] = "Method Not Allowed",
  [408] = "Request Timeout", [411] = "Length Required", [413] = "Content Too Large", [414] = "URI Too Long", [429] = "Too Many Requests", [431] = "Request Header Fields Too Large",
  [500] = "Internal Server Error", [501] = "Not Implemented", [502] = "Bad Gateway", [503] = "Service Unavailable", [505] = "HTTP Version Not Supported",
}

M.MIME = {
  html = "text/html", htm = "text/html", txt = "text/plain", css = "text/css", js = "text/javascript", json = "application/json", xml = "application/xml", lua = "text/plain",
  png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg", gif = "image/gif", nfp = "application/x-nfp", bimg = "application/x-bimg", dfpwm = "audio/x-dfpwm",
  ["32vid"] = "video/x-32vid", tar = "application/x-tar", gz = "application/gzip", tgz = "application/gzip", md = "text/markdown", csv = "text/csv", pdf = "application/pdf",
}

function M.mimeOf(path)
  local ext = path:match("%.([%w]+)$")
  return ext and M.MIME[ext:lower()] or "application/octet-stream"
end

--- Header names are case-insensitive: store them lower-cased.
local function addHeader(headers, name, value)
  name = name:lower()
  if headers[name] then headers[name] = headers[name] .. ", " .. value else headers[name] = value end
end

--- Parse the head of a request or response (everything up to the blank line). Returns { start = "GET / HTTP/1.1", headers = {..} } or nil + reason.
function M.parseHead(text)
  local lines = {}
  for line in (text .. "\r\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  local start = lines[1]
  if not start or start == "" then return nil, "empty message" end
  local headers = {}
  local last
  for i = 2, #lines do
    local l = lines[i]
    if l ~= "" then
      if l:match("^[ \t]") and last then headers[last] = headers[last] .. " " .. l:gsub("^%s+", "")
      else
        local name, value = l:match("^([%w%-!#$%%&'*+.^_`|~]+):%s*(.-)%s*$")
        if not name then return nil, "bad header line" end
        addHeader(headers, name, value)
        last = name:lower()
      end
    end
  end
  return { start = start, headers = headers }
end

function M.parseRequestLine(line)
  local method, target, version = line:match("^(%u+) (%S+) HTTP/(%d%.%d)$")
  if not method then return nil, "bad request line" end
  return { method = method, target = target, version = version }
end

function M.parseStatusLine(line)
  local version, status, reason = line:match("^HTTP/(%d%.%d) (%d%d%d)%s*(.*)$")
  if not version then return nil, "bad status line" end
  return { version = version, status = tonumber(status), reason = reason }
end

--- Format a header table: keys are written in Capital-Case.
function M.formatHeaders(headers)
  local names = {}
  for k in pairs(headers) do names[#names + 1] = k end
  table.sort(names)
  local out = {}
  for _, k in ipairs(names) do
    out[#out + 1] = (k:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end)) .. ": " .. tostring(headers[k]) .. "\r\n"
  end
  return table.concat(out)
end

--- Encode a body with chunked transfer encoding (pieces of at most `size` bytes).
function M.chunked(body, size)
  size = size or 4096
  local out = {}
  for i = 1, #body, size do
    local piece = body:sub(i, i + size - 1)
    out[#out + 1] = ("%x\r\n%s\r\n"):format(#piece, piece)
  end
  out[#out + 1] = "0\r\n\r\n"
  return table.concat(out)
end

--- Basic authentication header value for user and password.
function M.basicAuth(user, password)
  return "Basic " .. require("tsr.hash").base64Encode(user .. ":" .. (password or ""))
end

function M.parseBasicAuth(value)
  local b = tostring(value or ""):match("^[Bb]asic%s+(.+)$")
  if not b then return nil end
  local decoded = require("tsr.hash").base64Decode(b)
  if not decoded then return nil end
  local user, pw = decoded:match("^([^:]*):(.*)$")
  return user, pw
end

return M
