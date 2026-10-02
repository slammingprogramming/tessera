# tsr.gui.desktop

Package: `ui-gui`

The Tessera desktop: window area, taskbar (start button, one button per window, clock) and the start menu.
Applications are described by files in /usr/share/applications/*.lua, each returning
  { name = "Files", category = "Accessories", order = 10, w = 44, h = 15,
    build = function(root, win, desktop) ... end }          -- a widget app
  { name = "Terminal", run = function(win, desktop) ... end }  -- a process app (window terminal = win.term)
  { name = "Editor", program = "edit" }                        -- run a command line in a shell inside a window

## `M.new(opts)`

opts: term, kernel, apps (replaces the files in APP_DIR), now (function -> "HH:MM"), onExit

## `Desktop:launch(app)`

Open an application (a table as described above). Returns the window.

## `Desktop:launchByName(name)`

Launch an application by id or name.

## `Desktop:event(name, a, b, c)`

Handle one event. Returns true when the screen needs attention (the loop recomposes on its own anyway).

## `Desktop:run()`

Run until the user leaves. Returns "shell" | "logout" | "reboot" | "shutdown".

## `M.start(opts)`

Start the desktop on the current terminal with the configured theme. Returns the exit action.
