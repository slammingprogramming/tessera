-- SPDX-License-Identifier: AGPL-3.0-or-later
local parse = require("tsr.shell.parse")

local function ctx(vars, subst)
  return {
    getVar = function(n) return vars and vars[n] end,
    subst = subst or function(s) return "<" .. s .. ">" end,
    home = "/home",
    find = function(p) return { p .. "1", p .. "2" } end,
  }
end

local function words(src, c)
  local ast = assert(parse.parse(src))
  local node = ast.items[1].node
  local out = {}
  for _, w in ipairs(node.words) do
    for _, s in ipairs(parse.expand(w, c or ctx())) do out[#out + 1] = s end
  end
  return out
end

test("plain words and whitespace", function()
  eq(words("echo  hello   world"), { "echo", "hello", "world" })
end)

test("quotes group words and stop expansion", function()
  eq(words([[echo 'a b' "c d" e\ f]]), { "echo", "a b", "c d", "e f" })
  eq(words([[echo '$X' "$X"]], ctx({ X = "v" })), { "echo", "$X", "v" })
end)

test("empty quoted argument is kept", function()
  eq(words([[echo "" x]]), { "echo", "", "x" })
end)

test("variables expand and unquoted ones split", function()
  local c = ctx({ A = "one two", B = "x" })
  eq(words("echo $A", c), { "echo", "one", "two" })
  eq(words('echo "$A"', c), { "echo", "one two" })
  eq(words("echo ${B}y $B$B", c), { "echo", "xy", "xx" })
  eq(words("echo $UNSET end", c), { "echo", "end" })
end)

test("default values and special variables", function()
  eq(words("echo ${NOPE:-fallback}", ctx({})), { "echo", "fallback" })
  eq(words("echo ${A:-fallback}", ctx({ A = "set" })), { "echo", "set" })
  eq(words("echo $? $1 $#", ctx({ ["?"] = 3, ["1"] = "a", ["#"] = 2 })), { "echo", "3", "a", "2" })
end)

test("command substitution and arithmetic", function()
  eq(words("echo $(date now)"), { "echo", "<date", "now>" })
  eq(words([[echo "$(date now)"]]), { "echo", "<date now>" })
  eq(words('echo "x$(y)z"'), { "echo", "x<y>z" })
  eq(words("echo $((1 + 2 * 3))"), { "echo", "7" })
  eq(words("echo $(($N + 1))", ctx({ N = "9" })), { "echo", "10" })
  eq(parse.arith("10 / 3", ctx()), 3)
  eq(parse.arith("evil()", ctx()), 0)
  eq(parse.arith("1 / 0", ctx()), 0)
end)

test("globs expand only when unquoted", function()
  eq(words("ls *.lua"), { "ls", "*.lua1", "*.lua2" })
  eq(words("ls '*.lua'"), { "ls", "*.lua" })
  eq(words([[ls \*]]), { "ls", "*" })
end)

test("tilde expands to home", function()
  eq(words("cd ~ ~/x ~y"), { "cd", "/home", "/home/x", "~y" })
end)

test("operators build the expected tree", function()
  local ast = assert(parse.parse("a | b | c"))
  eq(ast.items[1].node.type, "pipeline")
  eq(#ast.items[1].node.cmds, 3)
  ast = assert(parse.parse("a && b || c"))
  eq(ast.items[1].node.type, "or")
  eq(ast.items[1].node.left.type, "and")
  ast = assert(parse.parse("a; b\nc &"))
  eq(#ast.items, 3)
  eq(ast.items[3].bg, true)
end)

test("redirects attach to the command", function()
  local ast = assert(parse.parse("sort < in > out"))
  local n = ast.items[1].node
  eq(#n.words, 1)
  eq({ n.redirs[1].op, n.redirs[2].op }, { "<", ">" })
  ast = assert(parse.parse("echo hi >> log"))
  eq(ast.items[1].node.redirs[1].op, ">>")
end)

test("comments are ignored", function()
  local ast = assert(parse.parse("echo a # not this\n# nor this\necho b"))
  eq(#ast.items, 2)
end)

test("compound commands parse", function()
  local ast = assert(parse.parse("if a; then b; elif c; then d; else e; fi"))
  local n = ast.items[1].node
  eq(n.type, "if")
  eq(#n.branches, 2)
  ok(n.elseBody)
  ast = assert(parse.parse("for x in 1 2 3; do echo $x; done"))
  eq(ast.items[1].node.type, "for")
  eq(#ast.items[1].node.words, 3)
  ast = assert(parse.parse("while a\ndo\n b\ndone"))
  eq(ast.items[1].node.type, "while")
  ast = assert(parse.parse("until a; do b; done"))
  eq(ast.items[1].node.negate, true)
end)

test("syntax errors are reported and unfinished input is flagged", function()
  local ast, err, incomplete = parse.parse("echo 'oops")
  ok(not ast and incomplete)
  ast, err, incomplete = parse.parse("if a; then b")
  ok(not ast and incomplete)
  ast, err, incomplete = parse.parse("a | | b")
  ok(not ast and not incomplete, err)
  ast, err, incomplete = parse.parse("fi")
  ok(not ast and not incomplete)
  ast, err = parse.parse("echo >")
  ok(not ast)
  ast, err = parse.parse("echo $(foo")
  ok(not ast)
end)
