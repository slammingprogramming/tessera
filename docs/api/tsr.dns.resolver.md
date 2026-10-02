# tsr.dns.resolver

Package: `dns`

Turning names into computers. net's own lookup asks everybody within modem range "who is called X?"; the name service adds names that
work anywhere you can reach a name server, aliases and a hosts file. Lookup order for a name:
  1. /etc/hosts          "<id> name [alias...]" lines, always trusted, no network
  2. the cache           answers remembered for their time to live
  3. the name servers    /etc/tsr/dns.cfg { servers = { 3, "ns1" }, search = { "base" }, timeout = 2 }
A name without a dot is also tried with each search suffix ("farm1" -> "farm1.base"). tsr.net calls `lookup` automatically when this
package is installed, so every command that takes a computer (ssh, ntpdate, torrent get ...) accepts names from the zone.

## `M.hosts()`

The hosts file as { [name] = id }.

## `M.query(node, name, rtype, opts)`

Resolve `name` to records of `rtype` (default "A"), following aliases. Returns answers (possibly empty, with .server and .cached set) or nil + reason.
