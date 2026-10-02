# tsr.archive.deflate

Package: `archive`

DEFLATE compression (RFC 1951): LZ77 matching with a hash of the next three bytes (window 32 KB, lazy matching) and the fixed
Huffman codes. The output is a valid raw DEFLATE stream that zlib, gzip, Node and tsr.inflate all read; it does not reach the ratio of a
tuned compressor with dynamic Huffman tables (expect roughly 40-60% of the original size for text and Lua), but it is small and quick
enough for a ComputerCraft computer. Incompressible data falls back to stored blocks, so the output is never much larger than the input.

## `M.deflate(data, level)`

Compress `data` to a raw DEFLATE stream. level 0 stores without compression.

## `M.gzip(data, opts)`

gzip file bytes for `data` (RFC 1952). opts: name (stored in the header), mtime (seconds), level.

## `M.gunzip(bytes)`

Unpack gzip bytes. Returns data, name or nil + reason (the CRC and size are checked).
