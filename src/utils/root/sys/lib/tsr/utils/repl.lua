-- SPDX-License-Identifier: AGPL-3.0-or-later
-- repl: a Lua prompt with history, tab completion, multi-line input and readable output.
--   > 1 + 2            prints 3        (an expression is evaluated and shown)
--   > x = 5            statements work too; variables persist
--   > for i = 1, 3 do  continues on the next line until the block is complete
--   > _                the last result
--   :help  :load <file>  :clear  :quit
-- The environment has everything from the CraftOS global table, plus `tsr` and `require` (Tessera's shared loader).
local M = {}


local function isIncomplete(msg)
  msg = tostring(msg)
  return msg:find("<eof>", 1, true) ~= nil or msg:find("unexpected eof", 1, true) ~= nil
end
M.isIncomplete = isIncomplete

--- Readable text for a value.
function M.show(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == "string" then return depth == 0 and v or string.format("%q", v) end
  if t == "table" then
    if depth >= 3 then return "{...}" end
    local parts, n = {}, 0
    local keys_ = {}
    for k in pairs(v) do keys_[#keys_ + 1] = k end
    table.sort(keys_, function(a, b)
      if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
      return tostring(a) < tostring(b)
    end)
    local arrayLen = #v
    for _, k in ipairs(keys_) do
      n = n + 1
      if n > 30 then parts[#parts + 1] = "..." break end
      local val = M.show(v[k], depth + 1)
      if type(k) == "number" and k >= 1 and k <= arrayLen then parts[#parts + 1] = val
      elseif type(k) == "string" and k:match("^[%a_][%w_]*$") then parts[#parts + 1] = k .. " = " .. val
      else parts[#parts + 1] = "[" .. M.show(k, depth + 1) .. "] = " .. val end
    end
    if #parts == 0 then return "{}" end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  return tostring(v)
end

--- A REPL session. opts: read(history, completer) -> line | nil, write(text), env (extra globals), maxLines (tests)
function M.new(opts)
  opts = opts or {}
  local env = setmetatable({}, { __index = _G })
  env._ENV = env
  env._G = env
  local okTsr = rawget(_G, "tsr")
  if okTsr then env.tsr = okTsr; env.require = okTsr.require end
  for k, v in pairs(opts.env or {}) do env[k] = v end
  local self = { env = env, history = {}, out = opts.write or function(t) print(t) end, quit = false }

  local function runChunk(code)
    -- an expression first, so "1 + 2" prints 3; fall back to a statement
    local fn, exprErr = load("return " .. code, "=repl", "t", env)
    if fn then return fn end
    local err
    fn, err = load(code, "=repl", "t", env)
    -- unfinished as an expression OR as a statement means: keep reading
    if not fn and isIncomplete(exprErr) then return nil, exprErr end
    return fn, err
  end

  --- Evaluate source text. Returns "ok" | "incomplete" | "error".
  function self.eval(code)
    local fn, err = runChunk(code)
    if not fn then
      if isIncomplete(err) then return "incomplete" end
      self.out(tostring(err))
      return "error"
    end
    local res = table.pack(pcall(fn))
    if not res[1] then
      self.out(tostring(res[2]))
      return "error"
    end
    if res.n > 1 then
      env._ = res[2]
      local parts = {}
      for i = 2, res.n do parts[#parts + 1] = M.show(res[i]) end
      self.out(table.concat(parts, "  "))
    end
    return "ok"
  end

  --- Names to complete after `line` (globals and table fields), as suffixes.
  function self.complete(line)
    local partial = line:match("([%w_]*)$")
    local base = line:match("([%w_%.]+)%.[%w_]*$")
    local container = env
    if base then
      container = env
      for part in base:gmatch("[^%.]+") do
        if type(container) ~= "table" then container = nil break end
        container = container[part]
      end
    end
    local out = {}
    if type(container) == "table" then
      local seen = {}
      local function collect(t)
        for k in pairs(t) do
          if type(k) == "string" and k:sub(1, #partial) == partial and #k > #partial and not seen[k] then
            seen[k] = true
            out[#out + 1] = k:sub(#partial + 1)
          end
        end
      end
      collect(container)
      local mt = getmetatable(container)
      if mt and type(mt.__index) == "table" then collect(mt.__index) end
    end
    table.sort(out)
    return out
  end

  local commands = {}
  commands.help = function() self.out("Type Lua. :load <file>, :clear, :quit. `_` is the last result.") end
  commands.quit = function() self.quit = true end
  commands.exit = commands.quit
  commands.clear = function() term.clear() term.setCursorPos(1, 1) end
  commands.load = function(arg)
    local path = arg ~= "" and ((rawget(_G, "shell") and shell.resolve(arg)) or arg)
    if not path or not fs.exists(path) then self.out("no such file: " .. tostring(arg)) return end
    local h = fs.open(path, "r")
    local code = h.readAll()
    h.close()
    local fn, err = load(code, "@" .. path, "t", env)
    if not fn then self.out(tostring(err)) return end
    local ok, e = pcall(fn)
    self.out(ok and ("loaded " .. path) or tostring(e))
  end

  --- Handle one entered line (possibly continuing an earlier unfinished one). Returns "ok" | "incomplete" | "error" | "command".
  function self.line(text, pending)
    if not pending and text:sub(1, 1) == ":" then
      local name, arg = text:match("^:(%w+)%s*(.*)$")
      local cmd = name and commands[name]
      if cmd then cmd(arg) else self.out("unknown command; try :help") end
      return "command"
    end
    local code = pending and (pending .. "\n" .. text) or text
    local state = self.eval(code)
    return state, code
  end

  function self.run(readFn)
    readFn = readFn or function(history, completer)
      return read(nil, history, completer)
    end
    local pending
    while not self.quit do
      write(pending and ">> " or "> ")
      local text = readFn(self.history, self.complete)
      if text == nil then break end
      if text:match("%S") or pending then
        if not pending then self.history[#self.history + 1] = text end
        local state, code = self.line(text, pending)
        pending = (state == "incomplete") and code or nil
      end
    end
  end

  return self
end

function M.main(args)
  local session = M.new({})
  print("Tessera Lua prompt. :help for help, :quit to leave.")
  session.run()
  return true
end

return M
