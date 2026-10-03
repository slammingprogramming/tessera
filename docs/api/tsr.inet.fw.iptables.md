# tsr.inet.fw.iptables

Package: `inet-fw`

The iptables command language (the useful subset) for tsr.inet.fw:
  iptables [-t filter|nat] -A|-I CHAIN [n] <match...> -j TARGET [target options]      add / insert a rule
  iptables [-t table] -D CHAIN n | <rule spec>    -F [CHAIN]   -N CHAIN   -X CHAIN   -P CHAIN ACCEPT|DROP   -Z   -L [CHAIN] [-n] [-v]   -S
matches:  -p tcp|udp|icmp|N  -s ADDR[/N]  -d ADDR[/N]  -i IF  -o IF  (IF may end in +)  --sport P[:Q]  --dport P[:Q]  -m multiport --dports a,b,c:d
          -m state --state NEW,ESTABLISHED,RELATED,INVALID   (or -m conntrack --ctstate)  --syn  --tcp-flags MASK COMP  --icmp-type echo-request
          -m limit --limit 5/second [--limit-burst 10]   -m connlimit --connlimit-above N      a leading ! negates addresses and ports
targets:  ACCEPT DROP REJECT [--reject-with ...] LOG [--log-prefix X] RETURN  MASQUERADE [--to-ports a]  SNAT --to-source IP[:port]
          DNAT --to-destination IP[:port]  REDIRECT --to-ports N  or the name of a chain you made with -N

## `M.tokenize(line)`

Split a line into words; "double quoted" text stays together.

## `M.parseRule(tokens, from)`

Parse the match and target part of a rule (everything after the chain). Returns a rule table or nil + reason.

## `M.ruleText(rule)`

The iptables text of a rule (what -S prints and what saved files contain).

## `M.exec(fw, args, ctx)`

Execute one iptables command (a list of words without the leading "iptables"). ctx.say / ctx.err print. Returns true or false.

## `M.load(fw, text)`

Apply a file of iptables commands ("-A INPUT ..." / "iptables -A ..."; one per line; # comments; a line "-t nat" may start a command). Returns problems.

## `M.save(fw)`

The whole rule set as text that M.load reads back.
