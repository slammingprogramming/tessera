-- SPDX-License-Identifier: AGPL-3.0-or-later
-- tsh parser: lexer + recursive-descent parser + word expansion.
--
-- Syntax (a practical Bourne-like subset):
--   cmd arg 'single' "double $VAR" $(command) ${VAR} ~ * ?     words, quoting, expansion, globs
--   a | b      a > file   a >> file   a < file                  pipes and redirects
--   a ; b      a && b     a || b      a &                       lists, and/or, background (runs synchronously)
--   if cmd; then ...; elif ...; else ...; fi
--   for x in a b c; do ...; done        while cmd; do ...; done        until cmd; do ...; done
--   # comment                                                    to end of line
-- AST node types: simple, pipeline, and, or, list, if, for, while.
local M = {}

local KEYWORDS = { ["if"] = true, ["then"] = true, ["elif"] = true, ["else"] = true, ["fi"] = true, ["for"] = true,
                   ["in"] = true, ["do"] = true, ["done"] = true, ["while"] = true, ["until"] = true }
M.KEYWORDS = KEYWORDS

---------------------------------------------------------------------------------------------------------------------
-- Lexer
---------------------------------------------------------------------------------------------------------------------

local function isSpace(c) return c == " " or c == "\t" or c == "\r" end

--- Read a balanced $( ... ) starting at the "(" at position i. Returns inner text, position after ")".
local function readSubst(src, i)
  local depth, j = 1, i + 1
  while j <= #src do
    local c = src:sub(j, j)
    if c == "(" then depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
      if depth == 0 then return src:sub(i + 1, j - 1), j + 1 end
    elseif c == "'" then
      local e = src:find("'", j + 1, true)
      if not e then break end
      j = e
    end
    j = j + 1
  end
  return nil
end

--- Variable reference at src[i] == "$": returns name, position after, or nil when the "$" is just a character.
local function readVar(src, i)
  local nx = src:sub(i + 1, i + 1)
  if nx == "{" then
    local e = src:find("}", i + 2, true)
    if not e then return nil end
    return src:sub(i + 2, e - 1), e + 1
  elseif nx == "?" or nx == "@" or nx == "#" or nx == "*" then
    return nx, i + 2
  elseif nx:match("^[%a_]$") then
    local name = src:match("^[%w_]+", i + 1)
    return name, i + 1 + #name
  elseif nx:match("^%d$") then
    return nx, i + 2
  end
  return nil
end

--- $(cmd) is a command substitution, $((expr)) is arithmetic.
local function substSeg(inner, q)
  local expr = inner:match("^%((.*)%)$")
  if expr then return { arith = expr, q = q } end
  return { cmd = inner, q = q }
end

