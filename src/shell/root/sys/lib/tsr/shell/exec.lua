-- SPDX-License-Identifier: AGPL-3.0-or-later
-- tsh interpreter: runs parsed command lines. One Shell object holds the session state (variables, aliases, working
-- directory, history, positional parameters). Pipelines run their stages one after another and hand the captured output of
-- a stage to the next as its standard input; programs written for the stock CraftOS shell run unchanged.
local parse = require("tsr.shell.parse")
local capture = require("tsr.shell.capture")

local unpack = table.unpack or unpack

local M = {}
local Sh = {}
Sh.__index = Sh
M.Shell = Sh

local DEFAULT_PATH = ".:/rom/programs:/rom/programs/http:/rom/programs/rednet:/rom/programs/fun:/usr/bin:/sys/bin"
local EXTENSIONS = { "", ".lua", ".tsh" }
local MAX_SCRIPT_DEPTH = 32

local function isFile(p) return fs.exists(p) and not fs.isDir(p) end

--- Create a shell. opts: parentShell (a CraftOS shell API to inherit path, aliases and completions from), dir, home, user.
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    vars = {}, aliases = {}, completions = {}, history = {},
    status = 0, dir = opts.dir or "", frames = { { name = "tsh", args = {} } },
    running = {}, signal = nil, exiting = false, exitCode = 0, stdin = nil, errTerm = nil,
    scriptDepth = 0, pathString = DEFAULT_PATH, opts = opts,
  }, Sh)
  local parent = opts.parentShell
  if parent then
    pcall(function()
      self.pathString = parent.path()
      for k, v in pairs(parent.aliases()) do self.aliases[k] = v end
      if parent.getCompletionInfo then
        for k, v in pairs(parent.getCompletionInfo()) do self.completions[k] = v end
      end
      if not opts.dir then self.dir = parent.dir() end
    end)
  end
  self.vars.HOME = opts.home or "/"
  self.vars.USER = opts.user or "user"
  self.vars.PS1 = opts.ps1 or "\\w> "
  local host = rawget(_G, "tsr") and tsr.hostname and tsr.hostname() or os.getComputerLabel() or ("cc-" .. os.getComputerID())
  self.vars.HOSTNAME = host
  self.api = require("tsr.shell.api").build(self)
  return self
end

---------------------------------------------------------------------------------------------------------------------
-- State helpers
---------------------------------------------------------------------------------------------------------------------

