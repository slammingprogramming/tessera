# tsr.inet.fw

Package: `inet-fw`

A stateful packet filter and NAT in the manner of Linux netfilter / iptables, for the IP stack of this computer.

  tables:  filter (INPUT: packets to this computer, FORWARD: packets routed through it, OUTPUT: packets it sends)
           nat    (PREROUTING: before routing, destination NAT / port forwarding;  POSTROUTING: after routing, source NAT / masquerading)
  rules:   match on protocol, addresses, ports, interfaces, connection state, TCP flags, ICMP type, rate and connections per source; the first rule
           that matches decides (ACCEPT, DROP, REJECT, LOG, jump to your own chain, ...); no match = the chain's policy.
  state:   the connection tracker (tsr.inet.fw.conntrack) follows every flow, so `-m state --state ESTABLISHED,RELATED -j ACCEPT` lets replies in
           without opening the door to anything else, and NAT translates both directions of a flow consistently.

## `M.install(stack)`

Create the firewall for a stack and install its hooks.

## `FW:addRule(tableName, chainName, rule, position)`

Add a rule (position nil = append, number = insert before that rule number, 1-based).

## `FW:trackIncoming(pkt, ctx, fromOutput)`

Work out the state of a packet and apply the translation of an existing flow. Sets pkt.fw = { entry, dir, state, t }.
