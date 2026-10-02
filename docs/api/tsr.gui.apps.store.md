# tsr.gui.apps.store

Package: `ui-gui`

App store: browse the package registry, install, remove and update, with the package manager doing the work.

## `M.rows(pkg, filter)`

Rows for the list: { name, version, type, description, installed, tags }, sorted by name; `filter` matches name/description/tags.

## `M.build(root, win, desktop, opts)`

opts: pkg (the tsr.pkg module, for tests), progress(text) hook
