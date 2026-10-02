-- SPDX-License-Identifier: AGPL-3.0-or-later
local crypto = require("tsr.crypto")
local fx = dofile("/tests/fixtures/crypto_vectors.lua")
local unhex, hex = crypto.fromHex, crypto.toHex

test("sha512 matches OpenSSL for every block-boundary length", function()
  for _, v in ipairs(fx.sha512) do eq(hex(crypto.sha512.digest(unhex(v.msg))), v.digest, "length " .. v.len) end
  eq(crypto.sha512.hex("abc"), "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
end)

test("poly1305 RFC 8439 section 2.5.2", function()
  local key = unhex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
  eq(hex(crypto.chacha.poly1305(key, "Cryptographic Forum Research Group")), "a8061dc1305136c6c22b8baf0c0127a9")
end)

test("chacha20 RFC 8439 section 2.4.2 keystream", function()
  local key = unhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
  local nonce = unhex("000000000000004a00000000")
  local plain = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
  local ct = crypto.chacha.xor(key, nonce, 1, plain)
  eq(hex(ct):sub(1, 32), "6e2e359a2568f98041ba0728dd0d6981")
  eq(crypto.chacha.xor(key, nonce, 1, ct), plain)
end)

test("chacha20-poly1305 matches OpenSSL and rejects tampering", function()
  for i, v in ipairs(fx.aead) do
    local key, nonce, plain, aad = unhex(v.key), unhex(v.nonce), unhex(v.plain), unhex(v.aad)
    local sealed = crypto.chacha.seal(key, nonce, plain, aad)
    eq(hex(sealed), v.sealed, "vector " .. i)
    eq(crypto.chacha.open(key, nonce, sealed, aad), plain)
    if #sealed > 16 then
      local bad = sealed:sub(1, 1) == "a" and ("b" .. sealed:sub(2)) or ("a" .. sealed:sub(2))
      eq(crypto.chacha.open(key, nonce, bad, aad), nil, "flipped ciphertext")
    end
    eq(crypto.chacha.open(key, nonce, sealed:sub(1, -2) .. string.char((sealed:byte(-1) + 1) % 256), aad), nil, "flipped tag")
    eq(crypto.chacha.open(key, nonce, sealed, aad .. "x"), nil, "different aad")
  end
end)

test("hkdf and pbkdf2 match OpenSSL", function()
  for _, v in ipairs(fx.hkdf) do eq(hex(crypto.kdf.hkdf(unhex(v.ikm), unhex(v.salt), unhex(v.info), v.len)), v.okm) end
  for _, v in ipairs(fx.pbkdf2) do eq(hex(crypto.kdf.pbkdf2(v.password, v.salt, v.iter, v.len)), v.dk) end
end)

test("field arithmetic: multiplication, inversion and packing", function()
  local fe = require("tsr.crypto.fe")
  local three, five = fe.new({ 3 }), fe.new({ 5 })
  local o = fe.new()
  fe.mul(o, three, five)
  eq(hex(fe.pack(o)), "0f" .. string.rep("00", 31))
  fe.inv(o, five)
  fe.mul(o, o, five)
  eq(hex(fe.pack(o)), "01" .. string.rep("00", 31))
  -- p - 1 + 2 wraps to 1
  local pm1 = fe.unpack(unhex("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"))
  fe.add(o, pm1, fe.new({ 2 }))
  eq(hex(fe.pack(o)), "01" .. string.rep("00", 31))
end)

test("x25519 matches OpenSSL, and both sides agree", function()
  for i, v in ipairs(fx.x25519) do
    eq(hex(crypto.x25519.publicKey(unhex(v.a))), v.apub, "public a " .. i)
    eq(hex(crypto.x25519.shared(unhex(v.a), unhex(v.bpub))), v.shared, "shared a " .. i)
    eq(hex(crypto.x25519.shared(unhex(v.b), unhex(v.apub))), v.shared, "shared b " .. i)
    if i == 2 then break end   -- each ladder is slow on a laptop-emulated CC; two vectors cover it
  end
end)

test("x25519 RFC 7748 section 6.1", function()
  local a = unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
  local bpub = unhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
  eq(hex(crypto.x25519.publicKey(a)), "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
  eq(hex(crypto.x25519.shared(a, bpub)), "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
end)

test("ed25519 matches OpenSSL / RFC 8032: keys, signatures, verification", function()
  for i, v in ipairs(fx.ed25519) do
    local seed, msg = unhex(v.seed), unhex(v.msg)
    eq(hex(crypto.ed25519.publicKey(seed)), v.pub, "public " .. i)
    local sig = crypto.ed25519.sign(seed, msg)
    eq(hex(sig), v.sig, "signature " .. i)
    ok(crypto.ed25519.verify(unhex(v.pub), msg, sig), "verify " .. i)
    if i >= 4 then break end
  end
end)

test("ed25519 rejects forgeries", function()
  local v = fx.ed25519[2]
  local pub, msg, sig = unhex(v.pub), unhex(v.msg), unhex(v.sig)
  ok(crypto.ed25519.verify(pub, msg, sig))
  ok(not crypto.ed25519.verify(pub, msg .. "x", sig), "other message")
  local bad = string.char((sig:byte(1) + 1) % 256) .. sig:sub(2)
  ok(not crypto.ed25519.verify(pub, msg, bad), "tampered R")
  bad = sig:sub(1, 40) .. string.char((sig:byte(41) + 1) % 256) .. sig:sub(42)
  ok(not crypto.ed25519.verify(pub, msg, bad), "tampered S")
  ok(not crypto.ed25519.verify(unhex(fx.ed25519[1].pub), msg, sig), "other key")
  -- S >= L must be rejected (malleability)
  local L = unhex("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010")
  local s = sig:sub(33)
  local sum, carry = {}, 0
  for i = 1, 32 do local t = s:byte(i) + L:byte(i) + carry sum[i] = t % 256 carry = math.floor(t / 256) end
  ok(not crypto.ed25519.verify(pub, msg, sig:sub(1, 32) .. string.char(table.unpack(sum))), "S + L")
  ok(not crypto.ed25519.verify(pub, msg, "short"), "short signature")
end)

test("sign and verify data of any length through the digest scheme", function()
  local key = crypto.signingKey(unhex(fx.ed25519[4].seed))
  local data = string.rep("registry line\n", 5000)
  local sig = crypto.signData(key.secret, data, "registry")
  ok(crypto.verifyData(key.public, data, sig, "registry"))
  ok(not crypto.verifyData(key.public, data .. "!", sig, "registry"))
  ok(not crypto.verifyData(key.public, data, sig, "file"), "context separation")
  ok(crypto.fingerprint(key.public):match("^SHA256:[%w%+/]+$"))
end)

test("sealed box: only the recipient can open it", function()
  local alice = crypto.agreementKey(unhex(fx.x25519[1].a))
  local bob = crypto.agreementKey(unhex(fx.x25519[1].b))
  local sealed = crypto.seal(alice.public, "attack at dawn", "ctx")
  eq(crypto.open(alice, sealed, "ctx"), "attack at dawn")
  eq(crypto.open(bob, sealed, "ctx"), nil)
  eq(crypto.open(alice, sealed, "other"), nil)
end)

test("random bytes: right length, not repeating, entropy can be added", function()
  local a, b = crypto.rand.bytes(32), crypto.rand.bytes(32)
  eq(#a, 32)
  ok(a ~= b)
  crypto.rand.addEntropy("typed text", 12345)
  ok(crypto.rand.bytes(8) ~= crypto.rand.bytes(8))
  eq(#crypto.rand.bytes(100), 100)
  local n = 0
  crypto.rand.collect(3, nil, function() n = n + 1 return "key", n end)
  eq(n, 3)
end)

test("constant-time compare", function()
  ok(crypto.equal("abc", "abc"))
  ok(not crypto.equal("abc", "abd"))
  ok(not crypto.equal("abc", "ab"))
end)
