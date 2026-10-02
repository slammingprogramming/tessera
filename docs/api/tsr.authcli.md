# tsr.authcli

Package: `auth`

Command-line front ends for the auth package: useradd, userdel, usermod, passwd, users, whoami, su, sudo, lock.
Each function is (args, io) -> boolean; io has say, err and secret so tests can script it.

## `M.sudo(args, io, run)`

`sudo <command...>` runs the command unrestricted after the current administrator retypes their password.

## `M.su(args, io, run)`

`su <user>`: a new shell as that user after their password.
