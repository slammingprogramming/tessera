# tsr.p2p.cli

Package: `p2p`

The torrent command: share and fetch files between the computers of one game world, BitTorrent-style (never the real Internet).
  torrent create <file|folder> [--name N] [--piece 16384] [--tracker host] [-o file.tsrt]    hash content into a torrent file
  torrent info <file.tsrt | magnet:...>                                                    what is in it
  torrent seed <file.tsrt> <path>                                                          offer content (also kept for the daemon)
  torrent get <file.tsrt | magnet:...> [-d folder] [--tracker host]                         download and then keep seeding
  torrent list | unseed <infohash prefix> | tracker on|off | packages on|off | status
The daemon (service torrentd) seeds what `torrent seed` registered, and runs a tracker or shares package files if you turn those on.

## `M.config()`

The configuration: { seeds = { { meta = path, path = path } }, tracker = bool, packages = bool, uploadRate = bytes/s }.

## `M.daemon()`

The torrentd service: serve the registered seeds, the tracker role and package payloads as configured.
