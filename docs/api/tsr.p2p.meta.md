# tsr.p2p.meta

Package: `p2p`

Torrent metadata ("metainfo", .tsrt files) for the in-game swarm, modelled on BitTorrent v2's choices: the content is cut into
pieces, each piece is identified by its SHA-256, and the whole torrent by the info hash = SHA-256 of the bencoded `info` dictionary.

  info = { name, ["piece length"], pieces (32 bytes per piece, concatenated), length (one file) | files = { { length, path = {...} } } }
  file = { info = ..., announce = trackerHost (optional), comment, ["creation date"] }

A magnet link carries only the info hash (and a name and tracker hints):  magnet:?xt=urn:btmh:1220<hex>&dn=<name>&tr=<tracker>
The 1220 prefix is the multihash code of SHA-256. The info dictionary itself is then fetched from the swarm (see tsr.p2p.swarm).

## `M.create(path, opts)`

Hash the content of `path` (a file or a directory) into a metainfo. opts: pieceLength, name, tracker, comment, created (seconds).
Returns meta = { info, infoRaw, infohash (hex), announce, comment, created }.

## `M.encode(meta)`

The bencoded .tsrt file for a metainfo.

## `M.parse(data)`

Metainfo from the bytes of a .tsrt file. Returns meta or nil + reason.

## `M.fromInfo(info, doc)`

Metainfo from a decoded info dictionary (and optionally the surrounding document). Returns meta or nil + reason.

## `M.fromInfoRaw(raw, expectedHash)`

Metainfo from an info dictionary received over the network; it must hash to the expected info hash.

## `M.pieceHash(meta, i)`

Hash (raw 32 bytes) of piece i (1-based).

## `M.pieceLength(meta, i)`

Length in bytes of piece i (the last one may be short).

## `M.files(meta)`

List of { path (list of parts), length, offset } in torrent order (a single file has one entry).

## `M.parseMagnet(uri)`

Parse a magnet link. Returns { infohash, name, trackers } or nil + reason.
