-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local msg = require("tsr.inet.http.message")
local html = require("tsr.inet.http.html")
local serverMod = require("tsr.inet.http.server")
local client = require("tsr.inet.http.client")
local www = require("tsr.inet.http.www")
local httpcli = require("tsr.inet.http.cli")
local socket = require("tsr.inet.socket")
local vfs = require("tsr.vfs")
local Sim = dofile("/tests/lib/inetsim.lua")

local ROOT = "/tmp/www-test"

local function site()
  if vfs.fs.exists(ROOT) then vfs.fs.delete(ROOT) end
  vfs.writeFile(ROOT .. "/index.html", "<html><head><title>Home</title></head><body><h1>Welcome</h1><p>See the <a href=\"news.html\">news</a> and the <a href=\"/docs/\">docs</a>.</p></body></html>")
  vfs.writeFile(ROOT .. "/news.html", "<html><head><title>News</title></head><body><p>Big news. <a href=\"index.html\">Back</a></p></body></html>")
  vfs.writeFile(ROOT .. "/hello.txt", "hello world")
  vfs.writeFile(ROOT .. "/data.json", '{"a":1}')
  vfs.writeFile(ROOT .. "/docs/index.txt", "documentation index")
  vfs.writeFile(ROOT .. "/docs/guide.md", "# guide")
  vfs.writeFile(ROOT .. "/.secret", "do not serve")
  vfs.writeFile(ROOT .. "/private/.hidden/x.txt", "hidden folder")
  vfs.writeFile(ROOT .. "/empty/readme", "no index here")
  vfs.writeFile(ROOT .. "/big.bin", string.rep("0123456789", 10000))
  vfs.writeFile("/tmp/www-secret-outside.txt", "outside the root")
  vfs.writeFile(ROOT .. "/404.html", "<html><body>custom missing page</body></html>")
end

test("URLs: parse, resolve, normalize, query strings, encoding", function()
  local u = assert(msg.parseUrl("http://user:pw@Example.LAN:8080/a/b.html?x=1&y=two#top"))
  eq(u.scheme, "http") eq(u.host, "example.lan") eq(u.port, 8080) eq(u.path, "/a/b.html") eq(u.query, "x=1&y=two") eq(u.fragment, "top") eq(u.user, "user") eq(u.password, "pw")
  eq(assert(msg.parseUrl("http://host")).path, "/") eq(assert(msg.parseUrl("http://host")).port, 80) eq(assert(msg.parseUrl("https://host")).port, 443)
  ok(msg.parseUrl("host/no/scheme") == nil and msg.parseUrl("http://") == nil)
  local base = assert(msg.parseUrl("http://a.lan/dir/page.html?q=1"))
  eq(msg.resolve(base, "other.html"), "http://a.lan/dir/other.html")
  eq(msg.resolve(base, "/top.html"), "http://a.lan/top.html")
  eq(msg.resolve(base, "../up.html"), "http://a.lan/up.html")
  eq(msg.resolve(base, "http://b.lan/x"), "http://b.lan/x")
  eq(msg.resolve(base, "?q=2"), "http://a.lan/dir/page.html?q=2")
  eq(msg.resolve(base, "sub/"), "http://a.lan/dir/sub/")
  eq(msg.normalizePath("/a/./b/../c//d/"), "/a/c/d/")
  eq(msg.normalizePath("/../../etc/passwd"), "/etc/passwd", "never above the root")
  eq(msg.parseQuery("a=1&b=two%20words&c=x+y&flag"), { a = "1", b = "two words", c = "x y", flag = "" })
  eq(msg.urlDecode("%41%2f"), "A/") eq(msg.urlEncode("a b/c"), "a%20b%2Fc")
  eq(msg.formatUrl(u), "http://example.lan:8080/a/b.html?x=1&y=two")
end)

