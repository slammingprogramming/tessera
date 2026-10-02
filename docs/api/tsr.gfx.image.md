# tsr.gfx.image

Package: `gfx`

Image formats.
  NFP   the paint program's format: one character per pixel, hex digits for the 16 colours, space = transparent
  BIMG  "blit image": a Lua table of frames; each frame is rows of { text, foreground, background } (blit strings), with an
        optional palette and animation settings. Several programs and sanjuuni produce it.
image.parse(text, kind?) / image.load(path) return an image with:
  img.kind, img.width, img.height (characters for BIMG, pixels for NFP), img.frames (BIMG)
  img:draw(t, x, y, frame)      draw on a terminal;  NFP images are rendered through a canvas (2 x 3 pixels per character)
  img:toCanvas()                NFP only

## `M.parseNfp(text)`

Parse NFP text. Returns an image, or nil + reason.

## `M.toNfp(canvas)`

Encode a canvas (or any object with w, h and get(x, y)) as NFP text.

## `M.parseBimg(text)`

Parse a BIMG document (the text of the serialized table). Returns an image, or nil + reason.

## `M.toBimg(frames, opts)`

Serialize frames (an array of frames, each an array of { text, fg, bg }) as a BIMG document.

## `M.parse(text, kind)`

Parse text of either format. `kind` forces one ("nfp" or "bimg"); otherwise a leading "{" means BIMG.

## `Image:draw(t, x, y, frame)`

Draw frame `frame` (BIMG, default 1) or the whole picture (NFP) with its top-left character at (x, y).

## `Image:charSize()`

Size in characters.
