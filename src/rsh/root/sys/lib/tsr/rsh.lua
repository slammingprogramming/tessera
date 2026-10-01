-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Remote shell.
--   rsh <peer>                 interactive session on a paired computer
--   rsh <peer> <command...>    run one command there and print its output (also: rexec)
--   rsh allow <peer> | deny <peer> | allowed      choose who may run commands HERE (nobody, until you allow them)
--
-- A remote command is as powerful as typing at the keyboard, so access is limited to paired computers you named. Commands run
-- in a tsh session that is kept per remote computer (working directory and variables persist between commands) inside their
-- own process with a time limit; programs that wait for the keyboard are stopped when the limit passes.
local vfs = require("tsr.vfs")

local M = {}

M.ALLOW_PATH = "/etc/tsr/rsh.allow"
M.MAX_OUTPUT = 60000
M.DEFAULT_TIMEOUT = 30

---------------------------------------------------------------------------------------------------------------------
-- Server
---------------------------------------------------------------------------------------------------------------------

local sessions = {}      -- peer id -> tsh Shell

--- Forget every remote session (tests; also useful after the shell package is upgraded).
function M.reset() sessions = {} end

function M.allowed()
  return vfs.readTable(M.ALLOW_PATH) or {}
end

local function isAllowed(peer)
  for _, name in ipairs(M.allowed()) do
    if name == peer.name then return true end
  end
  return false
end

local function sessionFor(id)
  if not sessions[id] then
    local exec = require("tsr.shell.exec")
    sessions[id] = exec.new({ home = "/" })
  end
  return sessions[id]
end

--- Run `line` in `sh` capturing everything it prints. Returns status, output, timedOut.
function M.execute(sh, line, timeout)
  local capture = require("tsr.shell.capture")
  local okK, kernel = pcall(require, "tsr.kernel")
  if okK and kernel.isRunning and kernel.isRunning() then
    local cap = capture.new()
    local status = 1
    local pid = kernel.spawn({
      name = "rsh-cmd", term = cap.term, daemon = true,
      fn = function() status = sh:runLine(line) end,
    })
    local timedOut = false
    if pid then
      local timer = os.startTimer(timeout)
      while kernel.get(pid) do
        local ev, id = os.pullEvent()
        if ev == "timer" and id == timer then
          kernel.kill(pid)
          timedOut = true
        end
      end
      os.cancelTimer(timer)
    end
    return status, cap.text(), timedOut
  end
  -- no kernel (tests, plain CraftOS): run inline
  local status, out = sh:withIO("", true, function() return sh:runLine(line) end)
  return status, out or "", false
end

--- Register the "shell" service on `node`.
function M.serve(node)
  node:serve("shell", function(from, method, a)
    local sh = sessionFor(from)
    if method == "hello" then
      return { host = node.hostname, cwd = "/" .. sh.dir }
    elseif method == "run" then
      if type(a) ~= "table" or type(a.line) ~= "string" then error("need a command line", 0) end
      local timeout = math.min(tonumber(a.timeout) or M.DEFAULT_TIMEOUT, 300)
      local status, out, timedOut = M.execute(sh, a.line, timeout)
      local truncated = false
      if #out > M.MAX_OUTPUT then out = out:sub(1, M.MAX_OUTPUT) truncated = true end
      return { status = status, output = out, cwd = "/" .. sh.dir, truncated = truncated, timedOut = timedOut }
    elseif method == "reset" then
      sessions[from] = nil
      return true
    end
    error("unknown method " .. tostring(method), 0)
  end, { allow = isAllowed, async = true })
end

---------------------------------------------------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------------------------------------------------

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.write(t) write(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  function io.readLine() return read() end
  return io
end

--- Run a command on a peer. Returns the reply table ({status, output, cwd,...}) or nil + error.
function M.exec(node, peer, line, opts)
  opts = opts or {}
  local timeout = opts.timeout or M.DEFAULT_TIMEOUT
  return node:call(peer, "shell", "run", { line = line, timeout = timeout }, { timeout = timeout + 5, encrypt = opts.encrypt })
end

local function needAdmin(io)
  local okAuth, auth = pcall(require, "tsr.auth")
  if not okAuth or not auth.hasUsers() then return true end
  local me = auth.current()
  if me == nil or auth.can(me, "auth.manage") then return true end
  io.err("only administrators can change who may run commands here")
  return false
end

function M.run(args, io, node)
  io = io or defaultIO()
  node = node or require("tsr.net").default()
  local first = args[1]

  if first == "allow" or first == "deny" then
    if not args[2] then io.err("usage: rsh " .. first .. " <peer name>") return false end
    if not needAdmin(io) then return false end
    local list, kept = M.allowed(), {}
    for _, n in ipairs(list) do if n ~= args[2] then kept[#kept + 1] = n end end
    if first == "allow" then
      if not node:peer(args[2]) then io.err("warning: " .. args[2] .. " is not paired (yet); `net pair` first") end
      kept[#kept + 1] = args[2]
    end
    vfs.writeTable(M.ALLOW_PATH, kept)
    io.say(first == "allow" and (args[2] .. " may now run commands on this computer.") or (args[2] .. " may no longer run commands here."))
    return true
  elseif first == "allowed" then
    local list = M.allowed()
    if #list == 0 then io.say("Nobody may run commands here.") end
    for _, n in ipairs(list) do io.say(n) end
    return true
  end

  local peer = first
  if not peer then io.err("usage: rsh <peer> [command...]   |   rsh allow|deny <peer>   |   rsh allowed") return false end
  if #args > 1 then
    local line = table.concat(args, " ", 2)
    local res, err = M.exec(node, tonumber(peer) or peer, line)
    if not res then io.err(tostring(err)) return false end
    if res.output ~= "" then io.write(res.output) if res.output:sub(-1) ~= "\n" then io.say("") end end
    if res.truncated then io.err("[output truncated]") end
    if res.timedOut then io.err("[stopped: the command took too long]") end
    return res.status == 0
  end

  -- interactive
  local hello, err = node:call(tonumber(peer) or peer, "shell", "hello", nil, { timeout = 5 })
  if not hello then io.err(tostring(err)) return false end
  io.say("Connected to " .. tostring(hello.host) .. ". Type exit to leave.")
  local cwd = hello.cwd
  while true do
    io.write(tostring(hello.host) .. ":" .. cwd .. "> ")
    local line = io.readLine()
    if line == nil or line == "exit" then break end
    if line:match("%S") then
      local res, e2 = M.exec(node, tonumber(peer) or peer, line)
      if not res then io.err(tostring(e2))
      else
        cwd = res.cwd or cwd
        if res.output ~= "" then io.write(res.output) if res.output:sub(-1) ~= "\n" then io.say("") end end
        if res.timedOut then io.err("[stopped: the command took too long]") end
      end
    end
  end
  node:call(tonumber(peer) or peer, "shell", "reset", nil, { timeout = 3 })
  return true
end

function M.main(args) return M.run(args) end

--- The rshd service: register the shell service and idle.
function M.daemon()
  M.serve(require("tsr.net").default())
  while true do os.pullEvent("rsh_never") end
end

return M
