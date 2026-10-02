-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Package source type "p2p": payloads (blobs/<sha256>) from neighbouring computers that have them, see tsr.p2p.blobs. Package
-- descriptions and the signed index still come from a registry source (http, a mirror, an offline bundle): this source only supplies
-- file contents, which are verified against the hashes in those descriptions.
--   config:  pkg.sources = { ..., { name = "swarm", type = "p2p" } }      (add it AFTER the sources that carry the index)
local source = require("tsr.pkg.source")

source.fetchers.p2p = {
  read = function(src, rel)
    local sha = tostring(rel):match("^blobs/(%x+)$")
    if not sha then return nil, "the p2p source serves file contents only" end
    local okNet, net = pcall(require, "tsr.net")
    if not okNet then return nil, "the net package is not installed" end
    local swarm = require("tsr.p2p.swarm").forNode(src.node or net.default())
    return swarm:fetchBlob(sha, { wait = src.wait })
  end,
}

return source.fetchers.p2p
