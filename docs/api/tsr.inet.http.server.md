# tsr.inet.http.server

Package: `web`

A web server for the in-game network: static files with the right types, index pages, conditional and range requests, virtual hosts, password-protected
areas, handlers written in Lua (for APIs, status pages, forms), per-address rate limits, an access log. HTTP/1.1 with keep-alive and chunked request
bodies. It never serves files outside its document root, and never files or folders whose names start with a dot.

  server = require("tsr.inet.http.server").new(stack, {
    port = 80, root = "/srv/www", index = { "index.html", "index.txt" }, listing = false,
    vhosts = { ["shop.lan"] = { root = "/srv/shop" } },
    routes = { ["/api/time"] = function(req, res) res.body = tostring(os.epoch("utc")) end },        -- exact path or "/prefix/*"
    auth = { { path = "/admin", realm = "Admin", users = { alice = server.hashPassword("secret") } } },
    errors = { [404] = "/404.html" }, accessLog = "/var/log/httpd.access.log", rate = 120,
  })
  server:serve()                -- blocks; or parallel.waitForAny(table.unpack(server:workers()))

## `M.hashPassword(password, salt)`

A password hash for the `auth` configuration: "salt$sha256(salt .. password)" (iterated 1000 times).

## `Server:handle(req)`

Turn a request table { method, target, headers, body, ip } into a response table { status, headers, body }.

## `Server:connection(conn)`

Serve one connection until it closes (keep-alive: several requests).

## `Server:workers(n)`

Worker functions to run side by side (parallel.waitForAny, or sim:spawn each): `n` acceptors.
