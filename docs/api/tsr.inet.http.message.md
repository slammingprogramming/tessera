# tsr.inet.http.message

Package: `web`

HTTP/1.1 messages (RFC 9110, 9112): URLs, request and status lines, headers, Content-Length and chunked bodies, percent-encoding, MIME types.

## `M.parseUrl(text)`

"http://user:pw@host:8080/path?query#frag" -> { scheme, host, port, path, query, fragment, user, password }. Returns nil + reason for what is not a URL.

## `M.resolve(base, ref)`

Resolve `ref` (absolute URL, "/path", "page.html", "?q") against the page `base` (a parsed URL). Returns a URL string.

## `M.normalizePath(path)`

Collapse "." and ".." segments. The result never climbs above the root.

## `M.parseQuery(q)`

"a=1&b=two%20words" -> { a = "1", b = "two words" }

## `M.parseHead(text)`

Parse the head of a request or response (everything up to the blank line). Returns { start = "GET / HTTP/1.1", headers = {..} } or nil + reason.

## `M.formatHeaders(headers)`

Format a header table: keys are written in Capital-Case.

## `M.chunked(body, size)`

Encode a body with chunked transfer encoding (pieces of at most `size` bytes).

## `M.basicAuth(user, password)`

Basic authentication header value for user and password.
