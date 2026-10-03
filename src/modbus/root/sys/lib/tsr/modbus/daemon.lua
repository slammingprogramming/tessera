-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The modbusd service: a Modbus/TCP slave on port 502 (settings and address map in /etc/tsr/modbus.lua; `modbusctl init` writes an example).
local socket = require("tsr.inet.socket")
local serverMod = require("tsr.modbus.server")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("modbusd")

local M = {}

M.CONFIG = "/etc/tsr/modbus.lua"

M.TEMPLATE = [[
-- Modbus/TCP slave. After a change: svc restart modbusd
-- Point kinds: { rs = "back:red" } redstone port, { dev = "name", read = "reading", on = "action", off = "action", scale = n } a machine or sensor (hal list),
-- { var = "name", init = 0 } a stored value, { const = 5 } a fixed value, { read = function() ... end, write = function(v) ... end } your own code.
return {
  port = 502,
  allow = { "10.0.0.0/24" },    -- only these networks may connect (empty = everybody: not recommended)
  readonly = false,             -- true: nobody may change anything
  units = {
    [1] = {
      coils = {                 -- on/off outputs you can set
        [0] = { rs = "back" },
      },
      inputs = {                -- on/off sensors
        [0] = { rs = "left" },
      },
      registers = {             -- measurements (16-bit numbers)
        [0] = { rs = "right", analog = true },
      },
      holding = {               -- values you can set
        [0] = { var = "setpoint", init = 50 },
      },
    },
  },
}
]]

function M.loadConfig()
  local text = vfs.readFile(M.CONFIG)
  if not text then return nil, M.CONFIG .. " does not exist (modbusctl init)" end
  local chunk, err = load(text, "=modbus.lua", "t", {})
  if not chunk then return nil, err end
  local ok, value = pcall(chunk)
  if not ok or type(value) ~= "table" then return nil, tostring(value) end
  return value
end

function M.main()
  local stack
  while true do
    local ok, s = pcall(socket.default)
    if ok then stack = s break end
    os.sleep(1)
  end
  local cfg, err = M.loadConfig()
  if not cfg then log.error("%s", tostring(err)) return end
  cfg.onWrite = function(unit, kind, addr, value) log.info("%s", ("unit %s: %s %s set to %s"):format(tostring(unit), kind, tostring(addr), tostring(value))) end
  local okS, srv = pcall(serverMod.new, cfg)
  if not okS then log.error("%s", tostring(srv)) return end
  M.server = srv
  local listener = socket.tcp(stack)
  listener:bind(nil, cfg.port or 502)
  local ok, lerr = listener:listen(8)
  if not ok then log.error("%s", "cannot listen: " .. tostring(lerr)) return end
  M.listener = listener
  M.running = true
  local jobs = {}
  for _ = 1, cfg.maxConnections or 6 do
    jobs[#jobs + 1] = function()
      while M.running do
        local c = listener:accept(1)
        if c then pcall(srv.serve, srv, c) end
      end
    end
  end
  log.info("%s", ("Modbus slave on port %d"):format(cfg.port or 502))
  parallel.waitForAny(table.unpack(jobs))
end

function M.stop()
  M.running = false
  if M.listener then M.listener:close() end
end

return M
