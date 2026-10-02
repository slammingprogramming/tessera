# tsr.p2p.store

Package: `p2p`

Where torrent data lives.
  Seed:      reads pieces out of the finished file or folder (verified against the piece hashes before they are served).
  Download:  keeps every verified piece in its own small file under <dir>/.tsrt-<infohash prefix>/ so an interrupted download resumes,
             then assembles the finished file or folder piece by piece (deleting each piece as it is copied, so the disk never has to
             hold the data twice) and removes the work folder.

## `M.seed(m, base)`

A reader for the content of `m` stored at `base` (the file itself, or the folder for multi-file torrents).
Returns { read(i) -> data | nil, verify(i) -> bool, bitfield() -> string of 0/1 }.

## `M.download(m, dest)`

Storage for downloading `m` into the folder `dest`. Resumes from pieces already in the work folder (each one re-verified).
