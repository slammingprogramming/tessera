# tsr.gfx.font

Package: `gfx`

A 3x5 pixel font. Each glyph is 15 characters, row by row, "1" = pixel set. Lower-case letters use the capital shapes.

## `M.glyph(ch)`

Rows of a character: three booleans per row, five rows. Unknown characters are drawn as a hollow box.
