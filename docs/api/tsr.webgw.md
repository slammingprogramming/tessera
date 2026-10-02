# tsr.webgw

Package: `webgw`

Web gateway client. A ComputerCraft computer cannot accept inbound connections, so it connects OUT (a WebSocket) to a small
gateway program (tools/gateway/gateway.mjs in the Tessera source) that you run on a machine of your own; the gateway turns
HTTP requests from browsers and scripts into calls the computer answers.

  webgw setup <ws://host:port/ws> <token> [service...]     remember where to connect and which services may be called
  webgw status | expose <service...> | test

Protocol (JSON, one message per frame):
  gateway -> computer   {"id": 1, "op": "call", "service": "metrics", "method": "get", "args": {...}, "target": "local"|"<paired peer>"}
                        {"id": 2, "op": "ping"}   {"id": 3, "op": "list"}
  computer -> gateway   {"id": 1, "ok": true, "result": ...}  |  {"id": 1, "ok": false, "error": "..."}
Only services listed in `expose` can be called, whatever the gateway asks for; calls to other computers need pairing as usual.

## `M.handle(msg, node, cfg)`

Answer one gateway message. Returns the reply table.

## `M.session(ws, node, cfg, shouldStop)`

Serve one connected websocket until it closes. `ws` needs receive(timeout) -> text|nil, send(text), close().

## `M.run(node, connect)`

Connect and serve forever, reconnecting with backoff. `connect(url, headers)` defaults to http.websocket.

## `M.cli(args, io)`

webgw setup <url> <token> [services...] | status | expose <services...>
