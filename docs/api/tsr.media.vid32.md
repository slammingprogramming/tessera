# tsr.media.vid32

Package: `media`

32vid video files (the compressed video + audio container written by sanjuuni), decoded in pure Lua.

Format summary (see sanjuuni's README, "32vid file format"):
  header   "32VD"  u16 width  u16 height  u8 fps  u8 streams  u16 flags     (little endian)
  flags    bits 0-1 video compression: 0 none, 1 ANS, 2 DEFLATE, 3 custom (Huffman); bits 2-3 audio: 0 8-bit PCM, 1 DFPWM; bit 4: 5-bit
           symbols (always set by current encoders); bits 5-11: multi-monitor layout
  streams  u32 size  u32 count  u8 type, then the data: type 0 video, 1 audio (mono), 8 subtitles, 12 COMBINED audio+video+subtitle
           frames (u32 size, u8 type, data) which is what current sanjuuni writes, 13 index (ignored), 64..127 multi-monitor video (skipped)
  a video frame: the characters (5 bits each: the teletext character 128 + code), then the foreground and background colour of every cell
           (4 bits each), then the 16-colour palette (16 x 3 bytes). Compression differs per mode, see the decoders below.
This decoder follows that description and was checked against sanjuuni's own Lua reference (lib32vid.lua, MIT licence, Copyright (c) 2025
JackMacWindows) on files made by an independent encoder; see tests/media/vid32_test.lua.

  local v = vid32.open("/disk/show.32v")            or  vid32.fromString(data)  /  vid32.fromHandle(handle)
  v.width, v.height, v.fps
  while true do
    local kind, data = v:next()          -- "video": { palette = { [0..15] = {r, g, b} }, [1..height] = { text, fg, bg } }
    if not kind then break end            -- "audio": list of samples -128..127   "subtitle": { frame, length, x, y, text, color }
  end

## `Video:decodeAudio(data)`

Decode audio bytes into samples (8-bit PCM -128..127 or DFPWM through cc.audio.dfpwm).

## `Video:audioChunks()`

Audio of a file with separate streams, as a list of chunks of samples (about half a second each); nil for combined files (their audio comes from next()).

## `Video:next()`

The next item of the file: "video", frame | "audio", samples | "subtitle", event; nil at the end. A frame carries .subtitles (the ones to show with it).

## `M.open(path)`

Open a 32vid file on disk (or a disk drive). Returns a reader or nil + reason.

## `M.fromHandle(h)`

A reader over an open binary handle (a file, or http.get(url, nil, true) for streaming).

## `M.fromString(data)`

A reader over the bytes of a whole file.