test("messages: heads, headers, chunking, basic authentication, MIME types", function()
  local h = assert(msg.parseHead("GET /x HTTP/1.1\r\nHost: a.lan\r\nX-Multi: one\r\nX-Multi: two\r\nFolded: a\r\n  b\r\nContent-Type:text/plain"))
  eq(h.start, "GET /x HTTP/1.1") eq(h.headers.host, "a.lan") eq(h.headers["x-multi"], "one, two") eq(h.headers.folded, "a b") eq(h.headers["content-type"], "text/plain")
  ok(msg.parseHead("GET / HTTP/1.1\r\nbad line without colon") == nil)
  eq(msg.parseRequestLine("POST /a?b=c HTTP/1.1"), { method = "POST", target = "/a?b=c", version = "1.1" })
  ok(msg.parseRequestLine("get / HTTP/1.1") == nil and msg.parseRequestLine("GET /") == nil)
  eq(msg.parseStatusLine("HTTP/1.1 404 Not Found"), { version = "1.1", status = 404, reason = "Not Found" })
  eq(msg.formatHeaders({ ["content-type"] = "text/html", ["x-powered-by"] = "tessera" }), "Content-Type: text/html\r\nX-Powered-By: tessera\r\n")
  eq(msg.chunked("hello world", 5), "5\r\nhello\r\n5\r\n worl\r\n1\r\nd\r\n0\r\n\r\n")
  local auth = msg.basicAuth("alice", "s3cret")
  eq(auth, "Basic YWxpY2U6czNjcmV0")
  local u, p = msg.parseBasicAuth(auth)
  eq(u, "alice") eq(p, "s3cret")
  ok(msg.parseBasicAuth("Bearer abc") == nil)
  eq(msg.mimeOf("/x/page.HTML"), "text/html") eq(msg.mimeOf("a.png"), "image/png") eq(msg.mimeOf("noext"), "application/octet-stream")
end)

