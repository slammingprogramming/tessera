# tsrapps.access

Package: `access-control`

access: keycard doors. A keycard is a floppy disk carrying a small file signed with the door's secret (HMAC-SHA256),
so cards cannot be forged or edited without the secret. Cards have a name, a level, and can be revoked.
  access setup [--key <secret>]     redstone output, open time, minimum level (a new secret is generated unless given)
  access issue <name> [level]       write a card to the disk in the drive
  access revoke <name|id> | unrevoke | list | key | log
  access run                        wait for cards and open the door
Piston doors: use `invert` in setup when the door is CLOSED by power (pistons extended = wall) or `toggle` mode.

## `M.makeCard(secret, name, level, env)`

Make a card table (not yet on a disk).

## `M.verify(cfg, card)`

Check a card read from a disk. Returns true, card  or  false, reason.

## `M.operate(cfg, env)`

Operate the door output. pulse: open for open_secs; toggle: flip. invert flips what "open" means.

## `M.handleCard(cfg, side, env)`

A card was inserted on `side`. Returns true if the door opened, or false + reason.
