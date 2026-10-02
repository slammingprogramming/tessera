# tsr.gui.apps.files

Package: `ui-gui`

File manager: browse folders, open files, make folders, rename and delete.

## `M.entries(path)`

Entries of a folder: directories first, then files, each alphabetical. Returns { {name, dir, size, path, readonly} ... }.

## `M.label(e)`

The label shown in the list.

## `M.build(root, win, desktop, opts)`

Build the file manager on `root`. opts: path (start folder), open(path) (what to do with a file; default: edit it).
