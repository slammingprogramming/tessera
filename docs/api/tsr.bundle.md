# tsr.bundle

Package: `core`

Offline bundles: a registry snapshot and/or package payloads packed into one container so a computer with NO
network access can still install Tessera and apps. A bundle reaches the computer in one of two ways:
  * as a file dropped onto the terminal (file_transfer event) or read from a disk  -> "TSRZ" + raw DEFLATE stream
  * as numbered text lines pasted at a prompt                                       -> "TSR1 <id> <n>/<total> <crc32> <base64>"
Container (before compression):  "TSRB" u8 version(1) u16 count, then per entry:
  u8 kind (1=index json, 2=package doc json, 3=blob, 4=signature file of the index)  u8 nameLen  name  u32 dataLen  data
Index and package entries hold the registry files byte for byte, so their signatures and hashes stay valid.
Blob entries are named by the SHA-256 of their content and verified on load.

## `M.parseContainer(s)`

Parse an (already decompressed) container. Returns { index = table|nil, indexRaw, indexSig, packages = {name=doc}, packageRaw = {name=text}, blobs = {sha=data} }.

## `M.parse(data)`

Parse bundle bytes as delivered by a file drop or disk: "TSRZ" + raw deflate, or a text file of TSR1 lines.

## `Assembler:add(line)`

Feed one pasted line. Returns status, detail:
  "ok", seq        accepted        "dup", seq   already had it       "bad", reason   rejected (re-paste it)
  "ignored"        not a chunk line (blank, prompt noise)

## `Assembler:result()`

Decode a completed assembly into the container table (verifies the bundle id and every blob hash).
