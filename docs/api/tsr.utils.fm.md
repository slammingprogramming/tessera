# tsr.utils.fm

Package: `utils`

fm: a file manager for any screen, built on the text UI toolkit (keyboard first, mouse where available).
  Enter opens a folder or shows the actions for a file.  Backspace goes up a folder, or leaves at the top.

## `M.entries(path)`

Folder listing: directories first, each group alphabetical.

## `M.copy(from, to)`

Copy a file or a whole folder. Returns true or nil + reason.

## `M.info(path)`

Text for the info screen.

## `M.run(opts)`

opts: path (start), ui (the tui module, for tests), run(line) (execute a command line), edit(path)
