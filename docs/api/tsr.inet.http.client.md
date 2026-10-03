# tsr.inet.http.client

Package: `web`

An HTTP/1.1 client for the in-game network (plain http:// to servers that run on computers of this world; names come from the stack's DNS and hosts).
  local http = require("tsr.inet.http.client")
  local r = http.get("http://info.lan/news.txt")           -- { status, reason, headers, body, url }
  local r = http.request{ method = "POST", url = "http://api.lan/x", body = "a=1", headers = { ["content-type"] = "application/x-www-form-urlencoded" }, timeout = 5 }
Redirects are followed (up to 5), chunked and Content-Length bodies are decoded, a body without either is read until the server closes.

## `M.request(opts)`

opts: url, method (GET), headers, body, timeout (10), follow (true), stack, maxRedirects, user, password.
