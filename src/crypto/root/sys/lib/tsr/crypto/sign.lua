-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Signing documents of any size. Ed25519 hashes the whole message twice with SHA-512, which is slow for a 100 KB registry index
-- on a game computer. So the signature covers a short, domain-separated statement instead:
--     "tessera-signature-v1" 0x00 <context> 0x00 SHA-256(document)
-- (SHA-256 is fast here and just as collision-resistant for this purpose). `context` separates uses: a signature made for a
-- registry index is never valid as a signature of a file or of a trust update.
-- tools/lib/sign.mjs implements the same scheme with Node's crypto for the build tooling.
local ed25519 = require("tsr.crypto.ed25519")
local kdf = require("tsr.crypto.kdf")

local M = {}

M.TAG = "tessera-signature-v1\0"

local function statement(data, context)
  return M.TAG .. (context or "") .. "\0" .. kdf.sha256(data)
end

--- 64-byte signature of `data` under the 32-byte secret seed.
function M.data(secret, data, context)
  return ed25519.sign(secret, statement(data, context))
end

--- Is `signature` valid for `data` under the 32-byte public key and `context`?
function M.verify(public, data, signature, context)
  return ed25519.verify(public, statement(data, context), signature)
end

return M
