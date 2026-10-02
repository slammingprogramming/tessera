# tsr.p2p.swarm

Package: `p2p`

The in-game swarm: computers that have a torrent's content hand pieces to computers that want it, BitTorrent-style, over the
network of the game world (modems / rednet, via a tsr.net node). Nothing here reaches the real Internet.

  Finding peers:  a broadcast "who has <info hash>?" reaches every computer in modem range; optionally a TRACKER (a computer running
                  the tracker role) remembers who announced which torrent, so far-away computers find each other too.
  Transfer:       the content is cut into pieces named by their SHA-256 (see tsr.p2p.meta). A downloader asks different peers for
                  different pieces in parallel (rarest piece first), checks every piece against its hash and drops peers that send
                  bad ones. Interrupted downloads resume. Finished downloads are seeded automatically.
  Politeness:     modems are slow and shared. A seeder caps its total upload rate (default 48 KB/s), serves a limited number of
                  computers at once and says "busy" instead of queueing; downloaders back off. Messages stay below ~24 KB.
  Blobs:          the same machinery serves single content-addressed blobs (a package payload named by its SHA-256) to the package
                  manager's `p2p` source, see tsr.p2p.blobs.
Messages are plain tables { t = "p2p", k = <kind>, ... } carried by the node; integrity comes from the hashes, not from the network,
so a hostile peer can waste time but cannot make anybody accept wrong data.

## `M.forNode(node, opts)`

The swarm of a node: one per node, shared by everything in the system that wants to use it (the node has a single message handler).

## `M.new(node, opts)`

Create the swarm part of a net node. opts: uploadRate, maxRequesters, clock (function -> seconds), blobLookup (function(sha) -> path|nil).

## `Swarm:addSeed(m, base)`

Offer the finished content of `m` found at `base` (file, or folder for multi-file torrents).

## `Swarm:handle(from, msg)`

Handle one incoming message (the node's "p2p" handler).

## `Swarm:announce(tracker, infohash, event, left)`

Tell a tracker about a torrent and get its peers. event: "started", "completed", "stopped" or nil. Returns { ids..., seeders, leechers } or nil + reason.

## `Swarm:discover(infohash, trackers, wait)`

Who has `infohash`? Broadcasts and asks the trackers. Returns { [computer id] = { have = "1010..." } }.

## `Swarm:fetchMeta(infohash, trackers)`

Fetch the metadata of a torrent known only by its info hash (from a magnet link). Returns meta or nil + reason.

## `Swarm:download(m, dest, opts)`

Download `m` into the folder `dest`. opts: trackers (list), maxWorkers (default 4), stall (give up after this many seconds without
progress, default 40), onProgress(owned, count), keepSeeding (default true).
Returns the path of the finished file or folder, or nil + reason.

## `Swarm:fetchBlob(sha, opts)`

Fetch the content-addressed blob `sha` (hex SHA-256) from whichever computers have it. Returns the data or nil + reason.
