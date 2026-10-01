-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Web gateway client. A ComputerCraft computer cannot accept inbound connections, so it connects OUT (a WebSocket) to a small
-- gateway program (tools/gateway/gateway.mjs in the Tessera source) that you run on a machine of your own; the gateway turns
-- HTTP requests from browsers and scripts into calls the computer answers.
--
--   webgw setup <ws://host:port/ws> <token> [service...]     remember where to connect and which services may be called
--   webgw status | expose <service...> | test
--
-- Protocol (JSON, one message per frame):
--   gateway -> computer   {"id": 1, "op": "call", "service": "metrics", "method": "get", "args": {...}, "target": "local"|"<paired peer>"}
--                         {"id": 2, "op": "ping"}   {"id": 3, "op": "list"}
--   computer -> gateway   {"id": 1, "ok": true, "result": ...}  |  {"id": 1, "ok": false, "error": "..."}
-- Only services listed in `expose` can be called, whatever the gateway asks for; calls to other computers need pairing as usual.
local vfs = require("tsr.vfs")

local M = {}

M.CFG_PATH = "/etc/tsr/webgw.cfg"

function M.loadConfig() return vfs.readTable(M.CFG_PATH) or {} end
function M.saveConfig(cfg) return vfs.writeTable(M.CFG_PATH, cfg) end

local function exposed(cfg, service)
  for _, s in ipairs(cfg.expose or {}) do
    if s == service then return true end
  end
  return false
end

--- Answer one gateway message. Returns the reply table.
function M.handle(msg, node, cfg)
  local reply = { id = msg.id }
  if type(msg) ~= "table" then return { ok = false, error = "bad message" } end
  if msg.op == "ping" then
    reply.ok, reply.result = true, { host = node.hostname, id = node.id }
  elseif msg.op == "list" then
    reply.ok = true
    local peers = {}
    for _, p in ipairs(node:peers()) do peers[#peers + 1] = p.name end
    reply.result = { host = node.hostname, expose = cfg.expose or {}, peers = peers }
  elseif msg.op == "call" then
    if type(msg.service) ~= "string" or type(msg.method) ~= "string" then
      reply.ok, reply.error = false, "service and method are required"
    elseif not exposed(cfg, msg.service) then
      reply.ok, reply.error = false, "service '" .. msg.service .. "' is not exposed"
    else
      local target = msg.target
      if target == nil or target == "local" then
        local svc = node.services[msg.service]
        if not svc then
          reply.ok, reply.error = false, "no such service here"
        else
          local ok, res = pcall(svc.handler, 0, msg.method, msg.args)
          if ok then reply.ok, reply.result = true, res else reply.ok, reply.error = false, tostring(res) end
        end
      else
        local res, err = node:call(target, msg.service, msg.method, msg.args, { timeout = 8 })
        if res == nil and err then reply.ok, reply.error = false, tostring(err) else reply.ok, reply.result = true, res end
      end
    end
  else
    reply.ok, reply.error = false, "unknown op"
  end
  return reply
end

--- Serve one connected websocket until it closes. `ws` needs receive(timeout) -> text|nil, send(text), close().
function M.session(ws, node, cfg, shouldStop)
  while true do
    if shouldStop and shouldStop() then return "stopped" end
    local text = ws.receive(5)
    if text ~= nil then
      local msg = textutils.unserializeJSON(text)
      local reply
      if type(msg) == "table" then reply = M.handle(msg, node, cfg) else reply = { ok = false, error = "bad json" } end
      ws.send(textutils.serializeJSON(reply))
    end
  end
end

--- Connect and serve forever, reconnecting with backoff. `connect(url, headers)` defaults to http.websocket.
function M.run(node, connect)
  connect = connect or function(url, headers) return http.websocket(url, headers) end
  local delay = 5
  while true do
    local cfg = M.loadConfig()
    if cfg.url and cfg.token then
      local ws, err = connect(cfg.url, { Authorization = "Bearer " .. cfg.token, ["X-Computer"] = node.hostname })
      if ws then
        delay = 5
        local realWs = {
          receive = function(t) return ws.receive(t) end,
          send = function(t) ws.send(t) end,
          close = function() ws.close() end,
          closed = function() return false end,
        }
        -- receive() returns nil on a timeout and raises an error when the connection has closed
        local ok, e = pcall(M.session, realWs, node, cfg)
        pcall(ws.close)
        if not ok then require("tsr.log").get("webgw").warn("connection lost: %s", tostring(e)) end
      else
        require("tsr.log").get("webgw").debug("cannot connect to %s: %s", tostring(cfg.url), tostring(err))
      end
    end
    sleep(delay)
    delay = math.min(60, delay * 2)
  end
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

--- webgw setup <url> <token> [services...] | status | expose <services...>
function M.cli(args, io)
  io = io or defaultIO()
  local cmd = args[1] or "status"
  if cmd == "setup" then
    local url, token = args[2], args[3]
    if not url or not token or not url:match("^wss?://") then io.err("usage: webgw setup <ws://host:port/ws> <token> [service...]") return false end
    if #token < 12 then io.err("use a token of at least 12 characters") return false end
    local cfg = M.loadConfig()
    cfg.url, cfg.token = url, token
    cfg.expose = cfg.expose or { "metrics" }
    if args[4] then cfg.expose = { table.unpack(args, 4) } end
    M.saveConfig(cfg)
    io.say("Saved. Start the connection with: svc enable webgwd")
    return true
  elseif cmd == "expose" then
    local cfg = M.loadConfig()
    cfg.expose = { table.unpack(args, 2) }
    M.saveConfig(cfg)
    io.say("Exposed: " .. (#cfg.expose > 0 and table.concat(cfg.expose, ", ") or "nothing"))
    return true
  elseif cmd == "status" then
    local cfg = M.loadConfig()
    io.say("gateway: " .. tostring(cfg.url or "not set up"))
    io.say("exposed: " .. ((cfg.expose and #cfg.expose > 0) and table.concat(cfg.expose, ", ") or "nothing"))
    return true
  end
  io.err("usage: webgw setup <url> <token> [service...] | expose <services...> | status")
  return false
end

function M.main(args) return M.cli(args) end

function M.daemon()
  M.run(require("tsr.net").default())
end

return M
