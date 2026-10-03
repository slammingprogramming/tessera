# tsr.inet.dns.wire

Package: `inet-dns`

DNS messages (RFC 1035): header, questions, resource records, and name compression. Supported record types: A, NS, CNAME, SOA, PTR, MX, TXT, SRV.
Names are lower-case dotted strings without the final dot ("mail.example.lan"); the root is "".

## `M.isSubdomain(name, zone)`

Is `name` equal to or below `zone`?

## `M.encode(m, maxSize)`

m: id, qr (bool), opcode, aa, tc, rd, ra, rcode, questions = { {name, type, class} }, answers / authority / additional = { rr }.
rr = { name, type, class, ttl, data }. With `maxSize` the message is cut at record boundaries and TC is set when something was left out.

## `M.dataText(rr)`

Text form of a record's data (for tools).

## `M.reverseName(ip)`

The name a reverse lookup of an address uses ("2.0.0.10.in-addr.arpa").