function Sh:frame() return self.frames[#self.frames] end

function Sh:getVar(name)
  if name == "?" then return tostring(self.status)
  elseif name == "#" then return tostring(#self:frame().args)
  elseif name == "@" or name == "*" then return table.concat(self:frame().args, " ")
  elseif name:match("^%d$") then
    local n = tonumber(name)
    if n == 0 then return self:frame().name end
    return self:frame().args[n]
  elseif name == "PWD" then return "/" .. self.dir
  elseif name == "PATH" then return self.pathString
  end
  return self.vars[name]
end

function Sh:setVar(name, value)
  if name == "PATH" then self.pathString = tostring(value) return end
  if name == "PWD" then return end
  self.vars[name] = value ~= nil and tostring(value) or nil
end

--- Absolute-or-relative path as the stock shell resolves it (no leading slash).
function Sh:resolve(p)
  if p:sub(1, 1) == "/" or p:sub(1, 1) == "\\" then return fs.combine(p, "") end
  return fs.combine(self.dir, p)
end

--- Print an error message on the real terminal even while output is being captured.
function Sh:err(msg)
  local target = self.errTerm
  local prev
  if target then prev = term.redirect(target) end
  pcall(printError, msg)
  if target then term.redirect(prev) end
end

function Sh:addHistory(line)
  if line == "" then return end
  local h = self.history
  if h[#h] == line then return end
  h[#h + 1] = line
  while #h > (self.opts.historyLimit or 200) do table.remove(h, 1) end
end

---------------------------------------------------------------------------------------------------------------------
-- Programs
---------------------------------------------------------------------------------------------------------------------

--- Resolve a command name to a program file (no leading slash), or nil.
function Sh:findProgram(name)
  if name == "" then return nil end
  if name:find("/", 1, true) then
    local base = self:resolve(name)
    for _, ext in ipairs(EXTENSIONS) do
      if isFile(base .. ext) then return base .. ext end
    end
    return nil
  end
  for dir in self.pathString:gmatch("[^:]+") do
    local d = self:resolve(dir)
    for _, ext in ipairs(EXTENSIONS) do
      local p = fs.combine(d, name .. ext)
      if isFile(p) then return p end
    end
  end
  return nil
end

--- Names of the programs on the path (without .lua/.tsh), sorted. Hidden entries start with a dot.
function Sh:programList(includeHidden)
  local seen, out = {}, {}
  for dir in self.pathString:gmatch("[^:]+") do
    local d = self:resolve(dir)
    if fs.isDir(d) then
      for _, f in ipairs(fs.list(d)) do
        local full = fs.combine(d, f)
        if not fs.isDir(full) then
          local name = f:gsub("%.lua$", ""):gsub("%.tsh$", "")
          if not seen[name] and (includeHidden or name:sub(1, 1) ~= ".") then
            seen[name] = true
            out[#out + 1] = name
          end
        end
      end
    end
  end
  table.sort(out)
  return out
end

function Sh:programEnv(dir)
  local env = { shell = self.api, multishell = rawget(_G, "multishell") }
  local ok, req = pcall(require, "cc.require")
  if ok and type(req) == "table" and req.make then env.require, env.package = req.make(env, "/" .. dir) end
  if self.opts.programOs then env.os = self.opts.programOs end       -- e.g. kiosk mode swallows terminate events
  local reader = self.stdin
  if reader then
    env.io = capture.ioFor(reader, io)
    env.read = function() return reader.readLine(false) end
  end
  return env
end

local function statusOf(ok, ...)
  if not ok then return 1 end
  local r = ...
  if r == false then return 1 end
  if type(r) == "number" then return r end
  return 0
end

function Sh:runProgram(path, args)
  if path:match("%.tsh$") then return self:runScriptFile("/" .. path, args) end
  local env = self:programEnv(fs.getDir(path))
  local fn, err = loadfile("/" .. path, "t", env)
  if not fn then self:err(tostring(err)) return 1 end
  setmetatable(env, { __index = _G })
  self.running[#self.running + 1] = path
  local res = table.pack(pcall(fn, unpack(args)))
  self.running[#self.running] = nil
  if not res[1] then
    self:err(tostring(res[2]))
    return 1
  end
  return statusOf(true, res[2])
end

---------------------------------------------------------------------------------------------------------------------
-- Input / output plumbing
---------------------------------------------------------------------------------------------------------------------

--- Run fn with standard input fed from `stdin` (a string; nil keeps the current input) and, when `capture` is set, with
--- output recorded instead of shown. Returns fn's status and the captured text.
function Sh:withIO(stdin, wantCapture, fn)
  local saveIn, saveErr = self.stdin, self.errTerm
  if stdin ~= nil then self.stdin = capture.stdin(stdin) end
  local cap, prevTerm
  if wantCapture then
    cap = capture.new()
    prevTerm = term.redirect(cap.term)
    if not self.errTerm then self.errTerm = prevTerm end
  end
  local ok, status = pcall(fn)
  if wantCapture then term.redirect(prevTerm) end
  self.stdin, self.errTerm = saveIn, saveErr
  if not ok then error(status, 0) end
  return status, cap and cap.text()
end

---------------------------------------------------------------------------------------------------------------------
-- Expansion
---------------------------------------------------------------------------------------------------------------------

function Sh:glob(pat)
  local ok, found = pcall(fs.find, self:resolve(pat))
  if not ok or type(found) ~= "table" then return {} end
  local abs = pat:sub(1, 1) == "/"
  local lastPat = pat:match("([^/]*)$")
  local out = {}
  for _, p in ipairs(found) do
    if not (fs.getName(p):sub(1, 1) == "." and lastPat:sub(1, 1) ~= ".") then
      if abs then
        out[#out + 1] = "/" .. p
      elseif self.dir ~= "" and p:sub(1, #self.dir + 1) == self.dir .. "/" then
        out[#out + 1] = p:sub(#self.dir + 2)
      elseif self.dir == "" then
        out[#out + 1] = p
      else
        out[#out + 1] = "/" .. p
      end
    end
  end
  return out
end

function Sh:ctx(noGlob)
  return {
    getVar = function(n) return self:getVar(n) end,
    subst = function(src) return self:substitute(src) end,
    home = self.vars.HOME,
    find = (not noGlob) and function(pat) return self:glob(pat) end or nil,
  }
end

--- Run `src` and return what it printed.
function Sh:substitute(src)
  local ast, err = parse.parse(src)
  if not ast then self:err("tsh: " .. tostring(err)) return "" end
  local _, out = self:withIO(nil, true, function() return self:execNode(ast) end)
  return out or ""
end

---------------------------------------------------------------------------------------------------------------------
-- Execution
---------------------------------------------------------------------------------------------------------------------

local builtins

local function yieldSometimes(self)
  self.ticks = (self.ticks or 0) + 1
  if self.ticks % 40 == 0 and rawget(_G, "sleep") then sleep(0) end
end

--- Resolve a command's words, apply redirects and run it. stdinText: piped input; capture: caller wants the output as text.
function Sh:execSimple(node, stdinText, wantCapture)
  local ctx, ctxPlain = self:ctx(), self:ctx(true)
  local idx, assigns = 1, {}
  while idx <= #node.words do
    local first = node.words[idx][1]
    if first and first.lit and first.q == "bare" and first.lit:match("^[%a_][%w_]*=") then
      local name, rest = first.lit:match("^([%a_][%w_]*)=(.*)$")
      local vsegs = {}
      if rest ~= "" then vsegs[1] = { lit = rest, q = "bare" } end
      for k = 2, #node.words[idx] do vsegs[#vsegs + 1] = node.words[idx][k] end
      assigns[#assigns + 1] = { name, parse.expandOne(vsegs, ctxPlain) }
      idx = idx + 1
    else
      break
    end
  end
  local words = {}
  for k = idx, #node.words do
    for _, w in ipairs(parse.expand(node.words[k], ctx)) do words[#words + 1] = w end
  end

  -- redirects
  local stdin, outFile, append = stdinText, nil, false
  for _, r in ipairs(node.redirs) do
    local target = parse.expandOne(r.target, ctxPlain)
    if target == "" then self:err("tsh: ambiguous redirect") return 1, wantCapture and "" or nil end
    local path = self:resolve(target)
    if r.op == "<" then
      if not isFile(path) then self:err("tsh: " .. target .. ": No such file") return 1, wantCapture and "" or nil end
      local h = fs.open(path, "r")
      stdin = h.readAll() or ""
      h.close()
    else
      if fs.isDir(path) then self:err("tsh: " .. target .. ": Is a directory") return 1, wantCapture and "" or nil end
      outFile, append = path, r.op == ">>"
    end
  end

  if #words == 0 then
    for _, a in ipairs(assigns) do self:setVar(a[1], a[2]) end
    if outFile then
      local h = fs.open(outFile, append and "a" or "w")
      if h then h.close() end
    end
    return 0, wantCapture and "" or nil
  end

  -- temporary assignments last for this command only
  local saved = {}
  for _, a in ipairs(assigns) do
    saved[#saved + 1] = { a[1], self.vars[a[1]] }
    self:setVar(a[1], a[2])
  end
  local status, text = self:withIO(stdin, wantCapture or outFile ~= nil, function() return self:dispatch(words) end)
  for i = #saved, 1, -1 do self.vars[saved[i][1]] = saved[i][2] end

  if outFile then
    local h = fs.open(outFile, append and "a" or "w")
    if not h then
      self:err("tsh: cannot write " .. outFile)
      return 1, wantCapture and "" or nil
    end
    h.write(text or "")
    h.close()
    text = wantCapture and "" or nil
  end
  return status, text
end

--- Run a command given as already-expanded words: alias, builtin, then program.
function Sh:dispatch(words)
  local name = words[1]
  local args = { unpack(words, 2) }
  local alias = self.aliases[name]
  if alias and alias ~= name then
    local parts = {}
    for w in alias:gmatch("%S+") do parts[#parts + 1] = w end
    if #parts > 0 then
      name = parts[1]
      local merged = {}
      for i = 2, #parts do merged[#merged + 1] = parts[i] end
      for _, a in ipairs(args) do merged[#merged + 1] = a end
      args = merged
    end
  end
  local b = rawget(builtins, name)
  if b then
    local st = b(self, args)
    return type(st) == "number" and st or 0
  end
  local path = self:findProgram(name)
  if not path then
    self:err("tsh: " .. name .. ": command not found")
    return 127
  end
  return self:runProgram(path, args)
end

function Sh:execStage(cmd, input, wantCapture)
  if cmd.type == "simple" then return self:execSimple(cmd, input, wantCapture) end
  return self:withIO(input, wantCapture, function() return self:execNode(cmd) end)
end

function Sh:execPipeline(node)
  local input, st = nil, 0
  for i, cmd in ipairs(node.cmds) do
    if i == #node.cmds then
      st = self:execStage(cmd, input, false)
    else
      local out
      st, out = self:execStage(cmd, input, true)
      input = out or ""
    end
    if self.signal then break end
  end
  return st
end

--- `cmd &`: run in a separate kernel process when Tessera's kernel is up, otherwise just run it.
function Sh:background(node)
  local okK, kernel = pcall(require, "tsr.kernel")
  if okK and kernel.isRunning and kernel.isRunning() then
    local pid = kernel.spawn({
      name = "tsh-bg", session = true, window = true,
      fn = function()
        local sub = M.new({ parentShell = nil, dir = self.dir, home = self.vars.HOME, user = self.vars.USER })
        sub.pathString, sub.aliases = self.pathString, self.aliases
        for k, v in pairs(self.vars) do sub.vars[k] = v end
        sub:execNode(node)
      end,
    })
    if pid then
      print("[" .. pid .. "] started")
      return 0
    end
  end
  return self:execNode(node)
end

local function loopSignal(self)
  -- returns "stop" to leave the loop, "next" to skip to the next round, nil to carry on
  local sig = self.signal
  if not sig then return nil end
  if sig.kind == "break" or sig.kind == "continue" then
    sig.n = (sig.n or 1) - 1
    if sig.n > 0 then return "stop" end   -- an outer loop must handle the rest
    self.signal = nil
    return sig.kind == "break" and "stop" or "next"
  end
  return "stop"   -- exit / return
end

function Sh:execNode(node)
  local t = node.type
  if t == "list" then
    local st = 0
    for _, item in ipairs(node.items) do
      if item.bg then st = self:background(item.node) else st = self:execNode(item.node) end
      self.status = st
      if self.signal then break end
    end
    return st
  elseif t == "simple" then
    local st = self:execSimple(node, nil, false)
    self.status = st
    return st
  elseif t == "pipeline" then
    local st = self:execPipeline(node)
    self.status = st
    return st
  elseif t == "and" then
    local st = self:execNode(node.left)
    if st == 0 and not self.signal then st = self:execNode(node.right) end
    return st
  elseif t == "or" then
    local st = self:execNode(node.left)
    if st ~= 0 and not self.signal then st = self:execNode(node.right) end
    return st
  elseif t == "if" then
    for _, br in ipairs(node.branches) do
      local c = self:execNode(br.cond)
      if self.signal then return c end
      if c == 0 then return self:execNode(br.body) end
    end
    if node.elseBody then return self:execNode(node.elseBody) end
    return 0
  elseif t == "for" then
    local values, ctx = {}, self:ctx()
    for _, segs in ipairs(node.words) do
      for _, w in ipairs(parse.expand(segs, ctx)) do values[#values + 1] = w end
    end
    if #node.words == 0 then values = { unpack(self:frame().args) } end
    local st = 0
    for _, v in ipairs(values) do
      self.vars[node.var] = v
      st = self:execNode(node.body)
      local action = loopSignal(self)
      if action == "stop" then break end
      yieldSometimes(self)
    end
    return st
  elseif t == "while" then
    local st = 0
    while true do
      local c = self:execNode(node.cond)
      if self.signal then return c end
      if (c == 0) == node.negate then break end
      st = self:execNode(node.body)
      local action = loopSignal(self)
      if action == "stop" then break end
      yieldSometimes(self)
    end
    return st
  end
  error("tsh: unknown node " .. tostring(t))
end

---------------------------------------------------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------------------------------------------------

--- Parse and run source text. Returns the exit status.
function Sh:runString(src, name)
  local ast, err = parse.parse(src)
  if not ast then
    self:err((name and (name .. ": ") or "tsh: ") .. "syntax error: " .. tostring(err))
    self.status = 2
    return 2
  end
  local st = self:execNode(ast)
  self.status = st
  return st
end

--- Run a command line the way the prompt would. Returns the status.
function Sh:runLine(line)
  local st = self:runString(line)
  local sig = self.signal
  if sig and (sig.kind == "exit" or sig.kind == "return") and self.scriptDepth == 0 then
    self.signal = nil
    if sig.kind == "exit" then self.exiting, self.exitCode = true, sig.code or st end
  end
  return st
end

--- Run script text with positional parameters. `exit`/`return` end only the script.
function Sh:runScript(src, name, args)
  if self.scriptDepth >= MAX_SCRIPT_DEPTH then
    self:err("tsh: scripts nested too deeply")
    return 1
  end
  self.frames[#self.frames + 1] = { name = name, args = args or {} }
  self.scriptDepth = self.scriptDepth + 1
  local ok, st = pcall(self.runString, self, src, name)
  self.scriptDepth = self.scriptDepth - 1
  self.frames[#self.frames] = nil
  if not ok then error(st, 0) end
  local sig = self.signal
  if sig and (sig.kind == "exit" or sig.kind == "return") then
    st = sig.code or self.status
    self.signal = nil
    if sig.kind == "exit" and self.scriptDepth == 0 and self.interactive then self.status = st end
  end
  return st
end

function Sh:runScriptFile(path, args)
  local p = self:resolve(path)
  if not isFile(p) then self:err("tsh: " .. path .. ": No such file") return 127 end
  local h = fs.open(p, "r")
  local src = h.readAll() or ""
  h.close()
  self.running[#self.running + 1] = p
  local ok, st = pcall(self.runScript, self, src, p, args)
  self.running[#self.running] = nil
  if not ok then error(st, 0) end
  return st
end

builtins = require("tsr.shell.builtins")
M.builtins = builtins

return M
