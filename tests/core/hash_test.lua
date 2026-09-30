-- SPDX-License-Identifier: AGPL-3.0-or-later
local hash = require("tsr.hash")

test("sha256 published test vectors", function()
  eq(hash.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  eq(hash.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  eq(hash.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
end)

test("sha256 across block boundaries (55, 56, 63, 64, 65 bytes)", function()
  -- expected values computed with Node's crypto module
  local expect = {
    [55] = "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
    [56] = "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
    [63] = "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
    [64] = "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
    [65] = "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
  }
  for n, want in pairs(expect) do eq(hash.sha256(string.rep("a", n)), want, tostring(n) .. " bytes") end
end)

test("sha256 of binary data and a million-ish bytes", function()
  local all = {}
  for i = 0, 255 do all[#all + 1] = string.char(i) end
  eq(hash.sha256(table.concat(all)), "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880")
  eq(hash.sha256(string.rep("a", 100000)), "6d1cf22d7cc09b085dfc25ee1a1f3ae0265804c607bc2074ad253bcc82fd81ee")
end)

test("hmac-sha256 RFC 4231 vectors", function()
  eq(hash.hmacSha256(string.rep("\11", 20), "Hi There"),
    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
  eq(hash.hmacSha256("Jefe", "what do ya want for nothing?"),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
  -- key longer than the block size is hashed first (test case 6)
  eq(hash.hmacSha256(string.rep("\170", 131), "Test Using Larger Than Block-Size Key - Hash Key First"),
    "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
end)

test("crc32 known values", function()
  eq(hash.crc32(""), 0)
  eq(hash.crc32("123456789"), 0xCBF43926)
  eq(hash.crc32("The quick brown fox jumps over the lazy dog"), 0x414FA339)
  eq(hash.crc32("world", hash.crc32("hello ")), hash.crc32("hello world"))
end)

test("base64 round trips and rfc4648 vectors", function()
  eq(hash.base64Encode(""), "")
  eq(hash.base64Encode("f"), "Zg==")
  eq(hash.base64Encode("fo"), "Zm8=")
  eq(hash.base64Encode("foo"), "Zm9v")
  eq(hash.base64Encode("foobar"), "Zm9vYmFy")
  eq(hash.base64Decode("Zm9vYmFy"), "foobar")
  eq(hash.base64Decode("Zm8="), "fo")
  eq(hash.base64Decode("Zg=="), "f")
  eq(hash.base64Decode("Zm9v\n YmFy"), "foobar", "whitespace ignored")
  local bin = {}
  for i = 0, 255 do bin[#bin + 1] = string.char(i) end
  bin = table.concat(bin)
  eq(hash.base64Decode(hash.base64Encode(bin)), bin)
  local bad, err = hash.base64Decode("@@@@")
  ok(bad == nil and err)
  ok(select(1, hash.base64Decode("abc")) == nil)
end)

test("hex helpers", function()
  eq(hash.toHex("\0\255A"), "00ff41")
  eq(hash.fromHex("00ff41"), "\0\255A")
end)
