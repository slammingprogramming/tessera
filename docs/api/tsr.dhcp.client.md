# tsr.dhcp.client

Package: `dhcp`

The DHCP client (RFC 2131): asks for an address on an interface, applies the lease (address, default route, DNS servers, search domain, MTU,
time servers) and keeps it alive: renew at T1 (half the lease) with the server, rebind at T2 (7/8) with anybody, start again when it runs out.
  client.run(stack, "eth0", opts)      blocks forever (run it in its own process or thread); opts: hostname, onBound(lease), onLost(), tries
  client.acquire(stack, "eth0", opts)  one DISCOVER/OFFER/REQUEST/ACK exchange; returns a lease table or nil + reason

## `M.acquire(stack, ifname, opts)`

One full exchange. opts: hostname, tries (number of DISCOVER rounds), probe (check the offered address with ARP, default true).

## `M.apply(stack, ifname, lease)`

Put a lease into effect on the stack.

## `M.run(stack, ifname, opts)`

Keep an interface configured forever.

## `M.release(stack, ifname)`

Say goodbye: tell the server we no longer need the address, and take it down.
