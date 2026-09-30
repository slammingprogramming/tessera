-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Shared helpers for command-line apps: option parsing, prompts and coloured output. Every function that talks to the
-- user goes through an `io` table, so apps can be driven by tests without a keyboard.
local C = {}

--- Parse `args` according to `spec`: { name = "bool" | "number" | "string", ... }, plus spec._alias = { y = "yes" }.
--- Accepts --name, --name value and --name=value. Returns positional (array), options (table), or nil + error.
function C.parse(args, spec)
  spec = spec or {}
  local alias = spec._alias or {}
  local pos, opts = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    local name, inline
    if a:sub(1, 2) == "--" then
      name = a:sub(3)
      local eq = name:find("=", 1, true)
      if eq then name, inline = name:sub(1, eq - 1), name:sub(eq + 1) end
    elseif a:match("^%-%a$") then
      name = alias[a:sub(2)]
      if not name then return nil, "unknown option " .. a end
    end
    if name then
      local kind = spec[name]
      if not kind then return nil, "unknown option --" .. name end
      if kind == "bool" then
        opts[name] = true
      else
        local value = inline
        if value == nil then i = i + 1 value = args[i] end
        if value == nil then return nil, "option --" .. name .. " needs a value" end
        if kind == "number" then
          value = tonumber(value)
          if not value then return nil, "option --" .. name .. " needs a number" end
        end
        opts[name] = value
      end
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end
  return pos, opts
end

local function color(c)
  if term.isColor() then term.setTextColor(c) end
end

--- The default io table: say/warn/err print (coloured), prompt reads a line, ask does yes/no.
function C.io()
  local io = {}
  function io.say(text) print(text) end
  function io.warn(text) color(colors.orange) print(text) color(colors.white) end
  function io.err(text) color(colors.red) print(text) color(colors.white) end
  function io.prompt(text, default)
    write(text .. (default ~= nil and (" [" .. tostring(default) .. "]") or "") .. ": ")
    local s = read()
    if s == nil or s == "" then return default end
    return s
  end
  --- Ask for a secret; what is typed is shown as *.
  function io.secret(text)
    write(text .. ": ")
    local s = read("*")
    if s == nil or s == "" then return nil end
    return s
  end
  function io.ask(text, default)
    write(text .. (default == false and " [y/N] " or " [Y/n] "))
    local s = read()
    if s == nil or s == "" then return default ~= false end
    return s:lower():sub(1, 1) == "y"
  end
  --- Wait for the player to change the inventory (or `seconds` to pass).
  function io.waitInventory(seconds)
    local t = os.startTimer(seconds or 5)
    while true do
      local ev, id = os.pullEvent()
      if ev == "turtle_inventory" or (ev == "timer" and id == t) then return end
    end
  end
  return io
end

--- Number from a positional/prompt value with a default; nil when it is not a positive integer.
function C.count(value, default)
  local n = tonumber(value)
  if n == nil then n = default end
  if n == nil or n < 1 or n ~= math.floor(n) then return nil end
  return n
end

--- Plain-text table: rows = array of arrays of strings. Returns lines.
function C.columns(rows, gap)
  gap = gap or 2
  local widths = {}
  for _, row in ipairs(rows) do
    for i, cell in ipairs(row) do widths[i] = math.max(widths[i] or 0, #tostring(cell)) end
  end
  local out = {}
  for _, row in ipairs(rows) do
    local parts = {}
    for i, cell in ipairs(row) do
      cell = tostring(cell)
      parts[i] = i < #row and (cell .. string.rep(" ", widths[i] - #cell + gap)) or cell
    end
    out[#out + 1] = table.concat(parts)
  end
  return out
end

--- Load an app module through the shared loader when Tessera is running, otherwise via a private loader.
function C.require(name)
  local req = (rawget(_G, "tsr") and tsr.require) or dofile("/sys/lib/tsr/loader.lua").require
  return req(name)
end

return C
