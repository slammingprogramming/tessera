-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Line-based differences between texts and patches in the unified format that diff -u, git and patch use.
--   diff.edit(aKeys, bKeys)            -> ops { {op = "=" | "-" | "+", i = line in a, j = line in b} }   (Myers' O(ND) algorithm)
--   diff.unified(a, b, opts)           -> text of a unified diff, or "" when equal   opts: nameA, nameB, context (3)
--   diff.parse(patchText)              -> { { old = name, new = name, hunks = { { oldStart, oldLen, newStart, newLen, lines } } } }
--   diff.apply(text, hunks, opts)      -> new text, or nil + reason      opts: reverse, maxOffset (how far a hunk may have moved, 200)
-- A last line without a final newline is kept apart ("\ No newline at end of file"), exactly as the real tools do.
local M = {}

local yield
do
  local ok, y = pcall(require, "tsr.crypto.yield")
  yield = ok and y or { maybe = function() end }
end

M.MAX_EDIT = 2000       -- beyond this many edits the middle part is reported as one replacement instead of an exact minimum

--- Split text into lines. Returns lines, keys (what is compared: a last line without newline gets a marker), noeol (true when
--- the text does not end with a newline).
function M.split(text)
  local lines, keys = {}, {}
  local pos, len = 1, #text
  local noeol = false
  while pos <= len do
    local nl = text:find("\n", pos, true)
    if nl then
      local line = text:sub(pos, nl - 1)
      lines[#lines + 1] = line
      keys[#keys + 1] = line
      pos = nl + 1
    else
      local line = text:sub(pos)
      lines[#lines + 1] = line
      keys[#keys + 1] = line .. "\0"
      noeol = true
      pos = len + 1
    end
  end
  return lines, keys, noeol
end

local function myers(a, b, a0, a1, b0, b1, ops)
  -- the edit script between a[a0..a1] and b[b0..b1] (inclusive; either range may be empty), appended to ops
  local n, m = a1 - a0 + 1, b1 - b0 + 1
  if n == 0 then for j = b0, b1 do ops[#ops + 1] = { op = "+", j = j } end return end
  if m == 0 then for i = a0, a1 do ops[#ops + 1] = { op = "-", i = i } end return end
  local V = { [1] = 0 }
  local trace = {}
  local found
  local max = math.min(n + m, M.MAX_EDIT)
  for d = 0, max do
    local copy = {}
    for k = -d, d do copy[k] = V[k] end
    trace[d] = copy
    for k = -d, d, 2 do
      local x
      if k == -d or (k ~= d and (V[k - 1] or -1) < (V[k + 1] or -1)) then x = V[k + 1] or 0 else x = (V[k - 1] or 0) + 1 end
      local y = x - k
      while x < n and y < m and a[a0 + x] == b[b0 + y] do x = x + 1 y = y + 1 end
      V[k] = x
      if x >= n and y >= m then found = d break end
    end
    if found then break end
    if d % 50 == 0 then yield.maybe() end
  end
  if not found then
    -- too different to minimise: delete everything, insert everything
    for i = a0, a1 do ops[#ops + 1] = { op = "-", i = i } end
    for j = b0, b1 do ops[#ops + 1] = { op = "+", j = j } end
    return
  end
  -- walk back from (n, m) to (0, 0), collecting the script in reverse
  local rev = {}
  local x, y = n, m
  for d = found, 1, -1 do
    local v = trace[d]
    local k = x - y
    local prevK
    if k == -d or (k ~= d and (v[k - 1] or -1) < (v[k + 1] or -1)) then prevK = k + 1 else prevK = k - 1 end
    local px = v[prevK]
    local py = px - prevK
    while x > px and y > py do
      rev[#rev + 1] = { op = "=", i = a0 + x - 1, j = b0 + y - 1 }
      x = x - 1 y = y - 1
    end
    if x == px then
      rev[#rev + 1] = { op = "+", j = b0 + y - 1 }
      y = y - 1
    else
      rev[#rev + 1] = { op = "-", i = a0 + x - 1 }
      x = x - 1
    end
  end
  while x > 0 and y > 0 do
    rev[#rev + 1] = { op = "=", i = a0 + x - 1, j = b0 + y - 1 }
    x = x - 1 y = y - 1
  end
  for idx = #rev, 1, -1 do ops[#ops + 1] = rev[idx] end
end

function M.edit(a, b)
  local ops = {}
  local n, m = #a, #b
  local pre = 0
  while pre < n and pre < m and a[pre + 1] == b[pre + 1] do pre = pre + 1 end
  local suf = 0
  while suf < n - pre and suf < m - pre and a[n - suf] == b[m - suf] do suf = suf + 1 end
  for i = 1, pre do ops[#ops + 1] = { op = "=", i = i, j = i } end
  myers(a, b, pre + 1, n - suf, pre + 1, m - suf, ops)
  for t = 0, suf - 1 do ops[#ops + 1] = { op = "=", i = n - suf + 1 + t, j = m - suf + 1 + t } end
  return ops
end

local function rangeText(start, len)
  if len == 1 then return tostring(start) end
  return start .. "," .. len
end

function M.unified(a, b, opts)
  opts = opts or {}
  local ctx = opts.context or 3
  local al, ak, anoeol = M.split(a)
  local bl, bk, bnoeol = M.split(b)
  local ops = M.edit(ak, bk)
  local changes = {}
  for idx, o in ipairs(ops) do if o.op ~= "=" then changes[#changes + 1] = idx end end
  if #changes == 0 then return "" end
  local out = { "--- " .. (opts.nameA or "a"), "+++ " .. (opts.nameB or "b") }
  -- the number of lines of a and b consumed before each op
  local aBefore, bBefore = {}, {}
  local ca, cb = 0, 0
  for idx, o in ipairs(ops) do
    aBefore[idx], bBefore[idx] = ca, cb
    if o.op ~= "+" then ca = ca + 1 end
    if o.op ~= "-" then cb = cb + 1 end
  end
  local function emit(prefix, text, isLast, noeol)
    out[#out + 1] = prefix .. text
    if isLast and noeol then out[#out + 1] = "\\ No newline at end of file" end
  end
  local g = 1
  while g <= #changes do
    local first, last = changes[g], changes[g]
    while g < #changes and changes[g + 1] - last - 1 <= 2 * ctx do g = g + 1 last = changes[g] end
    g = g + 1
    local s, e = math.max(1, first - ctx), math.min(#ops, last + ctx)
    local oldLen, newLen = 0, 0
    for idx = s, e do
      if ops[idx].op ~= "+" then oldLen = oldLen + 1 end
      if ops[idx].op ~= "-" then newLen = newLen + 1 end
    end
    local oldStart = oldLen == 0 and aBefore[s] or aBefore[s] + 1
    local newStart = newLen == 0 and bBefore[s] or bBefore[s] + 1
    out[#out + 1] = ("@@ -%s +%s @@"):format(rangeText(oldStart, oldLen), rangeText(newStart, newLen))
    for idx = s, e do
      local o = ops[idx]
      if o.op == "=" then emit(" ", al[o.i], o.i == #al, anoeol)
      elseif o.op == "-" then emit("-", al[o.i], o.i == #al, anoeol)
      else emit("+", bl[o.j], o.j == #bl, bnoeol) end
    end
  end
  return table.concat(out, "\n") .. "\n"
end

--- Read a patch (one file or many).
function M.parse(text)
  local files, cur, hunk = {}, nil, nil
  local lines = M.split(text)
  local i = 1
  local function name(s) return (s:gsub("\t.*$", ""):gsub("%s+$", "")) end
  while i <= #lines do
    local line = lines[i]
    if line:sub(1, 4) == "--- " and lines[i + 1] and lines[i + 1]:sub(1, 4) == "+++ " then
      cur = { old = name(line:sub(5)), new = name(lines[i + 1]:sub(5)), hunks = {} }
      files[#files + 1] = cur
      i = i + 2
    elseif line:sub(1, 3) == "@@ " then
      if not cur then return nil, "line " .. i .. ": a hunk before any file header" end
      local os_, ol, ns, nl = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      if not os_ then return nil, "line " .. i .. ": cannot read the hunk header" end
      hunk = { oldStart = tonumber(os_), oldLen = ol == "" and 1 or tonumber(ol), newStart = tonumber(ns), newLen = nl == "" and 1 or tonumber(nl), lines = {} }
      cur.hunks[#cur.hunks + 1] = hunk
      i = i + 1
      local seenOld, seenNew = 0, 0
      while i <= #lines and (seenOld < hunk.oldLen or seenNew < hunk.newLen) do
        local l = lines[i]
        local c = l:sub(1, 1)
        if c == " " or l == "" then
          hunk.lines[#hunk.lines + 1] = { kind = " ", text = l:sub(2) }
          seenOld, seenNew = seenOld + 1, seenNew + 1
        elseif c == "-" then
          hunk.lines[#hunk.lines + 1] = { kind = "-", text = l:sub(2) }
          seenOld = seenOld + 1
        elseif c == "+" then
          hunk.lines[#hunk.lines + 1] = { kind = "+", text = l:sub(2) }
          seenNew = seenNew + 1
        elseif c == "\\" then
          local prev = hunk.lines[#hunk.lines]
          if prev then prev.noeol = true end
        else
          return nil, "line " .. i .. ": unexpected text inside a hunk: " .. l:sub(1, 30)
        end
        i = i + 1
      end
      if seenOld ~= hunk.oldLen or seenNew ~= hunk.newLen then return nil, "the patch ends inside a hunk" end
      while lines[i] and lines[i]:sub(1, 1) == "\\" do
        local prev = hunk.lines[#hunk.lines]
        if prev then prev.noeol = true end
        i = i + 1
      end
    else
      i = i + 1          -- "diff ...", "Index: ...", blank lines between files
    end
  end
  if #files == 0 then return nil, "no patch found (expected --- / +++ headers and @@ hunks)" end
  return files
end

local function keyOf(text, noeol) return noeol and (text .. "\0") or text end

--- Apply hunks to `text`. Every hunk's old lines (context and removed) must be found, at the stated place or within maxOffset
--- lines of it (patch's "offset"); nothing is changed otherwise. Returns text, report { hunks = n, offsets = { ... } }.
function M.apply(text, hunks, opts)
  opts = opts or {}
  local maxOffset = opts.maxOffset or 200
  local src, keys, noeol = M.split(text)
  local items = {}
  for i, line in ipairs(src) do items[i] = { text = line, noeol = noeol and i == #src or nil } end
  local out = {}
  local pos = 1
  local shift = 0
  local offsets = {}
  for h, hunk in ipairs(hunks) do
    local oldKeys, newItems = {}, {}
    for _, l in ipairs(hunk.lines) do
      local kind = l.kind
      if opts.reverse then if kind == "-" then kind = "+" elseif kind == "+" then kind = "-" end end
      if kind == " " or kind == "-" then oldKeys[#oldKeys + 1] = keyOf(l.text, l.noeol) end
      if kind == " " or kind == "+" then newItems[#newItems + 1] = { text = l.text, noeol = l.noeol } end
    end
    local start = opts.reverse and hunk.newStart or hunk.oldStart
    local len = opts.reverse and hunk.newLen or hunk.oldLen
    local expected = (len == 0 and start + 1 or start) + shift
    local function matchesAt(at)
      if at < pos or at + #oldKeys - 1 > #keys then return false end
      for k = 1, #oldKeys do if keys[at + k - 1] ~= oldKeys[k] then return false end end
      return true
    end
    local at
    for delta = 0, maxOffset do
      if matchesAt(expected + delta) then at = expected + delta break end
      if delta > 0 and matchesAt(expected - delta) then at = expected - delta break end
    end
    if not at then
      return nil, ("hunk %d (at line %d) does not fit: the text there is not what the patch expects"):format(h, start)
    end
    shift = at - (len == 0 and start + 1 or start)
    offsets[#offsets + 1] = at - (len == 0 and start + 1 or start) - 0
    for i = pos, at - 1 do out[#out + 1] = items[i] end
    for _, it in ipairs(newItems) do out[#out + 1] = it end
    pos = at + #oldKeys
  end
  for i = pos, #items do out[#out + 1] = items[i] end
  local parts = {}
  for idx, it in ipairs(out) do parts[idx] = it.text .. (it.noeol and "" or "\n") end
  return table.concat(parts), { hunks = #hunks, offsets = offsets }
end

return M