--- Tokenize. Returns array of tokens: { t = "word", segs = {...} } or { t = "op", v = "|" } or { t = "nl" }; or nil + error.
--- Word segments: { lit = "text", q = "bare"|"sq"|"dq" }, { var = "NAME", q = ... }, { cmd = "text", q = ... }.
function M.lex(src)
  local toks = {}
  local i, n = 1, #src
  while i <= n do
    local c = src:sub(i, i)
    if isSpace(c) then
      i = i + 1
    elseif c == "\n" then
      toks[#toks + 1] = { t = "nl" }
      i = i + 1
    elseif c == "#" then
      while i <= n and src:sub(i, i) ~= "\n" do i = i + 1 end
    elseif c == "|" then
      if src:sub(i + 1, i + 1) == "|" then toks[#toks + 1] = { t = "op", v = "||" } i = i + 2
      else toks[#toks + 1] = { t = "op", v = "|" } i = i + 1 end
    elseif c == "&" then
      if src:sub(i + 1, i + 1) == "&" then toks[#toks + 1] = { t = "op", v = "&&" } i = i + 2
      else toks[#toks + 1] = { t = "op", v = "&" } i = i + 1 end
    elseif c == ";" then
      toks[#toks + 1] = { t = "op", v = ";" }
      i = i + 1
    elseif c == ">" then
      if src:sub(i + 1, i + 1) == ">" then toks[#toks + 1] = { t = "op", v = ">>" } i = i + 2
      else toks[#toks + 1] = { t = "op", v = ">" } i = i + 1 end
    elseif c == "<" then
      toks[#toks + 1] = { t = "op", v = "<" }
      i = i + 1
    else
      -- a word
      local segs = {}
      local buf = {}
      local function flush(q)
        if #buf > 0 then segs[#segs + 1] = { lit = table.concat(buf), q = q or "bare" } buf = {} end
      end
      while i <= n do
        local ch = src:sub(i, i)
        if isSpace(ch) or ch == "\n" or ch == "|" or ch == "&" or ch == ";" or ch == ">" or ch == "<" then break end
        if ch == "\\" then
          local nx = src:sub(i + 1, i + 1)
          if nx == "" then buf[#buf + 1] = "\\" i = i + 1
          else
            -- an escaped character is literal and must not glob: store it quoted
            flush("bare")
            segs[#segs + 1] = { lit = nx, q = "sq" }
            i = i + 2
          end
        elseif ch == "'" then
          flush("bare")
          local e = src:find("'", i + 1, true)
          if not e then return nil, "unterminated ' quote", true end
          segs[#segs + 1] = { lit = src:sub(i + 1, e - 1), q = "sq" }
          i = e + 1
        elseif ch == '"' then
          flush("bare")
          i = i + 1
          local dbuf = {}
          local closed = false
          while i <= n do
            local d = src:sub(i, i)
            if d == '"' then closed = true i = i + 1 break end
            if d == "\\" and (src:sub(i + 1, i + 1) == '"' or src:sub(i + 1, i + 1) == "\\" or src:sub(i + 1, i + 1) == "$") then
              dbuf[#dbuf + 1] = src:sub(i + 1, i + 1)
              i = i + 2
            elseif d == "$" and src:sub(i + 1, i + 1) == "(" then
              if #dbuf > 0 then segs[#segs + 1] = { lit = table.concat(dbuf), q = "dq" } dbuf = {} end
              local inner, after = readSubst(src, i + 1)
              if not inner then return nil, "unterminated $(", true end
              segs[#segs + 1] = substSeg(inner, "dq")
              i = after
            elseif d == "$" and readVar(src, i) ~= nil then
              if #dbuf > 0 then segs[#segs + 1] = { lit = table.concat(dbuf), q = "dq" } dbuf = {} end
              local name, after = readVar(src, i)
              segs[#segs + 1] = { var = name, q = "dq" }
              i = after
            else
              dbuf[#dbuf + 1] = d
              i = i + 1
            end
          end
          if not closed then return nil, 'unterminated " quote', true end
          if #dbuf > 0 then segs[#segs + 1] = { lit = table.concat(dbuf), q = "dq" } end
          if #dbuf == 0 and (#segs == 0 or segs[#segs].q ~= "dq") then segs[#segs + 1] = { lit = "", q = "dq" } end
        elseif ch == "$" and src:sub(i + 1, i + 1) == "(" then
          flush("bare")
          local inner, after = readSubst(src, i + 1)
          if not inner then return nil, "unterminated $(", true end
          segs[#segs + 1] = substSeg(inner, "bare")
          i = after
        elseif ch == "$" and readVar(src, i) ~= nil then
          flush("bare")
          local name, after = readVar(src, i)
          segs[#segs + 1] = { var = name, q = "bare" }
          i = after
        else
          buf[#buf + 1] = ch
          i = i + 1
        end
      end
      flush("bare")
      toks[#toks + 1] = { t = "word", segs = segs }
    end
  end
  return toks
end

--- If the token is a plain bare word, return its text (used for keywords and for `for x in`).
local function plain(tok)
  if tok and tok.t == "word" and #tok.segs == 1 and tok.segs[1].lit and tok.segs[1].q == "bare" then return tok.segs[1].lit end
end

---------------------------------------------------------------------------------------------------------------------
-- Parser
---------------------------------------------------------------------------------------------------------------------

local P = {}
P.__index = P

function P:peek() return self.toks[self.i] end
function P:next() local t = self.toks[self.i] self.i = self.i + 1 return t end
function P:isOp(v) local t = self:peek() return t and t.t == "op" and t.v == v end
function P:isKw(v) local t = self:peek() return plain(t) == v end

function P:skipSeps()
  while true do
    local t = self:peek()
    if t and (t.t == "nl" or (t.t == "op" and t.v == ";")) then self.i = self.i + 1 else return end
  end
end

function P:fail(msg) self.err = self.err or msg return nil end

--- list := and_or { (";" | "&" | newline) and_or }  — stops at a keyword in `stop` (set) or end of input.
function P:parseList(stop)
  local items = {}
  self:skipSeps()
  while true do
    local t = self:peek()
    if not t then break end
    local kw = plain(t)
    if kw and stop and stop[kw] then break end
    local node = self:parseAndOr()
    if not node then return nil end
    local bg = false
    if self:isOp("&") then self.i = self.i + 1 bg = true end
    items[#items + 1] = { node = node, bg = bg }
    self:skipSeps()
  end
  return { type = "list", items = items }
end

function P:parseAndOr()
  local left = self:parsePipeline()
  if not left then return nil end
  while self:isOp("&&") or self:isOp("||") do
    local op = self:next().v
    -- allow a newline after && and ||
    while self:peek() and self:peek().t == "nl" do self.i = self.i + 1 end
    local right = self:parsePipeline()
    if not right then return nil end
    left = { type = op == "&&" and "and" or "or", left = left, right = right }
  end
  return left
end

function P:parsePipeline()
  local first = self:parseCommand()
  if not first then return nil end
  if not self:isOp("|") then return first end
  local cmds = { first }
  while self:isOp("|") do
    self.i = self.i + 1
    while self:peek() and self:peek().t == "nl" do self.i = self.i + 1 end
    local c = self:parseCommand()
    if not c then return nil end
    cmds[#cmds + 1] = c
  end
  return { type = "pipeline", cmds = cmds }
end

function P:expectKw(kw)
  if not self:isKw(kw) then return self:fail("expected '" .. kw .. "'") end
  self.i = self.i + 1
  return true
end

function P:parseCommand()
  local t = self:peek()
  if not t then return self:fail("unexpected end of input") end
  local kw = plain(t)
  if kw == "if" then
    self.i = self.i + 1
    local node = { type = "if", branches = {} }
    local cond = self:parseList({ ["then"] = true })
    if not cond or not self:expectKw("then") then return nil end
    local body = self:parseList({ ["elif"] = true, ["else"] = true, ["fi"] = true })
    if not body then return nil end
    node.branches[1] = { cond = cond, body = body }
    while self:isKw("elif") do
      self.i = self.i + 1
      local c = self:parseList({ ["then"] = true })
      if not c or not self:expectKw("then") then return nil end
      local b = self:parseList({ ["elif"] = true, ["else"] = true, ["fi"] = true })
      if not b then return nil end
      node.branches[#node.branches + 1] = { cond = c, body = b }
    end
    if self:isKw("else") then
      self.i = self.i + 1
      node.elseBody = self:parseList({ ["fi"] = true })
      if not node.elseBody then return nil end
    end
    if not self:expectKw("fi") then return nil end
    return node
  elseif kw == "for" then
    self.i = self.i + 1
    local var = plain(self:next())
    if not var then return self:fail("expected a variable name after 'for'") end
    local words = {}
    if self:isKw("in") then
      self.i = self.i + 1
      while self:peek() and self:peek().t == "word" and plain(self:peek()) ~= "do" do words[#words + 1] = self:next().segs end
    end
    self:skipSeps()
    if not self:expectKw("do") then return nil end
    local body = self:parseList({ ["done"] = true })
    if not body or not self:expectKw("done") then return nil end
    return { type = "for", var = var, words = words, body = body }
  elseif kw == "while" or kw == "until" then
    self.i = self.i + 1
    local cond = self:parseList({ ["do"] = true })
    if not cond or not self:expectKw("do") then return nil end
    local body = self:parseList({ ["done"] = true })
    if not body or not self:expectKw("done") then return nil end
    return { type = "while", cond = cond, body = body, negate = kw == "until" }
  elseif kw and KEYWORDS[kw] and kw ~= "in" then
    return self:fail("unexpected '" .. kw .. "'")
  end
  -- simple command
  local node = { type = "simple", words = {}, redirs = {} }
  while true do
    local tk = self:peek()
    if not tk then break end
    if tk.t == "word" then
      node.words[#node.words + 1] = self:next().segs
    elseif tk.t == "op" and (tk.v == ">" or tk.v == ">>" or tk.v == "<") then
      self.i = self.i + 1
      local target = self:peek()
      if not target or target.t ~= "word" then return self:fail("expected a file name after '" .. tk.v .. "'") end
      self.i = self.i + 1
      node.redirs[#node.redirs + 1] = { op = tk.v, target = target.segs }
    else
      break
    end
  end
  if #node.words == 0 and #node.redirs == 0 then
    local bad = self:peek()
    return self:fail(bad and bad.t == "op" and ("unexpected '" .. bad.v .. "'") or "empty command")
  end
  return node
end

--- Parse source text. Returns the AST (a `list` node), or nil + error + incomplete (true when more input would help,
--- e.g. an open `if` or quote: the REPL then asks for a continuation line).
function M.parse(src)
  local toks, err, incomplete = M.lex(src)
  if not toks then return nil, err, incomplete end
  local p = setmetatable({ toks = toks, i = 1 }, P)
  local ast = p:parseList(nil)
  if not ast then return nil, p.err or "syntax error", p.i > #toks end
  if p.i <= #toks then
    local t = p:peek()
    return nil, "unexpected " .. (t.t == "op" and ("'" .. t.v .. "'") or t.t)
  end
  return ast
end

---------------------------------------------------------------------------------------------------------------------
-- Expansion
---------------------------------------------------------------------------------------------------------------------

local function hasGlob(s) return s:find("[%*%?]") ~= nil end

--- Evaluate integer arithmetic: + - * / % and parentheses over numbers and variable names (unset names are 0).
function M.arith(expr, ctx)
  expr = expr:gsub("%$?{?([%a_][%w_]*)}?", function(name)
    local v = tonumber(ctx.getVar(name))
    return tostring(v or 0)
  end)
  expr = expr:gsub("%$(%d)", function(d) return tostring(tonumber(ctx.getVar(d)) or 0) end)
  if not expr:match("^[%d%s%+%-%*/%%%(%)]*$") then return 0 end
  local fn = load("return " .. expr, "=arith", "t", {})
  if not fn then return 0 end
  local ok, v = pcall(fn)
  if not ok or type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return 0 end
  if v >= 0 then return math.floor(v) end
  return -math.floor(-v)
end

--- Expand one word into a list of strings. ctx: getVar(name), subst(commandText) -> output, cwd(), find(pattern) -> list,
--- home. Quoting rules follow the shell: quoted text never splits or globs.
function M.expand(segs, ctx)
  local pieces = {}   -- { text, splittable, globbable }
  for idx, seg in ipairs(segs) do
    if seg.lit then
      local text = seg.lit
      if idx == 1 and seg.q == "bare" and text:sub(1, 1) == "~" and (#text == 1 or text:sub(2, 2) == "/") then
        text = (ctx.home or "/") .. text:sub(2)
      end
      pieces[#pieces + 1] = { text = text, split = false, glob = seg.q == "bare" }
    elseif seg.var then
      local name, default = seg.var:match("^([%w_]+):%-(.*)$")
      local value = ctx.getVar(name or seg.var)
      if name and (value == nil or value == "") then value = default end
      pieces[#pieces + 1] = { text = tostring(value or ""), split = seg.q == "bare", glob = false }
    elseif seg.arith then
      pieces[#pieces + 1] = { text = tostring(M.arith(seg.arith, ctx)), split = false, glob = false }
    elseif seg.cmd then
      local out = ctx.subst(seg.cmd) or ""
      out = out:gsub("\n+$", "")
      pieces[#pieces + 1] = { text = out, split = seg.q == "bare", glob = false }
    end
  end
  -- build fields; unquoted expansions split on whitespace
  local fields = { { text = "", glob = false, any = false } }
  local function cur() return fields[#fields] end
  for _, p in ipairs(pieces) do
    if p.split then
      local text = p.text
      local first = true
      for ws, word in text:gmatch("(%s*)(%S*)") do
        if word ~= "" or ws ~= "" then
          if ws ~= "" and not first and cur().any then fields[#fields + 1] = { text = "", glob = false, any = false } end
          if ws ~= "" and first and cur().any and word ~= "" then fields[#fields + 1] = { text = "", glob = false, any = false } end
          if word ~= "" then cur().text = cur().text .. word cur().any = true end
          first = false
        end
      end
    else
      cur().text = cur().text .. p.text
      cur().any = true
      if p.glob and hasGlob(p.text) then cur().glob = true end
    end
  end
  local out = {}
  for _, f in ipairs(fields) do
    if f.any or f.text ~= "" then
      if f.glob and ctx.find then
        local matches = ctx.find(f.text)
        if matches and #matches > 0 then
          table.sort(matches)
          for _, m in ipairs(matches) do out[#out + 1] = m end
        else
          out[#out + 1] = f.text
        end
      else
        out[#out + 1] = f.text
      end
    end
  end
  return out
end

--- Expand a word to exactly one string (redirect targets, assignments): no splitting is applied to the join.
function M.expandOne(segs, ctx)
  local list = M.expand(segs, ctx)
  return table.concat(list, " ")
end

return M
