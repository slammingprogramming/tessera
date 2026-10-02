# tsr.media

Package: `media`

Media playback.
  .bimg   pictures and videos in "blit image" format (sanjuuni's default output; several frames = an animation)
  .nfp    pictures from the paint program
  .dfpwm  audio for speakers (a video's sound is the .dfpwm file next to it with the same name)
  (32vid, sanjuuni's compressed video container, is not supported yet: convert with `sanjuuni --bimg`.)
  play <file> [--monitor name] [--loop]     play list [folder]

## `M.kind(path)`

"video" (BIMG), "picture" (NFP) or "audio" (DFPWM) from the file name, or nil.

## `M.library(dir)`

Files in `dir` that can be played: { name, path, kind, size }, sorted by name.

## `M.playVideo(path, t, opts)`

Show a picture or play a BIMG animation on terminal `t`. opts: loop, interruptible (default true), pull (event source, tests),
stop (function -> true to stop early), center (default true), duration (seconds; ends the show, "done"), once (draw and return).
Returns "done" or "stopped".

## `M.playAudio(path, speakers, opts)`

Play a .dfpwm file on the given speakers (all play the same stream). opts: volume (0-3, default 1), stop, decoder (tests),
pull. Returns "done" or "stopped".

## `M.play(path, opts)`

Play whatever `path` is. opts: term, speakers (array), loop, volume, pull. A video is accompanied by the .dfpwm file with the same
name if one exists. Returns "done" / "stopped", or nil + reason.

## `M.run(args, io, env)`

play <file> [--monitor name] [--loop] [--volume n] | play list [folder]
