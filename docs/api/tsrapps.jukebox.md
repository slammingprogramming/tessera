# tsrapps.jukebox

Package: `audio`

jukebox: a music player for speakers.
  jukebox [path|url ...] [--volume 0-3] [--loop] [--shuffle] [--once]
Plays .dfpwm files (CC:T's audio format; convert other music at music.madefor.cc or with sanjuuni's tools). A folder
is played as a playlist; with no argument /music is used. Every attached speaker plays at once.
Keys:  n next   p previous   space pause   + / - volume   l loop   s shuffle   q quit

## `M.playlist(items)`

Expand files, folders and URLs into an ordered list of sources.

## `M.title(src)`

A short title for a source.

## `M.load(src, env)`

Load the bytes of a source (file or URL). Returns data or nil + reason.

## `M.playTrack(speakers, data, state, env)`

Play one track. Returns "done", "next", "prev" or "quit".

## `M.play(list, speakers, state, io, env)`

Play a playlist. state: { volume, loop, shuffle, queue = {} }. Returns the number of tracks played.

## `M.keyLoop(state, env)`

Key reader: translates keypresses into commands for the player.
