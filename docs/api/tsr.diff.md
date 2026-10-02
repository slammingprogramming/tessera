# tsr.diff

Package: `diff`

Line-based differences between texts and patches in the unified format that diff -u, git and patch use.
  diff.edit(aKeys, bKeys)            -> ops { {op = "=" | "-" | "+", i = line in a, j = line in b} }   (Myers' O(ND) algorithm)
  diff.unified(a, b, opts)           -> text of a unified diff, or "" when equal   opts: nameA, nameB, context (3)
  diff.parse(patchText)              -> { { old = name, new = name, hunks = { { oldStart, oldLen, newStart, newLen, lines } } } }
  diff.apply(text, hunks, opts)      -> new text, or nil + reason      opts: reverse, maxOffset (how far a hunk may have moved, 200)
A last line without a final newline is kept apart ("\ No newline at end of file"), exactly as the real tools do.

## `M.split(text)`

Split text into lines. Returns lines, keys (what is compared: a last line without newline gets a marker), noeol (true when
the text does not end with a newline).

## `M.parse(text)`

Read a patch (one file or many).

## `M.apply(text, hunks, opts)`

Apply hunks to `text`. Every hunk's old lines (context and removed) must be found, at the stated place or within maxOffset
lines of it (patch's "offset"); nothing is changed otherwise. Returns text, report { hunks = n, offsets = { ... } }.
