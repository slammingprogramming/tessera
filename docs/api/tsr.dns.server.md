# tsr.dns.server

Package: `dns`

The name server: answers "dns.q" questions from the zone files in /etc/tsr/zones/*.zone and from names that computers registered by
themselves. Registration goes through the authenticated service "dns" (see tsr.net pairing), so only computers paired with the server
can claim names, and a computer can only register for itself (its own id) and only in the zones the config allows:
  /etc/tsr/dns.cfg  { serve = true, dynamic = { "base" }, register = { server = "ns1", name = "farm1.base" }, ttl = 600 }
Dynamic records expire after their time to live unless renewed; zone-file records are static. Answers are not signed: like classic DNS
this is a convenience for a friendly network, not a defence against a hostile one (use `ssh` host key checks for that).

## `M.new(opts)`

The server's database: static records from the zone files plus live dynamic ones.

## `M.serve(node, db, cfg)`

Serve on a net node: questions from anybody (plain messages), registrations from paired computers. Returns the database.

## `M.daemon()`

The dnsd service: serve when configured, and keep this computer's own name registered at a name server.
