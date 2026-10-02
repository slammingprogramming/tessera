# tsr.gfx

Package: `gfx`

Sub-pixel canvas. Every terminal character is 2 x 3 pixels (the "teletext" characters 128-159), so an 51 x 19 screen is a
102 x 57 pixel canvas. Pixels hold CraftOS colours (powers of two); nil is transparent.

  local gfx = require("tsr.gfx")
  local c = gfx.new(26, 10)                 -- 26 x 10 characters = 52 x 30 pixels
  c:line(0, 0, 51, 29, colors.red)
  c:rect(5, 5, 20, 10, colors.blue, true)
  c:text(2, 2, "HI", colors.white, 2)       -- the 3x5 font at scale 2
  c:flush(term.current(), 1, 1)

A character can show only two colours. Where a cell holds more, the two most common win (the bottom-right pixel's colour
is always the background, as the teletext characters require).

## `M.new(cols, rows)`

A canvas of `cols` x `rows` characters.

## `Canvas:set(x, y, color)`

Pixel coordinates are 0-based from the top-left corner.

## `Canvas:line(x1, y1, x2, y2, color)`

Bresenham line.

## `Canvas:circle(cx, cy, r, color, fill)`

Midpoint circle; with fill the disc is drawn.

## `Canvas:blit(other, x, y)`

Copy another canvas onto this one at (x, y); nil pixels of the source are transparent.

## `M.textWidth(str, scale)`

Pixel width of `str` at `scale` (glyphs are 3 wide with 1 pixel between them).

## `Canvas:text(x, y, str, color, scale)`

Draw text with the 3x5 font, each font pixel becoming a scale x scale block.

## `Canvas:rowBlit(row, background)`

The text, foreground and background strings for one row of characters (1-based row). Transparent pixels render as
`background` (default black).

## `Canvas:flush(t, ox, oy, background)`

Draw onto a terminal (or window/monitor) with the canvas' top-left character at (ox, oy).

## `Canvas:toBimg(background)`

The canvas as a BIMG frame (rows of { text, fg, bg }), ready to save.

## `M.bigText(t, x, y, str, fg, bg, scale)`

Draw `str` in big letters on terminal `t` with its top-left corner at character cell (x, y). scale 1 = 3x5 pixels per letter,
which is about 2 x 2 characters. Returns the width and height used, in characters.
