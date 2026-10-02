-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The httpd service (configuration in /etc/tsr/inet/httpd.lua; the default serves /srv/www on port 80).
local socket = require("tsr.inet.socket")
local server = require("tsr.inet.http.server")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("httpd")

local M = {}

M.CONFIG = "/etc/tsr/inet/httpd.lua"

local WELCOME = [[<html><head><title>It works</title></head><body>
<h1>It works!</h1>
<p>This computer runs a Tessera web server. Put your pages into <b>/srv/www</b>.</p>
<p>Settings: <b>/etc/tsr/inet/httpd.lua</b></p>
</body></html>
]]

function M.main()
  local stack
  while true do
    local ok, s = pcall(socket.default)
    if ok then stack = s break end
    os.sleep(1)
  end
  local cfg = {}
  local text = vfs.readFile(M.CONFIG)
  if text then
    local chunk, err = load(text, "=httpd.lua", "t", { os = { epoch = os.epoch, time = os.time, clock = os.clock }, string = string, table = table, math = math, tostring = tostring, tonumber = tonumber })
    local ok, value = false, err
    if chunk then ok, value = pcall(chunk) end
    if not ok or type(value) ~= "table" then log.error("%s", "httpd.lua: " .. tostring(value)) return end
    cfg = value
  end
  cfg.root = cfg.root or "/srv/www"
  if not vfs.fs.exists(cfg.root .. "/index.html") and not vfs.fs.exists(cfg.root .. "/index.txt") then
    vfs.writeFile(cfg.root .. "/index.html", WELCOME)
  end
  local srv = server.new(stack, cfg)
  M.server = srv
  local jobs, err = srv:workers(4)
  if not jobs then log.error("%s", tostring(err)) return end
  log.info("%s", ("web server on port %d, serving %s"):format(srv.port, cfg.root))
  parallel.waitForAny(table.unpack(jobs))
end

return M
