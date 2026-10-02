# tsr.netmon

Package: `netmon`

Network monitor: see what travels over the in-game network, like tcpdump or Wireshark.
  Monitor.attach(node, opts)    watch every message that goes through this computer's node (needs the network daemon or another reader)
  Monitor.sniffer(opts)         "promiscuous mode": listen on modem channels for rednet traffic between OTHER computers in range
Records are { at, dir, peer, to, kind, size, protection }; the payload is not kept, only what kind of message it is and whether it
was protected (encrypted, signed or plain). This also shows why unprotected messages should not carry secrets: anybody with a modem
in range can do exactly what the sniffer mode does.

## `M.classify(msg)`

What kind of message is this, and how well is it protected?

## `Monitor:wants(rec)`

Does this record pass the filter? filter: types (set of kind prefixes), peers (set of ids), drops (only refused messages), dir.

## `M.attach(node, opts)`

Start watching a net node. Returns the monitor; monitor:stop() detaches.

## `M.sniffer(opts)`

Promiscuous mode: open `channels` (a list of numbers, e.g. computer ids) on every modem and decode rednet envelopes seen there.
Feed it the events with monitor:event(ev) (the CLI does). Returns the monitor and how many channels were opened.

## `Monitor:event(ev)`

Handle an event table { "modem_message", side, channel, replyChannel, message, distance }. Returns the record or nil.

## `M.format(rec, base)`

One line of text for a record.

## `Monitor:summary()`

A summary: totals by kind and by peer, and a note about plain traffic.

## `Monitor:save(path)`

Save the recorded messages as tab-separated text (netmon read <file> shows them again) / load them.
