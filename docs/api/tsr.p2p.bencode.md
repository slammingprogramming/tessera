# tsr.p2p.bencode

Package: `p2p`

Bencode, the encoding of BitTorrent metadata: integers  i42e,  strings  4:spam,  lists  l...e,  dictionaries  d...e  (keys sorted).
Dictionary keys are sorted, so encoding is canonical: the same data always gives the same bytes, which is what makes an
info hash well defined. In Lua a table with keys 1..n is a list, any other table (also an empty one) is a dictionary.

## `M.encode(v)`

Encode a value (number, string, boolean, list or dictionary) to a string.

## `M.decode(s)`

Decode a complete bencoded string. Returns the value or nil + reason.
