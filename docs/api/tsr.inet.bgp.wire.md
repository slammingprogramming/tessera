# tsr.inet.bgp.wire

Package: `bgp`

BGP-4 messages (RFC 4271): the 19-byte header, OPEN, UPDATE with its path attributes (ORIGIN, AS_PATH, NEXT_HOP, MED, LOCAL_PREF, COMMUNITIES),
KEEPALIVE and NOTIFICATION. AS numbers are two bytes (1..65535; 64512..65534 are the private range, which is what players should use).

## `M.parseHeader(head)`

Split the header off a complete message: returns type, body or nil + reason.

## `M.openBody(o)`

o: as, holdTime, id (router ID, IPv4 number), auth (optional parameter: a string).

## `M.updateBody(u)`

u: withdrawn = { {net, plen} }, nlri = { {net, plen} }, attrs = { origin, asPath = { as, ... }, nextHop, med, localPref, communities = { n } }.

## `M.parseUpdate(body)`

Returns { withdrawn, nlri, attrs } or nil + reason.
