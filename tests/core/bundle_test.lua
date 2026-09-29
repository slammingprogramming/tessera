-- SPDX-License-Identifier: AGPL-3.0-or-later
local bundle = require("tsr.bundle")
local hash = require("tsr.hash")

local fx = dofile("/tests/fixtures/bundle_fixtures.lua")

local function check(result)
  ok(result, "bundle did not parse")
  eq(result.index.packages.demo.version, "1.0.0")
  eq(result.packages.demo.name, "demo")
  for _, sha in ipairs(fx.blobs) do
    ok(result.blobs[sha], "missing blob " .. sha)
    eq(hash.sha256(result.blobs[sha]), sha)
  end
end

test("file bundle (TSRZ) parses", function()
  check(bundle.parse(hash.base64Decode(fx.file_b64)))
end)

test("pasted chunks assemble in order", function()
  local asm = bundle.newAssembler()
  for i, line in ipairs(fx.lines) do
    local st, d = asm:add(line)
    eq(st, "ok")
    eq(d, i)
  end
  ok(asm:complete())
  check(asm:result())
end)

test("pasted chunks assemble out of order, with duplicates and noise", function()
  local asm = bundle.newAssembler()
  eq(asm:add(""), "ignored")
  eq(asm:add("> some prompt noise"), "ignored")
  for i = #fx.lines, 1, -1 do eq((asm:add("  " .. fx.lines[i] .. "  ")), "ok") end
  eq((asm:add(fx.lines[2])), "dup")
  check(asm:result())
end)

test("missing chunks are reported and result() refuses", function()
  local asm = bundle.newAssembler()
  for i, line in ipairs(fx.lines) do
    if i ~= 2 and i ~= 4 then asm:add(line) end
  end
  ok(not asm:complete())
  eq(asm:missing(), { 2, 4 })
  local r, err = asm:result()
  ok(r == nil and err)
  asm:add(fx.lines[2])
  asm:add(fx.lines[4])
  check(asm:result())
end)

test("corrupted chunks are rejected so they can be re-pasted", function()
  local asm = bundle.newAssembler()
  local line = fx.lines[3]
  local broken = line:sub(1, #line - 3) .. (line:sub(-3) == "AAA" and "BBB" or "AAA")
  local st, why = asm:add(broken)
  eq(st, "bad")
  ok(why:find("checksum"))
  eq((asm:add(line)), "ok")
  eq((asm:add("TSR1 garbage")), "bad")
end)

test("chunks from a different bundle are rejected", function()
  local asm = bundle.newAssembler()
  asm:add(fx.lines[1])
  local other = fx.lines[2]:gsub(fx.id, "deadbeef", 1)
  local st = asm:add(other)
  eq(st, "bad")
end)

test("text file of chunk lines parses through bundle.parse", function()
  check(bundle.parse(table.concat(fx.lines, "\n") .. "\n"))
end)

test("garbage is not a bundle", function()
  local r, err = bundle.parse("hello world")
  ok(r == nil and err)
  r, err = bundle.parseContainer("TSRB\2\0\0")
  ok(r == nil and err:find("version"))
end)

test("a tampered blob is detected", function()
  local bin = hash.base64Decode(fx.file_b64)
  -- flip one byte inside the deflate stream; must fail to parse (inflate error or hash mismatch)
  local i = math.floor(#bin / 2)
  local tampered = bin:sub(1, i - 1) .. string.char((bin:byte(i) + 1) % 256) .. bin:sub(i + 1)
  local r = bundle.parse(tampered)
  ok(r == nil, "tampered bundle should not parse")
end)
