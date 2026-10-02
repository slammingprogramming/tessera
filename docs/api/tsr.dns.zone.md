# tsr.dns.zone

Package: `dns`

Zone files for the in-game name service. A zone file is plain text, one record per line:

    $origin base            names without a dot get this suffix:  "farm1" means "farm1.base"
    $ttl 3600               default time to live of the records below, in seconds
    farm1        A      14          the name points at computer 14
    gate         A      9
    www          CNAME  farm1       an alias for another name
    ssh.farm1    TXT    "main entrance, key SHA256:..."
    @            NS     3           the name server(s) for this zone: computer ids

Names are lower case letters, digits, '-' and '_' separated by dots. "@" is the origin itself.

## `M.normalize(name, origin)`

Normalise a name: lower case, only the allowed characters. With an `origin`, names are relative to it ("note.farm1" in zone "base" is
"note.farm1.base") unless they end with a dot (absolute) or already end with the origin. Returns the name or nil + reason.

## `M.parse(text)`

Parse a zone file. Returns { origin, ttl, records = { { name, type, value, ttl } } }, problems.

## `M.format(records)`

Render records back into text (without directives).
