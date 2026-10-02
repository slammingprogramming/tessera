# tsr.p2p.tracker

Package: `p2p`

A tracker for the in-game swarm: a computer that remembers which computers announced which torrent, so that peers far apart (outside
each other's modem range, but both able to reach the tracker) can find each other. It stores only computer ids and counts, never data.
Limits keep it small: a fixed number of torrents and peers per torrent, entries expire after 30 minutes without an announcement.

## `M.attach(swarm, opts)`

Attach tracker behaviour to a swarm (tsr.p2p.swarm). opts: clock (function -> seconds).

## `M.summary(tracker)`

A summary for `torrent tracker`: { swarms = n, peers = n }.
