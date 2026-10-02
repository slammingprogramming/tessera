-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Lua syntax colouring for the editor. highlight(lines) returns, for each line, a string with one colour letter per character:
--   k keyword, s string, c comment, n number, f well-known function/library, o other.
local M = {}

local KEYWORDS = {}
for w in ([[and break do else elseif end false for function goto if in local nil not or repeat return then true until while]]):gmatch("%a+") do
  KEYWORDS[w] = true
end

local LIBS = {}
for w in ([[print write read require pairs ipairs next type tostring tonumber pcall xpcall error assert select setmetatable getmetatable
  rawget rawset rawequal rawlen unpack table string math os fs term peripheral rednet redstone turtle http textutils colors colours
  keys shell parallel window settings disk gps vector paintutils sleep coroutine bit32 utf8]]):gmatch("%a+") do
  LIBS[w] = true
end

--- state: nil, or { kind = "string" | "comment", level = n } carried over from the previous line.
local function line(text, state)
  local out = {}
  local i, n = 1, #text
  local function fill(from, to, c) for k = from, to do out[k] = c end end
  while i <= n do
    if state then
      -- inside a long string/comment: look for the closing bracket
      local close = "]" .. string.rep("=", state.level) .. "]"
      local s, e = text:find(close, i, true)
      local c = state.kind == "comment" and "c" or "s"
      if s then fill(i, e, c) i = e + 1 state = nil else fill(i, n, c) i = n + 1 end
    else
      local ch = text:sub(i, i)
      if text:sub(i, i + 1) == "--" then
        local eq = text:match("^%-%-%[(=*)%[", i)
        if eq then
          state = { kind = "comment", level = #eq }
          fill(i, i + 3 + #eq, "c")
          i = i + 4 + #eq
        else
          fill(i, n, "c")
          i = n + 1
        end
      elseif ch == '"' or ch == "'" then
        local j = i + 1
        while j <= n do
          local cj = text:sub(j, j)
          if cj == "\\" then j = j + 2
          elseif cj == ch then break
          else j = j + 1 end
        end
        fill(i, math.min(j, n), "s")
        i = j + 1
      elseif ch == "[" and text:match("^%[=*%[", i) then
        local eq = text:match("^%[(=*)%[", i)
        state = { kind = "string", level = #eq }
        fill(i, i + 1 + #eq, "s")
        i = i + 2 + #eq
      elseif ch:match("%d") or (ch == "." and text:sub(i + 1, i + 1):match("%d")) then
        local num = text:match("^0[xX]%x+", i) or text:match("^%d*%.?%d+[eE][%+%-]?%d+", i) or text:match("^%d*%.?%d*", i)
        fill(i, i + #num - 1, "n")
        i = i + math.max(1, #num)
      elseif ch:match("[%a_]") then
        local word = text:match("^[%w_]+", i)
        local c = "o"
        if KEYWORDS[word] then c = "k" elseif LIBS[word] then c = "f" end
        fill(i, i + #word - 1, c)
        i = i + #word
      else
        out[i] = "o"
        i = i + 1
      end
    end
  end
  for k = 1, n do out[k] = out[k] or "o" end
  return table.concat(out), state
end

--- Colour letters for every line of `lines`.
function M.highlight(lines)
  local result, state = {}, nil
  for y, text in ipairs(lines) do
    result[y], state = line(text, state)
  end
  return result
end

--- Just one line given the multi-line state before it (used for incremental redraws): returns letters, stateAfter.
M.line = line

return M
