# tsr.pgp.armor

Package: `pgp`

Binary records and ASCII armor for the PGP-style tool (tsr.pgp).
A binary blob is a sequence of records:  u8 type, u32 length, data.  Armor wraps a blob in base64 between BEGIN/END lines with a
CRC-32 check line, so keys, signatures and encrypted messages can be pasted into a terminal, a chat or a book.

## `M.reader(s)`

A reader over a binary string: r:u8(), r:u16(), r:u32(), r:u64(), r:bytes(n), r:rest(), r:eof().

## `M.records(list)`

Concatenate records: list of { type, data }.

## `M.parse(bin)`

Split a blob into records. Returns a list of { type, data } or nil + reason.

## `M.armor(kind, bin)`

Text form of a blob: kind is e.g. "PUBLIC KEY", "SIGNATURE", "MESSAGE".

## `M.dearmor(text, wanted)`

Find the first armored block in `text` (optionally of one `kind`). Returns kind, blob, rest-of-text or nil + reason.
