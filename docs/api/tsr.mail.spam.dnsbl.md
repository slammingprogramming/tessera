# tsr.mail.spam.dnsbl

Package: `mail-spam`

Blocklists in DNS (DNSBL, RFC 5782): a list server answers A queries for "<reversed ip>.<zone>"; any answer in 127.0.0.0/8 means "listed". Players who run a
DNS server can run such a list (a zone with entries like 5.0.0.10.bl.example.lan A 127.0.0.2); mail servers name the lists they trust, with a score each.
  dnsbl.check(mail, "10.0.0.5", { { zone = "bl.example.lan", score = 4 } })  ->  { { zone, score, code } ... }

## `M.check(mail, ip, zones)`

Lists that contain the address. Lookup problems count as "not listed".

## `M.checkDomain(mail, domain, zones)`

Lists of domains (URIBL style): the domain itself is the query prefix.
