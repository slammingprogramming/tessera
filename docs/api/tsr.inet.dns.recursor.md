# tsr.inet.dns.recursor

Package: `inet-dns`

A recursive resolver (RFC 1034 section 5.3.3): starts at the root servers you give it (the root hints of YOUR network - in this game the root
zone is whatever the players run), follows referrals down the tree, resolves name servers that came without an address, chases CNAMEs, and caches
answers, delegations and failures. It can also just forward to other resolvers.

## `M.new(stack, opts)`

opts: roots (list of addresses), forwarders (list of addresses; when present nothing is resolved iteratively, or "upstream": the DNS servers this computer itself
learned by DHCP or has configured, other than itself: what a home router wants), timeout.

## `Recursor:startServers(name)`

The servers to start from for `name`: the deepest cached delegation, else the roots.

## `Recursor:resolve(name, qtype, depth)`

Resolve (name, type). Returns { rcode, answers, authority } or nil + reason.
