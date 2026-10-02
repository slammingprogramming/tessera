-- SPDX-License-Identifier: AGPL-3.0-or-later
-- An in-game key server: computers of a base publish their public keys to one computer (service "keyserver") and others look keys up
-- there. Only paired computers can talk to it (see tsr.net), and only PUBLIC key material is ever stored: whatever is uploaded
-- is re-exported as a public block. Certifications travel with the keys, so signing parties work: certify, then send-keys again.
local pgp = require("tsr.pgp")
local ring = require("tsr.pgp.ring")

local M = {}

M.DIR = "/var/lib/tsr/keyserver"
M.MAX_KEYS = 500

local function store() return ring.open(M.DIR) end

--- Register the "keyserver" service on a net node.
function M.serve(node)
  node:serve("keyserver", function(from, method, a)
    local r = store()
    if method == "put" then
      if type(a) ~= "table" or type(a.text) ~= "string" or #a.text > 40000 then error("expected a key block", 0) end
      if #r:keys() >= M.MAX_KEYS then error("the key server is full", 0) end
      local key, status = r:add(a.text)
      if not key then error(tostring(status), 0) end
      return { fingerprint = pgp.fingerprint(key), uid = key.uid, status = status }
    elseif method == "get" then
      local key, err = r:find(type(a) == "table" and a.query or "")
      if not key then error(tostring(err), 0) end
      return { text = pgp.exportPublic(key) }
    elseif method == "search" then
      local q = (type(a) == "table" and a.query or ""):lower()
      local out = {}
      for _, k in ipairs(r:keys()) do
        if q == "" or k.uid:lower():find(q, 1, true) or pgp.fpHex(k):find(q:gsub("%s", ""), 1, true) then
          out[#out + 1] = { uid = k.uid, fingerprint = pgp.fingerprint(k), revoked = k.revoked }
          if #out >= 30 then break end
        end
      end
      return out
    end
    error("unknown method " .. tostring(method), 0)
  end)
end

function M.daemon()
  M.serve(require("tsr.net").default())
  while true do os.pullEvent("keyserver_never") end
end

--- Publish `key` to the computer `peer`. Returns the server's answer or nil + error.
function M.send(node, peer, key)
  return node:call(peer, "keyserver", "put", { text = pgp.exportPublic(key) }, { timeout = 10 })
end

--- Fetch a key by fingerprint or identity from `peer` and add it to `keyring`. Returns key, status or nil + error.
function M.receive(node, peer, query, keyring)
  local res, err = node:call(peer, "keyserver", "get", { query = query }, { timeout = 10 })
  if not res then return nil, err end
  return keyring:add(res.text)
end

function M.search(node, peer, query)
  return node:call(peer, "keyserver", "search", { query = query }, { timeout = 10 })
end

return M
