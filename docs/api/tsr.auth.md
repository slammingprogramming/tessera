# tsr.auth

Package: `auth`

Users, passwords, roles and soft file permissions.

HONEST LIMITS: a ComputerCraft computer is one Lua VM that anyone with a keyboard controls; any program can restore the
original `fs` functions or read the disk through a disk drive. These checks keep honest users from making mistakes and
keep other players from casually wandering around a shared computer. They are not a security boundary against someone
who can run arbitrary code or break the computer.

Processes that were not started from a login session (daemons, boot scripts) are the "system": nothing is checked for them.

## `M.reset()`

Forget in-memory state (tests, and after the database file changed on disk).

## `M.get(name)`

Public view of a user (never includes the password hash).

## `M.addUser(name, password, opts)`

Create a user. opts: role ("admin" | "user" | "guest", default "user"), home (default /home/<name>).

## `M.verify(name, password)`

Check a password. Returns the user (public view), or nil + reason. Counts failures so callers can slow down.

## `M.setSessionUser(name, pid)`

Make `name` the user of process `pid` (default: the running one) and everything it starts.

## `M.userOf(pid)`

The user a process runs as: its own session, else its nearest ancestor's, else nil (system).

## `M.asUser(name, fn, ...)`

Run fn as another user (nil = system) and restore afterwards.

## `M.pathAllowed(name, path, mode)`

May `name` read ("r") or write ("w") `path`? Rules for non-administrators:
 * the user database is off limits, other users' home directories are private,
 * writes go to the user's own home and /tmp only (guests: /tmp only).
