# tsr.inflate

Package: `core`

Raw DEFLATE (RFC 1951) decoder, structured after zlib's "puff". Used to unpack offline bundles that were compressed
by tools/build (Node zlib) or by the browser bundle builder (CompressionStream "deflate-raw").

## `M.inflate(src, start)`

Decompress raw DEFLATE data in `src` starting at byte `start` (default 1).
Returns the decompressed string and the position just after the compressed stream. Raises on corrupt input.
