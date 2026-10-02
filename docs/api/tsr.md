# tsr

Package: `core`

init: builds the running system. Starts daemons from /etc/tsr/init.d/*.lua (sorted, each as a windowless process),
then the interactive session, then hands control to the kernel loop until the system stops.

## `M.startDaemons()`

Start every daemon script in /etc/tsr/init.d.

## `M.startShellSession(parentShell)`

The default interactive session: tsh when installed, otherwise the stock CraftOS shell, as a Tessera process.

## `M.run(opts)`

opts: parentShell (the CraftOS shell API of the startup context), onReady (called right before the loop starts)
Returns the kernel's exit action ("craftos", "shutdown" or "reboot").
