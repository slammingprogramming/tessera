# tsr.ssh.server

Package: `ssh`

sshd: the in-game secure shell server. It answers handshakes on the net node (see tsr.ssh.chan), authenticates users and then
serves requests inside the encrypted channel: run a command, browse and copy files, register a key.

Who gets in:  a user must exist (tsr.auth; on a computer without users the single account is "root") and prove it with a key
              listed in ~/.ssh/authorized_keys (/etc/tsr/ssh/authorized_keys without users), or with the account password when
              /etc/tsr/sshd.cfg says password = true (off by default). What they can touch is limited by the same soft file
              permissions as a console login.
Abuse limits:  handshakes cost real CPU on a game computer, so each peer may start one every few seconds, the number of open
              sessions is capped, wrong credentials end the session and get slower, idle sessions expire.

## `M.config()`

Settings with defaults: { password = false, allowUsers = nil (everyone who has a key), maxAuthTries = 3 }.

## `ops.authorize(s, a)`

ssh-copy-id: append a public key line to this user's authorized_keys.

## `M.reset()`

Forget everything (tests).

## `M.handle(node, from, msg)`

Handle one network message (installed as the node's "ssh" handler).

## `M.attach(node)`

Start answering on `node`.

## `M.daemon()`

The sshd service: attach to the default node and idle (the netd daemon dispatches the messages).
