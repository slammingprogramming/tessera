# tsr.mobile.shell

Package: `mobile`

Phone-style shell for pocket computers (about 26 x 20 characters).
  row 1        status bar: clock, network, notification count
  rows 2..h-1  the current screen (a widget tree)
  row h        navigation: [<] back   [o] home   [=] notifications
Apps are files in /usr/share/mobile/*.lua returning { name, icon (one character), build = function(root, phone) ... end }.
A screen pushed with phone:push(title, build) gets the content area; `phone:pop()` goes back, `phone:home()` clears the stack.

## `M.new(opts)`

opts: term, apps (replaces APP_DIR), notify (module, default tsr.notify), now (function -> "HH:MM"), signal (function -> bool)

## `Phone:push(title, build)`

Open a screen on top of the current one. build(root, phone) fills the content area.

## `Phone:buildHome(root)`

App tiles, two per row, paged when there are more than fit.

## `Phone:event(name, a, b, c)`

Handle one event. Mouse coordinates on the content area are shifted up by the status bar.

## `M.start(opts)`

Start the phone interface on the current terminal. Returns "shell" | "reboot" | "shutdown".
