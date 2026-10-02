-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Kiosk mode: run one program for ever. If it ends or crashes it is started again after a short pause, and Ctrl+T does not stop it
-- (the program is run with `os.pullEvent` ignoring terminate). Meant for public screens where nobody should reach a shell.
--   /etc/tsr/kiosk.cfg  { command = "play /media/loop.bimg --loop --monitor tv", delay = 2 }
--   kiosk set <command...> | status | run        (run in the foreground; the kioskd service does it at boot)
-- To get out: stop the service from another computer (`svc stop kioskd`) or remove /etc/tsr/kiosk.cfg and restart.
local vfs = require("tsr.vfs")

local M = {}

M.CFG_PATH = "/etc/tsr/kiosk.cfg"

function M.loadConfig() return vfs.readTable(M.CFG_PATH) or {} end

--- An `os` for kiosk programs: terminate events are swallowed.
function M.protectedOs()
  local function pull(filter)
    while true do
      local ev = table.pack(os.pullEventRaw(filter))
      if ev[1] ~= "terminate" then return table.unpack(ev, 1, ev.n) end
    end
  end
  return setmetatable({ pullEvent = pull }, { __index = os })
end

--- Run the command once. runner(line) -> status; tests replace it. Returns whatever the runner returns.
function M.runOnce(cfg, runner)
  runner = runner or function(line)
    local exec = require("tsr.shell.exec")
    local sh = exec.new({ parentShell = rawget(_G, "shell"), programOs = M.protectedOs() })
    return sh:runLine(line)
  end
  local ok, res = pcall(runner, cfg.command)
  return ok, res
end

--- The restart loop. env: runner, sleep, maxRuns (tests). Returns the number of runs.
function M.run(cfg, env)
  env = env or {}
  cfg = cfg or M.loadConfig()
  if not cfg.command or cfg.command == "" then return nil, "no command set: kiosk set <command>" end
  local pause = env.sleep or sleep
  local runs = 0
  while true do
    M.runOnce(cfg, env.runner)
    runs = runs + 1
    if env.maxRuns and runs >= env.maxRuns then return runs end
    pcall(pause, cfg.delay or 2)           -- a stray Ctrl+T during the pause must not end the kiosk either
  end
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

function M.cli(args, io, env)
  io = io or defaultIO()
  local cmd = args[1] or "status"
  if cmd == "set" then
    if not args[2] then io.err("usage: kiosk set <command...>") return false end
    local cfg = M.loadConfig()
    cfg.command = table.concat(args, " ", 2)
    vfs.writeTable(M.CFG_PATH, cfg)
    io.say("Kiosk command: " .. cfg.command)
    io.say("Start it at boot with: svc enable kioskd")
    return true
  elseif cmd == "status" then
    local cfg = M.loadConfig()
    io.say("command: " .. tostring(cfg.command or "(none)"))
    return true
  elseif cmd == "run" then
    local n, err = M.run(M.loadConfig(), env)
    if not n then io.err(err) return false end
    return true
  end
  io.err("usage: kiosk set <command> | status | run")
  return false
end

function M.main(args) return M.cli(args) end

function M.daemon()
  local n, err = M.run(M.loadConfig(), {})
  if not n then error(err, 0) end
end

return M
