-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Small shared helpers. Only add things that at least two modules need.
local M = {}

function M.split(s, sep, max)
  local out, pos = {}, 1
  sep = sep or ","
  while true do
    if max and #out >= max - 1 then break end
    local a, b = s:find(sep, pos, true)
    if not a then break end
    out[#out + 1] = s:sub(pos, a - 1)
    pos = b + 1
  end
  out[#out + 1] = s:sub(pos)
  return out
end

function M.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

function M.startswith(s, p) return s:sub(1, #p) == p end

function M.endswith(s, p) return p == "" or s:sub(-#p) == p end

function M.copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end

function M.deepcopy(t, seen)
  if type(t) ~= "table" then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end
  local o = {}
  seen[t] = o
  for k, v in pairs(t) do o[M.deepcopy(k, seen)] = M.deepcopy(v, seen) end
  return o
end

--- Recursively merge `src` into `dst` (tables merge, everything else overwrites). Returns dst.
function M.merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      M.merge(dst[k], v)
    else
      dst[k] = M.deepcopy(v)
    end
  end
  return dst
end

function M.sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b)
    if type(a) == type(b) then return a < b end
    return tostring(a) < tostring(b)
  end)
  return ks
end

function M.fmtBytes(n)
  if n < 1024 then return string.format("%d B", n) end
  if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
  return string.format("%.2f MB", n / 1024 / 1024)
end

--- Timestamp used in logs, e.g. "2026-09-29 12:34:56".
function M.timestamp()
  local ok, s = pcall(os.date, "%Y-%m-%d %H:%M:%S")
  return ok and s or tostring(os.clock())
end

return M
