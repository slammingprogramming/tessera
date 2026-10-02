# tsr.power

Package: `core`

Power management: shutdown/reboot hooks, so services can flush state before the computer stops even when a program
calls os.shutdown()/os.reboot() directly (e.g. the stock `shutdown` command).

## `M.onPower(fn)`

Register fn(action) to run before power-off/reboot; action is "shutdown" or "reboot".

## `M.install()`

Route os.shutdown / os.reboot through the hooks. Idempotent.
