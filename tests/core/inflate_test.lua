-- SPDX-License-Identifier: AGPL-3.0-or-later
local inflate = require("tsr.inflate")
local hash = require("tsr.hash")

local fixtures = dofile("/tests/fixtures/deflate_fixtures.lua")

for _, fx in ipairs(fixtures) do
  test("inflate: " .. fx.name, function()
    local z = hash.base64Decode(fx.b64)
    local data, nextPos = inflate.inflate(z)
    eq(#data, fx.len)
    eq(hash.sha256(data), fx.sha)
    eq(nextPos, #z + 1, "should consume the whole stream")
  end)
end

test("inflate rejects truncated and corrupt data", function()
  local z = hash.base64Decode(fixtures[3].b64)
  throws(function() inflate.inflate(z:sub(1, #z - 10)) end, "inflate")
  throws(function() inflate.inflate("\255\255\255\255") end, "inflate")
end)

test("inflate honours a start offset", function()
  local z = hash.base64Decode(fixtures[2].b64)
  local data, nextPos = inflate.inflate("HEADER" .. z, 7)
  eq(hash.sha256(data), fixtures[2].sha)
  eq(nextPos, 6 + #z + 1)
end)
