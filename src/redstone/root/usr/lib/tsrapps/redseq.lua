-- SPDX-License-Identifier: AGPL-3.0-or-later
-- redseq: timed redstone sequences — piston doors, dispenser clocks, lighting shows, cannon volleys.
--   redseq run <name|file> [--times N]     run a sequence (name = /etc/tsr/redseq/<name>.seq)
--   redseq check <name|file>               parse only; prints the steps and the total time
--   redseq list                            sequences in /etc/tsr/redseq
-- A sequence file has one command per line ("#" starts a comment):
--   on <port>            off <port>         set <port> <0-15>
--   pulse <port> <sec>   toggle <port>      wait <sec>
--   repeat <n>  ...  end                    repeat the enclosed lines (may be nested)
-- Ports are as in `rs` (top, back:red, relay_0/left ...).
local rsio = require("tsrapps.rsio")
local cli = require("tsrapps.cli")

local M = {}

M.DIR = "/etc/tsr/redseq"
M.SPEC = { times = "number" }

--- Parse sequence text into a step list. Returns steps, or nil + "line N: reason".
function M.parse(text, env)
  local root = { steps = {} }
  local stack = { root }
  local n = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    line = line:gsub("\r", ""):gsub("#.*$", "")
    local words = {}
    for w in line:gmatch("%S+") do words[#words + 1] = w end
    local op = words[1] and words[1]:lower()
    local cur = stack[#stack]
    local function bad(msg) return nil, ("line %d: %s"):format(n, msg) end
    local function port(i)
      if not words[i] then return nil, "missing port" end
      local p, err = rsio.parse(words[i], env)
      if not p then return nil, err end
      return words[i]
    end
    if op == nil then
      -- blank
    elseif op == "on" or op == "off" or op == "toggle" then
      local p, err = port(2)
      if not p then return bad(err) end
      cur.steps[#cur.steps + 1] = { op = op, port = p, line = n }
    elseif op == "set" then
      local p, err = port(2)
      if not p then return bad(err) end
      local level = rsio.level(words[3] or "")
      if level == nil then return bad("set needs on, off or 0-15") end
      cur.steps[#cur.steps + 1] = { op = "set", port = p, level = level, line = n }
    elseif op == "pulse" then
      local p, err = port(2)
      if not p then return bad(err) end
      local secs = tonumber(words[3] or "0.5")
      if not secs or secs <= 0 then return bad("pulse needs a positive number of seconds") end
      cur.steps[#cur.steps + 1] = { op = "pulse", port = p, secs = secs, line = n }
    elseif op == "wait" then
      local secs = tonumber(words[2] or "")
      if not secs or secs < 0 then return bad("wait needs a number of seconds") end
      cur.steps[#cur.steps + 1] = { op = "wait", secs = secs, line = n }
    elseif op == "repeat" then
      local times = tonumber(words[2] or "")
      if not times or times < 1 or times ~= math.floor(times) then return bad("repeat needs a whole number") end
      local block = { op = "repeat", times = times, steps = {}, line = n }
      cur.steps[#cur.steps + 1] = block
      stack[#stack + 1] = block
    elseif op == "end" then
      if #stack == 1 then return bad("'end' without 'repeat'") end
      stack[#stack] = nil
    else
      return bad("unknown command '" .. words[1] .. "'")
    end
  end
  if #stack > 1 then return nil, ("line %d: 'repeat' is never closed with 'end'"):format(stack[#stack].line) end
  return root.steps
end

--- Total running time of a step list in seconds.
function M.duration(steps)
  local total = 0
  for _, s in ipairs(steps) do
    if s.op == "wait" or s.op == "pulse" then total = total + s.secs
    elseif s.op == "repeat" then total = total + s.times * M.duration(s.steps) end
  end
  return total
end

--- Number of primitive steps (repeats expanded).
function M.count(steps)
  local n = 0
  for _, s in ipairs(steps) do
    if s.op == "repeat" then n = n + s.times * M.count(s.steps) else n = n + 1 end
  end
  return n
end

--- Execute steps. env: redstone, peripheral, sleep (see tsrapps.rsio). opts.onStep(step) is called before each step.
--- Outputs that were switched on by the sequence are switched off again if it stops with an error.
function M.run(steps, env, opts)
  env = env or {}
  opts = opts or {}
  local sleepFn = env.sleep or sleep
  local ports = {}
  local touched = {}
  local function get(spec)
    if not ports[spec] then
      local p, err = rsio.open(spec, env)
      if not p then error(err, 0) end
      ports[spec] = p
    end
    return ports[spec]
  end
  local function exec(list)
    for _, s in ipairs(list) do
      if opts.onStep then opts.onStep(s) end
      if s.op == "on" then get(s.port).set(true) touched[s.port] = true
      elseif s.op == "off" then get(s.port).set(false)
      elseif s.op == "set" then get(s.port).set(s.level) touched[s.port] = true
      elseif s.op == "toggle" then get(s.port).toggle() touched[s.port] = true
      elseif s.op == "pulse" then touched[s.port] = true get(s.port).pulse(s.secs)
      elseif s.op == "wait" then sleepFn(s.secs)
      elseif s.op == "repeat" then for _ = 1, s.times do exec(s.steps) end end
    end
  end
  local ok, err = pcall(exec, steps)
  if not ok then
    for spec in pairs(touched) do pcall(function() get(spec).set(false) end) end -- fail safe
    return false, tostring(err)
  end
  return true
end

local function resolve(nameOrFile)
  if fs.exists(nameOrFile) and not fs.isDir(nameOrFile) then return nameOrFile end
  local p = M.DIR .. "/" .. nameOrFile .. ".seq"
  if fs.exists(p) then return p end
  return nil
end

local function load(nameOrFile, env)
  local path = resolve(nameOrFile)
  if not path then return nil, "no such sequence: " .. nameOrFile end
  local h = fs.open(path, "r")
  local text = h.readAll()
  h.close()
  return M.parse(text, env)
end

function M.main(args, io, env)
  io = io or cli.io()
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  local cmd, target = pos[1], pos[2]
  if cmd == "list" then
    if not fs.isDir(M.DIR) then io.say("No sequences yet. Put *.seq files in " .. M.DIR) return true end
    for _, f in ipairs(fs.list(M.DIR)) do
      if f:match("%.seq$") then io.say((f:gsub("%.seq$", ""))) end
    end
    return true
  end
  if not (cmd and target) or (cmd ~= "run" and cmd ~= "check") then
    io.say("usage: redseq run <name|file> [--times N] | check <name|file> | list")
    return false
  end
  local steps, err = load(target, env)
  if not steps then io.err(err) return false end
  local times = opts.times or 1
  if cmd == "check" then
    io.say(("%d steps, %.1f seconds per run"):format(M.count(steps), M.duration(steps)))
    return true
  end
  for i = 1, times do
    local ok, why = M.run(steps, env)
    if not ok then io.err("Sequence stopped: " .. why) return false end
  end
  io.say(("Ran %s%s."):format(target, times > 1 and (" " .. times .. " times") or ""))
  return true
end

return M
