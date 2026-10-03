# tsr.inet.dissect

Package: `inet`

Reading captured frames: parse a frame into a table (parse), one line of text for tcpdump (describe), and capture filters
("host 10.0.0.2 and not port 22", "tcp", "arp", "icmp or udp") compiled into functions (filter).
Other packages add decoders for their protocols: dissect.udp[port] = function(info, payload) -> text.

## `M.parse(frame)`

Parse a frame. Returns a table: eth, kind ("arp" | "ip" | "other"), plus for ip: ip, proto, src, dst, sport, dport, tcp/udp/icmp details.

## `M.describe(info)`

One line of text for a parsed frame.

## `M.filter(words)`

Compile a filter given as a list of words, e.g. { "host", "10.0.0.2", "and", "port", "80" }. Returns a function(info) -> bool, or nil + reason.
Words: tcp udp icmp arp ip | host A | src A | dst A | net CIDR | port N | vlan N | not, and, or | ( ) is not supported (keep it simple).
