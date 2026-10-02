# tsr.fw

Package: `firewall`

A packet filter for the in-game network, in the spirit of iptables / Windows Defender Firewall. It looks at every message a computer
receives (before any service sees it) and decides by rules whether to let it in. Rules live in /etc/tsr/firewall.rules:

    default deny                          # what happens when no rule matches: allow (the default) or deny
    allow from paired                     # computers you paired with
    allow type ping,disco.q from any      # anybody may ping and ask who offers what
    deny  from 15                         # computer 15 is shut out completely
    allow type ssh from 11,12,alpha       # computer ids or peer names
    limit 20/min type p2p from any        # at most 20 such messages per minute from each computer, the rest is dropped

Rules are checked top to bottom, the first match wins. `type` is the message type (ping, disco.q, time.q, rpc, ssh, ntp.q, p2p, pair.1 ...);
"p2p.find" narrows a type to one kind of message. `from` is any, paired (peers you paired with), computer ids or peer/host names.
Replies to something this computer sent a moment ago (or to its broadcast) always pass: closing the door to strangers must not
deafen the computer. Stateless apart from that, no deep inspection: a filter against noise and nuisances, not a defence against someone
who controls a modem.

## `M.parseLine(line)`

Parse one line. Returns rule, nil | false (blank or comment) | nil + reason.

## `M.parse(text)`

Parse a rules text. Returns { default = "allow"|"deny", list = rules }, problems.

## `M.new(set, opts)`

Create the filter state for a rule set. opts: clock (function -> seconds).

## `M.decide(state, node, from, msg)`

Decide about one message. Returns allow (boolean) and why (rule number, "reply", "default").

## `M.install(node, set, opts)`

Switch the firewall on for a node (rules read from the rules file unless `set` is given). Returns the state.

## `M.reload(node)`

Re-read the rules into the running filter (counters are kept). Returns problems.

## `M.daemon()`

The firewall service: install on the default node and re-read the rules when the file changes.
