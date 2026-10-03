# tsr.inet.dns.zone

Package: `inet-dns`

Zones: master files (RFC 1035 section 5) and the lookup rules of an authoritative server (RFC 1034 section 4.3.2): exact names, CNAME chains,
wildcards, "name exists but has no data", delegations (referrals with glue) and NXDOMAIN with the SOA for negative caching.

## `Zone:remove(name, rtype)`

Remove records: by name, optionally of one type (and optionally one value text).

## `Zone:all()`

All records, SOA first (the order AXFR wants), then sorted by name and type.

## `Zone:lookup(qname, qtype)`

Answer a question from this zone's data. Returns { rcode, aa, answers, authority, additional, referral }.

## `M.parse(text, origin)`

Parse master file text. Returns a Zone (origin from $ORIGIN or `origin`) and a list of problems ("line 4: ...").

## `M.serialize(zone)`

Text of a zone as a master file that parse() reads back.
