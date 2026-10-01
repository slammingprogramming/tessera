-- SPDX-License-Identifier: AGPL-3.0-or-later
-- tsh builtin commands. Each is function(shell, args) -> status (0 = success).
local B = {}

local unpack = table.unpack or unpack

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function fileText(path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll() or ""
  h.close()
  return s
end

function B.cd(sh, args)
  local target = args[1] or sh.vars.HOME or "/"
  if target == "-" then target = sh.vars.OLDPWD or "/" .. sh.dir end
  local p = sh:resolve(target)
  if not fs.isDir(p) then
    sh:err("cd: " .. target .. ": No such directory")
    return 1
  end
  sh.vars.OLDPWD = "/" .. sh.dir
  sh.dir = p
  return 0
end

function B.pwd(sh) print("/" .. sh.dir) return 0 end

function B.exit(sh, args)
  sh.signal = { kind = "exit", code = tonumber(args[1]) or sh.status }
  return sh.signal.code
end

B["return"] = function(sh, args)
  sh.signal = { kind = "return", code = tonumber(args[1]) or sh.status }
  return sh.signal.code
end

B["break"] = function(sh, args)
  sh.signal = { kind = "break", n = math.max(1, tonumber(args[1]) or 1) }
  return 0
end

B["continue"] = function(sh, args)
  sh.signal = { kind = "continue", n = math.max(1, tonumber(args[1]) or 1) }
  return 0
end

B["true"] = function() return 0 end
B[":"] = B["true"]
B["false"] = function() return 1 end

function B.alias(sh, args)
  if #args == 0 then
    for _, k in ipairs(sortedKeys(sh.aliases)) do print("alias " .. k .. "=" .. sh.aliases[k]) end
    return 0
  end
  local status = 0
  local i = 1
  while i <= #args do
    local a = args[i]
    local name, value = a:match("^([^=]+)=(.*)$")
    if name then
      sh.aliases[name] = value
    elseif args[i + 1] and #args == 2 then
      sh.aliases[a] = args[i + 1]   -- CraftOS style: alias <name> <program>
      i = i + 1
    elseif sh.aliases[a] then
      print("alias " .. a .. "=" .. sh.aliases[a])
    else
      sh:err("alias: " .. a .. ": not found")
      status = 1
    end
    i = i + 1
  end
  return status
end

function B.unalias(sh, args)
  for _, a in ipairs(args) do sh.aliases[a] = nil end
  return 0
end

function B.export(sh, args)
  for _, a in ipairs(args) do
    local name, value = a:match("^([%a_][%w_]*)=(.*)$")
    if name then sh:setVar(name, value) end
  end
  return 0
end

function B.unset(sh, args)
  for _, a in ipairs(args) do sh:setVar(a, nil) end
  return 0
end

function B.set(sh, args)
  if #args == 0 then
    for _, k in ipairs(sortedKeys(sh.vars)) do print(k .. "=" .. sh.vars[k]) end
    return 0
  end
  -- `set -- a b c` replaces the positional parameters
  if args[1] == "--" then
    sh:frame().args = { unpack(args, 2) }
  end
  return 0
end
B.env = function(sh)
  for _, k in ipairs(sortedKeys(sh.vars)) do print(k .. "=" .. sh.vars[k]) end
  print("PATH=" .. sh.pathString)
  return 0
end

function B.echo(sh, args)
  local newline, escapes = true, false
  local i = 1
  while args[i] and args[i]:match("^%-[ne]+$") do
    if args[i]:find("n", 1, true) then newline = false end
    if args[i]:find("e", 1, true) then escapes = true end
    i = i + 1
  end
  local text = table.concat({ unpack(args, i) }, " ")
  if escapes then
    text = text:gsub("\\(.)", function(c)
      if c == "n" then return "\n" elseif c == "t" then return "\t" elseif c == "\\" then return "\\" end
      return "\\" .. c
    end)
  end
  if newline then print(text) else write(text) end
  return 0
end

function B.printf(sh, args)
  local fmt = args[1]
  if not fmt then return 1 end
  fmt = fmt:gsub("\\(.)", function(c)
    if c == "n" then return "\n" elseif c == "t" then return "\t" elseif c == "\\" then return "\\" end
    return "\\" .. c
  end)
  local n = 1
  local out = fmt:gsub("%%([%-%d%.]*)([sdixfc%%])", function(flags, conv)
    if conv == "%" then return "%" end
    n = n + 1
    local v = args[n]
    if conv == "s" then return string.format("%" .. flags .. "s", v or "")
    elseif conv == "c" then return (v or ""):sub(1, 1)
    elseif conv == "f" then return string.format("%" .. flags .. "f", tonumber(v) or 0)
    elseif conv == "x" then return string.format("%x", math.floor(tonumber(v) or 0))
    else return string.format("%.0f", math.floor(tonumber(v) or 0)) end
  end)
  write(out)
  return 0
end

function B.history(sh, args)
  if args[1] == "-c" then sh.history = {} return 0 end
  local h = sh.history
  local from = 1
  local n = tonumber(args[1])
  if n then from = math.max(1, #h - n + 1) end
  for i = from, #h do print(("%4d  %s"):format(i, h[i])) end
  return 0
end

function B.source(sh, args)
  local file = args[1]
  if not file then sh:err("source: file name required") return 2 end
  local p = sh:resolve(file)
  if not fs.exists(p) or fs.isDir(p) then
    -- like a program lookup, so `source name` finds scripts on the path
    p = sh:findProgram(file)
  end
  if not p then sh:err("source: " .. file .. ": No such file") return 1 end
  local src = fileText(p)
  return sh:runScript(src, p, { unpack(args, 2) })
end
B["."] = B.source

function B.eval(sh, args)
  local st = sh:runString(table.concat(args, " "))
  return st
end

local function describe(sh, name)
  if sh.aliases[name] then return "alias", name .. " is aliased to '" .. sh.aliases[name] .. "'" end
  if rawget(B, name) then return "builtin", name .. " is a shell builtin" end
  local p = sh:findProgram(name)
  if p then return "file", name .. " is /" .. p end
  return nil
end

function B.type(sh, args)
  local status = 0
  for _, name in ipairs(args) do
    local _, text = describe(sh, name)
    if text then print(text) else sh:err("type: " .. name .. ": not found") status = 1 end
  end
  return status
end

function B.which(sh, args)
  local status = 0
  for _, name in ipairs(args) do
    local kind, text = describe(sh, name)
    if kind == "file" then print("/" .. sh:findProgram(name))
    elseif kind then print(text)
    else status = 1 end
  end
  return status
end

function B.read(sh, args)
  local prompt
  local names = {}
  local i = 1
  while i <= #args do
    if args[i] == "-p" then prompt = args[i + 1] i = i + 2
    else names[#names + 1] = args[i] i = i + 1 end
  end
  if #names == 0 then names[1] = "REPLY" end
  local line
  if sh.stdin then
    line = sh.stdin.readLine(false)
  else
    if prompt then write(prompt) end
    line = read()
  end
  if line == nil then
    for _, n in ipairs(names) do sh:setVar(n, "") end
    return 1
  end
  for idx, n in ipairs(names) do
    if idx == #names then
      sh:setVar(n, (line:gsub("^%s+", "")))
    else
      local word, rest = line:match("^%s*(%S*)%s*(.*)$")
      sh:setVar(n, word or "")
      line = rest or ""
    end
  end
  return 0
end

function B.shift(sh, args)
  local n = tonumber(args[1]) or 1
  local a = sh:frame().args
  if n > #a then return 1 end
  for _ = 1, n do table.remove(a, 1) end
  return 0
end

function B.sleep(sh, args)
  local n = tonumber(args[1])
  if not n then sh:err("sleep: need a number of seconds") return 1 end
  sleep(n)
  return 0
end

function B.expr(sh, args)
  local parse = require("tsr.shell.parse")
  print(tostring(parse.arith(table.concat(args, " "), { getVar = function(n) return sh:getVar(n) end })))
  return 0
end

-- test / [ -------------------------------------------------------------------------------------------------------

local function evalTest(sh, a)
  local n = #a
  if n == 0 then return false end
  if a[1] == "!" then return not evalTest(sh, { unpack(a, 2) }) end
  -- split on -o / -a (lowest precedence first)
  for i = 1, n do
    if a[i] == "-o" and i > 1 and i < n then
      return evalTest(sh, { unpack(a, 1, i - 1) }) or evalTest(sh, { unpack(a, i + 1) })
    end
  end
  for i = 1, n do
    if a[i] == "-a" and i > 1 and i < n then
      return evalTest(sh, { unpack(a, 1, i - 1) }) and evalTest(sh, { unpack(a, i + 1) })
    end
  end
  if n == 1 then return a[1] ~= "" end
  if n == 2 then
    local op, v = a[1], a[2]
    if op == "-e" then return fs.exists(sh:resolve(v)) end
    if op == "-f" then local p = sh:resolve(v) return fs.exists(p) and not fs.isDir(p) end
    if op == "-d" then return fs.isDir(sh:resolve(v)) end
    if op == "-s" then local p = sh:resolve(v) return fs.exists(p) and not fs.isDir(p) and fs.getSize(p) > 0 end
    if op == "-z" then return v == "" end
    if op == "-n" then return v ~= "" end
    return false
  end
  if n == 3 then
    local x, op, y = a[1], a[2], a[3]
    if op == "=" or op == "==" then return x == y end
    if op == "!=" then return x ~= y end
    local nx, ny = tonumber(x), tonumber(y)
    if nx and ny then
      if op == "-eq" then return nx == ny end
      if op == "-ne" then return nx ~= ny end
      if op == "-lt" then return nx < ny end
      if op == "-le" then return nx <= ny end
      if op == "-gt" then return nx > ny end
      if op == "-ge" then return nx >= ny end
    end
  end
  return false
end

B.test = function(sh, args) return evalTest(sh, args) and 0 or 1 end
B["["] = function(sh, args)
  if args[#args] ~= "]" then sh:err("[: missing ]") return 2 end
  return evalTest(sh, { unpack(args, 1, #args - 1) }) and 0 or 1
end

-- completion hints for tab completion (kept off the table itself so listing builtins stays clean)
return setmetatable(B, {
  __index = {
    completion = { cd = "dirs", export = "vars", unset = "vars", unalias = "aliases", alias = "aliases",
                   type = "programs", which = "programs" },
  },
})
