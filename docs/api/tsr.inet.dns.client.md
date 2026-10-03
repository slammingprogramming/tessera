# tsr.inet.dns.client

Package: `inet-dns`

The DNS client: one query to one server (UDP, with TCP when the answer was truncated) and the stub resolver that the rest of the system uses
through stack:resolve(name): the servers come from DHCP or the configuration (stack.dnsServers), names without a dot get the search domains,
answers are cached for their TTL, and failures are cached for a short while so a dead name does not slow every program down.

## `M.query(stack, server, name, qtype, opts)`

Ask one server. opts: rd (recursion desired, default true), timeout, tcp (force TCP), edns no. Returns the decoded reply or nil + reason.

## `M.lookup(stack, name, qtype, opts)`

Resolve name/type with the configured servers. Returns { rcode, answers, authority, cached } or nil + reason.

## `M.resolveName(stack, name, timeout)`

name -> ip with search domains. This is what stack:resolve calls after the hosts table.

## `M.install(stack)`

Make this stack use DNS for names it does not know from the hosts table.

## `M.reverse(stack, ip)`

Reverse lookup: ip -> name.
