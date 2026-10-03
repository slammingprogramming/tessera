# tsr.mail.config

Package: `mail`

Settings of the mail server. Two places:
  /etc/tsr/mail/mail.lua   written by hand (a Lua table): host name, TLS, limits, anti-spam, anti-virus. `mailctl init` writes a commented template.
  /etc/tsr/mail/routing.db changed by `mailctl`: the domains, relay networks, aliases and the allow/deny lists. The server reads it again when it changes.
Both are merged into one table by load().

## `M.load()`

The settings the server runs with: the file plus the routing data.

## `M.liveRouting()`

The part that the server re-reads while it runs (no restart needed).
