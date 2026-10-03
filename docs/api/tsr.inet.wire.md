# tsr.inet.wire

Package: `inet`

Packet formats as they appear on the wire: Ethernet II with 802.1Q tags, ARP (RFC 826), IPv4 (RFC 791), ICMP (RFC 792), UDP (RFC 768) and
TCP (RFC 9293) headers. Every function turns a byte string into a table or back, and verifies what the RFCs say to verify
(lengths, checksums). Nothing here keeps state.

## `M.ethEncode(f)`

{ dst, src, type, payload, vlan (nil for untagged), pcp }. Frame = dst(6) src(6) [8100 TCI] type payload.

## `M.ipEncode(p)`

p: src, dst, proto, payload, ttl (64), tos (0), id, df (bool), mf (bool), frag (offset in 8-byte units), options (raw string, padded to 4).

## `M.ipDecode(data)`

Parse and validate an IPv4 packet. Returns a table (see ipEncode, plus len, ihl, header) or nil + reason.

## `M.pseudo(src, dst, proto, len)`

The pseudo header that TCP and UDP checksums cover (RFC 793/768).

## `M.icmpEncode(m)`

m: type, code, rest (the 4 "rest of header" bytes as a string, default zeros), data.

## `M.tcpEncode(src, dst, s)`

s: sport, dport, seq, ack, flags (number), window, mss (option on SYN), payload.