test("HTML: tags, entities, links, lists, tables, pre, and what is dropped", function()
  local page = html.render([[<html><head><title>My  Page</title><style>p { color: red }</style></head><body>
    <h1>Big &amp; Bold</h1>
    <p>First paragraph with a <a href="/one">link one</a> and <b>bold</b> and <i>italic</i> text that is long enough to need wrapping somewhere around here.</p>
    <ul><li>apple<li>banana</ul>
    <ol><li>first</li><li>second</li></ol>
    <pre>  keep
   this</pre>
    <table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>
    <script>alert("no")</script><!-- a comment -->
    <img src="x.png" alt="a picture"> <a href="two.html">second <b>link</b></a>
    <hr><p>&lt;done&gt; &#65; &copy;</p></body></html>]], 40)
  eq(page.title, "My Page")
  local text = html.plain(page)
  ok(text:find("Big & Bold", 1, true))
  ok(text:find("* apple", 1, true) and text:find("* banana", 1, true), text)
  ok(text:find("1. first", 1, true) and text:find("2. second", 1, true), text)
  ok(text:find("  keep\n   this", 1, true), "pre keeps its layout")
  ok(text:find("a | b", 1, true) and text:find("c | d", 1, true), text)
  ok(not text:find("alert", 1, true) and not text:find("a comment", 1, true) and not text:find("color: red", 1, true))
  ok(text:find("[image: a picture]", 1, true))
  ok(text:find("<done> A (c)", 1, true), text)
  for _, l in ipairs(page.lines) do local n = 0 for _, p in ipairs(l) do n = n + #p.text end ok(n <= 40, "line wider than 40: " .. n) end
  eq(#page.links, 2)
  eq(page.links[1].href, "/one") eq(page.links[1].text, "link one")
  eq(page.links[2].href, "two.html") eq(page.links[2].text, "second link")
  ok(page.links[1].line >= 1 and page.links[2].line > page.links[1].line)
  -- plain text is shown as it is
  local t = html.render("line one\nline two", 20, true)
  eq(#t.lines, 2)
  -- broken markup does not crash
  ok(html.render("<p><b>unclosed <a href=x>link <div>stuff", 30))
  ok(html.render("<<<>>> & &bogus; <", 30))
end)

test("server: files, types, index pages, listings, conditional and range requests, errors", function()
  site()
  local sim = Sim.new()
  local s = sim:host("s")
  local srv = serverMod.new(s, { root = ROOT, errors = { [404] = "/404.html" }, index = { "index.html", "index.txt" } })
  local function get(target, headers, method)
    return srv:handle({ method = method or "GET", target = target, headers = headers or { host = "x" }, body = "", ip = "10.0.0.9" })
  end
  local r = get("/hello.txt")
  eq(r.status, 200) eq(r.body, "hello world") eq(r.headers["content-type"], "text/plain") ok(r.headers.etag)
  eq(get("/data.json").headers["content-type"], "application/json")
  eq(get("/").body:find("<h1>Welcome</h1>", 1, true) ~= nil, true, "index.html of the root")
  eq(get("/docs/").body, "documentation index", "index.txt of a folder")
  local moved = get("/docs")
  eq(moved.status, 301) eq(moved.headers.location, "/docs/")
  eq(get("/empty/").status, 403, "no index and no listing")
  srv.listing = true
  local listing = get("/empty/")
  eq(listing.status, 200) ok(listing.body:find("readme", 1, true) and listing.body:find("Index of /empty/", 1, true))
  ok(not get("/").body:find("Index of", 1, true), "an index page wins over the listing")
  srv.listing = false
  -- not found, with the custom page
  local nf = get("/nothing.html")
  eq(nf.status, 404) ok(nf.body:find("custom missing page", 1, true))
  -- the road to files outside the root and to hidden files is closed
  eq(get("/../www-secret-outside.txt").status, 403, "'..' cannot climb")
  eq(get("/%2e%2e/www-secret-outside.txt").status, 403)
  eq(get("/.secret").status, 403) eq(get("/private/.hidden/x.txt").status, 403) eq(get("/docs/%2e%2e/%2e%2e/x").status, 403)
  eq(get("/hello.txt%00.png").status, 403, "NUL bytes")
  -- conditional requests
  local etag = get("/hello.txt").headers.etag
  eq(get("/hello.txt", { host = "x", ["if-none-match"] = etag }).status, 304)
  -- ranges
  local rg = get("/hello.txt", { host = "x", range = "bytes=0-4" })
  eq(rg.status, 206) eq(rg.body, "hello") eq(rg.headers["content-range"], "bytes 0-4/11")
  eq(get("/hello.txt", { host = "x", range = "bytes=-5" }).body, "world")
  eq(get("/hello.txt", { host = "x", range = "bytes=6-" }).body, "world")
  eq(get("/hello.txt", { host = "x", range = "bytes=50-60" }).status, 416)
  -- methods
  eq(get("/hello.txt", nil, "OPTIONS").status, 204)
  eq(get("/hello.txt", nil, "DELETE").status, 405)
  eq(get("/hello.txt", nil, "POST").status, 405, "POST needs a handler")
  eq(get("/hello.txt", nil, "HEAD").status, 200)
  eq(get("/x?" .. string.rep("a", 3000)).status, 414)
end)

test("server: handlers, forms, authentication, virtual hosts, rate limits, logging", function()
  site()
  vfs.writeFile("/tmp/www-vhost/index.html", "the shop")
  vfs.fs.delete("/tmp/www-test.log")
  local sim = Sim.new()
  local s = sim:host("s")
  local hashed = serverMod.hashPassword("secret")
  local srv = serverMod.new(s, {
    root = ROOT, vhosts = { ["shop.lan"] = { root = "/tmp/www-vhost" } }, accessLog = "/tmp/www-test.log",
    routes = {
      ["/api/echo"] = function(req, res) res.body = req.method .. ":" .. (req.params.q or "-") .. ":" .. req.body end,
      ["/api/json"] = function(req, res) res.headers["content-type"] = "application/json" return '{"ok":true}' end,
      ["/api/boom"] = function() error("handler crashed") end,
      ["/tree/*"] = function(req, res) res.body = "tree" .. req.path end,
    },
    auth = { { path = "/private", realm = "Staff", users = { alice = hashed } } },
  })
  local function call(method, target, headers, body, ip)
    local h = { host = "x" }
    for k, v in pairs(headers or {}) do h[k] = v end
    return srv:handle({ method = method, target = target, headers = h, body = body or "", ip = ip or "10.0.0.1" })
  end
  eq(call("GET", "/api/echo?q=hi").body, "GET:hi:")
  eq(call("POST", "/api/echo?q=1", nil, "payload").body, "POST:1:payload")
  eq(call("GET", "/api/json").headers["content-type"], "application/json")
  eq(call("GET", "/api/boom").status, 500)
  eq(call("GET", "/tree/a/b").body, "tree/tree/a/b")
  -- authentication
  local denied = call("GET", "/private/")
  eq(denied.status, 401) ok(denied.headers["www-authenticate"]:find('realm="Staff"', 1, true))
  eq(call("GET", "/private/x.txt", { authorization = msg.basicAuth("alice", "wrong") }).status, 401)
  eq(call("GET", "/private/x.txt", { authorization = msg.basicAuth("mallory", "secret") }).status, 401)
  vfs.writeFile(ROOT .. "/private/x.txt", "staff only")
  eq(call("GET", "/private/x.txt", { authorization = msg.basicAuth("alice", "secret") }).body, "staff only")
  ok(hashed:find("^%x+%$%x+$"))
  ok(serverMod.hashPassword("secret", "abc") ~= serverMod.hashPassword("secrex", "abc"))
  -- virtual hosts
  eq(call("GET", "/", { host = "shop.lan" }).body, "the shop")
  eq(call("GET", "/", { host = "shop.lan:8080" }).body, "the shop")
  ok(call("GET", "/", { host = "other.lan" }).body:find("Welcome", 1, true))
  -- rate limit per client address
  srv.rate = 5
  local limited = 0
  for _ = 1, 8 do if call("GET", "/hello.txt", nil, nil, "10.0.0.77").status == 429 then limited = limited + 1 end end
  ok(limited >= 3, "limited " .. limited)
  eq(call("GET", "/hello.txt", nil, nil, "10.0.0.78").status, 200, "other clients are not affected")
  eq(srv.stats.limited, limited)
end)

local function netWith(cfg)
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local s, c = sim:host("s"), sim:host("c")
  sim:plug(s, "eth0", seg, "10.0.0.1/24")
  sim:plug(c, "eth0", seg, "10.0.0.2/24")
  c:addHost("web.lan", "10.0.0.1")
  site()
  cfg = cfg or {}
  cfg.root = cfg.root or ROOT
  local srv = serverMod.new(s, cfg)
  for _, job in ipairs(assert(srv:workers(3))) do local t = sim:spawn(job) t.daemon = true end
  sim:run(0.1)
  return sim, s, c, srv
end

test("over the network: client and server, redirects, keep-alive, big files, posted data, timeouts", function()
  local sim, s, c, srv = netWith({ routes = { ["/api/echo"] = function(req, res) return req.method .. ":" .. req.body end } })
  srv.cfg.routes = srv.routes
  srv.routes["/go"] = function(req, res) res.status = 302 res.headers.location = "/hello.txt" end
  srv.routes["/loop"] = function(req, res) res.status = 302 res.headers.location = "/loop" end
  srv.routes["/post-redirect"] = function(req, res) res.status = 303 res.headers.location = "/api/echo" end
  local r = assert(client.get("http://web.lan/hello.txt", { stack = c }))
  eq(r.status, 200) eq(r.body, "hello world") eq(r.headers["content-length"], "11") eq(r.headers.server, serverMod.SERVER_NAME)
  local home = assert(client.get("http://10.0.0.1/", { stack = c }))
  ok(home.body:find("Welcome", 1, true))
  local missing = assert(client.get("http://web.lan/nothing", { stack = c }))
  eq(missing.status, 404)
  local redirected = assert(client.get("http://web.lan/go", { stack = c }))
  eq(redirected.body, "hello world") eq(redirected.redirects, 1)
  local loop, err = client.get("http://web.lan/loop", { stack = c })
  ok(loop == nil and err == "too many redirects", tostring(err))
  eq(assert(client.get("http://web.lan/go", { stack = c, follow = false })).status, 302)
  local posted = assert(client.post("http://web.lan/api/echo", "a=1&b=2", { stack = c }))
  eq(posted.body, "POST:a=1&b=2")
  eq(assert(client.request({ url = "http://web.lan/post-redirect", method = "POST", body = "x", stack = c })).body, "GET:", "303 turns a POST into a GET")
  local big = assert(client.get("http://web.lan/big.bin", { stack = c }))
  eq(#big.body, 100000) eq(big.body:sub(1, 20), "01234567890123456789")
  local head = assert(client.request({ url = "http://web.lan/big.bin", method = "HEAD", stack = c }))
  eq(head.body, "") eq(head.headers["content-length"], "100000")
  -- an unreachable name or port
  local r2, e2 = client.get("http://nowhere.lan/", { stack = c })
  ok(r2 == nil and e2:find("cannot resolve", 1, true) or e2:find("cannot connect", 1, true), tostring(e2))
  local r3, e3 = client.get("http://web.lan:81/", { stack = c, timeout = 3 })
  ok(r3 == nil and e3:find("cannot connect", 1, true), tostring(e3))
  local r4, e4 = client.get("https://web.lan/", { stack = c })
  ok(r4 == nil and (e4:find("secure connection", 1, true) or e4:find("cannot connect", 1, true)), tostring(e4))
  -- keep-alive: two requests over one connection
  local conn = socket.tcp(c)
  assert(conn:connect("10.0.0.1", 80, 3))
  conn:send("GET /hello.txt HTTP/1.1\r\nHost: x\r\n\r\nGET /data.json HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  local all = conn:receive("*a", 5)
  ok(all:find("hello world", 1, true) and all:find('{"a":1}', 1, true) and all:find("Connection: keep%-alive") and all:find("Connection: close"), all)
  eq(srv.stats.requests >= 10, true)
  -- garbage and oversized requests are answered, not crashed on
  local g = socket.tcp(c)
  assert(g:connect("10.0.0.1", 80, 3))
  g:send("this is not http\r\n\r\n")
  ok(g:receive("*a", 5):find("400 Bad Request", 1, true))
  local g2 = socket.tcp(c)
  assert(g2:connect("10.0.0.1", 80, 3))
  g2:send("POST /api/echo HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999\r\n\r\n")
  ok(g2:receive("*a", 5):find("413", 1, true))
  local g3 = socket.tcp(c)
  assert(g3:connect("10.0.0.1", 80, 3))
  g3:send("GET / HTTP/1.1\r\nHost: x\r\n" .. string.rep("X-Pad: " .. string.rep("a", 200) .. "\r\n", 100) .. "\r\n")
  ok(g3:receive("*a", 5):find("431", 1, true), "huge headers")
  -- a chunked request body
  local ch = socket.tcp(c)
  assert(ch:connect("10.0.0.1", 80, 3))
  ch:send("POST /api/echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .. msg.chunked("hello chunked world", 6))
  ok(ch:receive("*a", 5):find("POST:hello chunked world", 1, true))
end)

test("the client reads chunked bodies, bodies without a length, and survives a server that goes quiet", function()
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local s, c = sim:host("s"), sim:host("c")
  sim:plug(s, "eth0", seg, "10.0.0.1/24") sim:plug(c, "eth0", seg, "10.0.0.2/24")
  local replies = {
    ["/chunked"] = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n" .. msg.chunked("chunked body arrives in pieces", 7),
    ["/nolength"] = "HTTP/1.0 200 OK\r\n\r\nbody until close",
    ["/empty"] = "HTTP/1.1 204 No Content\r\n\r\n",
    ["/silent"] = false,
  }
  local th = sim:spawn(function()
    local l = socket.tcp(s)
    l:bind(nil, 80) l:listen(4)
    while true do
      local conn = l:accept(60)
      if not conn then return end
      local line = conn:receive("*l", 5)
      local path = line and line:match("^%u+ (%S+)")
      repeat local h = conn:receive("*l", 5) until h == "" or h == nil
      local reply = replies[path]
      if reply then conn:send(reply) end
      if reply ~= false then conn:close() else sim:waitFor(function() return false end, 30) end
    end
  end)
  th.daemon = true
  sim:run(0.1)
  eq(assert(client.get("http://10.0.0.1/chunked", { stack = c })).body, "chunked body arrives in pieces")
  eq(assert(client.get("http://10.0.0.1/nolength", { stack = c })).body, "body until close")
  eq(assert(client.get("http://10.0.0.1/empty", { stack = c })).status, 204)
  local r, err = client.get("http://10.0.0.1/silent", { stack = c, timeout = 2 })
  ok(r == nil and err:find("no response", 1, true), tostring(err))
end)

local function fakeTerm(w, h)
  local t = { w = w, h = h, rows = {}, x = 1, y = 1, fg = colors.white, bg = colors.black }
  for r = 1, h do t.rows[r] = string.rep(" ", w) end
  function t.getSize() return w, h end
  function t.isColor() return true end
  function t.setCursorPos(x, y) t.x, t.y = x, y end
  function t.setTextColor(c) t.fg = c end
  function t.setBackgroundColor(c) t.bg = c end
  function t.clear() for r = 1, h do t.rows[r] = string.rep(" ", w) end end
  function t.clearLine() t.rows[t.y] = string.rep(" ", w) end
  function t.write(s)
    local row = t.rows[t.y]
    if row then t.rows[t.y] = (row:sub(1, t.x - 1) .. s .. row:sub(t.x + #s)):sub(1, w) end
    t.x = t.x + #s
  end
  return t
end

test("the browser: loads a page, scrolls, follows links with Tab/Enter and clicks, goes back, saves", function()
  local sim, s, c, srv = netWith()
  local t = fakeTerm(40, 12)
  local queue, prompts = {}, { "web.lan/news.html" }
  local function key(k) queue[#queue + 1] = { "key", keys[k] } end
  local origin = coroutine.wrap(function() end)
  -- run the browser as a simulated thread; its events come from the queue
  local result
  local th = sim:spawn(function()
    result = www.browse("http://web.lan/", { term = t, stack = c,
      events = function() while #queue == 0 do sim:waitFor(function() return #queue > 0 end, 5) end return table.remove(queue, 1) end,
      prompt = function(text) return table.remove(prompts, 1) end })
  end)
  sim:run(2)
  local screen = table.concat(t.rows, "\n")
  ok(t.rows[1]:find("Home", 1, true), "title bar: " .. t.rows[1])
  ok(screen:find("Welcome", 1, true) and screen:find("news", 1, true) and screen:find("docs", 1, true), screen)
  ok(t.rows[12]:find("http://web.lan/news.html", 1, true), "the status line shows where the selected link goes: " .. t.rows[12])
  key("tab") sim:run(0.5)
  ok(t.rows[12]:find("http://web.lan/docs/", 1, true), t.rows[12])
  key("enter") sim:run(2)
  ok(t.rows[1]:find("docs", 1, true) or t.rows[2]:find("documentation index", 1, true), t.rows[1] .. " / " .. t.rows[2])
  key("backspace") sim:run(2)
  ok(t.rows[1]:find("Home", 1, true), "back to the first page")
  -- G types an address
  key("g") sim:run(2)
  ok(t.rows[1]:find("News", 1, true), "went to the typed address: " .. t.rows[1])
  -- a click on a link
  queue[#queue + 1] = { "mouse_click", 1, 3, 3 }
  sim:run(0.5)
  -- save the page
  prompts[#prompts + 1] = "/tmp/saved-page.html"
  key("s") sim:run(1)
  ok(vfs.readFile("/tmp/saved-page.html", true):find("Big news", 1, true) or vfs.readFile("/tmp/saved-page.html", true):find("Welcome", 1, true))
  key("q") sim:run(1)
  eq(result, true)
  vfs.fs.delete("/tmp/saved-page.html")
  -- a missing page shows an error line instead of crashing
  local t2 = fakeTerm(40, 10)
  local page = www.load("http://web.lan/nothing", 40, { stack = c })
  eq(page.status, 404)
  local broken, err = www.load("http://nowhere.lan/", 40, { stack = c })
  ok(broken == nil)
  local textPage = www.load("http://web.lan/hello.txt", 40, { stack = c })
  eq(html.plain(textPage), "hello world")
  local bin = www.load("http://web.lan/big.bin", 40, { stack = c })
  ok(html.plain(bin):find("not text", 1, true))
  local localFile = www.load("file://" .. ROOT .. "/news.html", 40)
  eq(localFile.title, "News")
end)

test("the fetch command", function()
  local sim, s, c, srv = netWith({ routes = { ["/api/echo"] = function(req, res) return (req.headers["x-test"] or "") .. "|" .. req.method .. "|" .. req.body end } })
  srv.routes = srv.routes
  local lines, errs = {}, {}
  local ctx = { stack = c, say = function(t) lines[#lines + 1] = t end, err = function(t) errs[#errs + 1] = t end }
  ok(httpcli.fetch({ "web.lan/hello.txt" }, ctx), table.concat(errs))
  eq(lines[1], "hello world")
  lines = {}
  ok(httpcli.fetch({ "-I", "http://web.lan/hello.txt" }, ctx))
  ok(lines[1] == "HTTP/1.1 200 OK" and table.concat(lines, "\n"):find("content%-type: text/plain"))
  lines = {}
  ok(httpcli.fetch({ "-d", "payload", "-H", "X-Test: yes", "http://web.lan/api/echo" }, ctx))
  eq(lines[1], "yes|POST|payload")
  lines = {}
  ok(httpcli.fetch({ "-o", "/tmp/fetched.txt", "http://web.lan/hello.txt" }, ctx))
  eq(vfs.readFile("/tmp/fetched.txt", true), "hello world")
  vfs.fs.delete("/tmp/fetched.txt")
  ok(not httpcli.fetch({ "http://web.lan/missing" }, ctx), "a 404 is a failure")
  ok(not httpcli.fetch({}, ctx))
end)

test("https: the web server and client over the secure channel", function()
  local tls = require("tsr.inet.tls")
  local cert = require("tsr.inet.tls.cert")
  local crypto = require("tsr.crypto")
  local dir = "/tmp/tls-web-test"
  if vfs.fs.exists(dir) then vfs.fs.delete(dir) end
  vfs.fs.makeDir(dir) vfs.fs.makeDir(dir .. "/ca")
  local ca = crypto.signingKey(string.rep("\1", 32))
  local key = crypto.signingKey(string.rep("\2", 32))
  local c = cert.issue({ subject = "web.lan", key = key.public, issuerName = "Lab CA", issuerKey = ca })
  vfs.writeFile(dir .. "/web.lan.crt", cert.encode(c))
  tls.saveKey(dir .. "/web.lan.key", key)
  local store = tls.store({ dir = dir, tofu = false })
  local sim, s, cl, srv = netWith({ port = 443, tls = { name = "web.lan", dir = dir } })
  local r, err = client.get("https://web.lan/hello.txt", { stack = cl, tlsStore = store })
  ok(r == nil and err:find("untrusted", 1, true), "the CA is not trusted yet: " .. tostring(err))
  store:addCa(cert.selfSigned("Lab CA", ca, { ca = true }))
  local good = assert(client.get("https://web.lan/hello.txt", { stack = cl, tlsStore = store }))
  eq(good.status, 200) eq(good.body, "hello world")
  local home = assert(client.get("https://web.lan/", { stack = cl, tlsStore = store }))
  ok(home.body:find("Welcome", 1, true))
  -- plain http to the TLS port gets nothing useful
  local plain = client.get("http://web.lan:443/", { stack = cl, timeout = 3 })
  ok(plain == nil or plain.status ~= 200)
  vfs.fs.delete(dir)
end)
