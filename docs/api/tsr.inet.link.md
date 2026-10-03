# tsr.inet.link

Package: `inet`

The physical layer: how Ethernet frames travel over ComputerCraft modems.

A modem sends a message on a numbered channel and every modem that has opened that channel (and is in reach: connected by networking cable, or
within range for wireless) receives it. That is exactly a shared medium, so a channel is used like a cable segment or a radio frequency:
  * wired modems on one cable network that listen on the same channel form one segment (a hub); two separate cable networks are two segments;
  * wireless modems in range of each other that use the same channel form one segment; choose another channel for a private radio link;
  * a switch or router with several modems joins segments (see tsr.inet.switch and the routing packages).
The frame is the byte string of an Ethernet II frame (tsr.inet.wire). Optional link encryption seals each frame with ChaCha20-Poly1305 under
a shared key (like MACsec), so that only computers with the key can read or inject frames on that channel.

## `M.attachModem(stack, spec)`

Open a modem as an interface of `stack`. spec: peripheral (name), channel, name (interface name), mac, mtu, key (link encryption secret),
kind ("ethernet" for cables, "wifi" is set by the Wi-Fi package). Returns the interface, or nil + reason.

## `M.deriveKey(secret)`

Derive the link key from a passphrase (the same on every computer of the segment).

## `M.addHandler(stack, peripheralName, fn, name)`

Register a handler for everything a modem receives (used by Wi-Fi, which listens on several channels and speaks its own frame format).
fn(ev) gets every modem_message event of that peripheral. Returns the driver record; M.detach(name) removes it by the name field.

## `M.dispatch(ev, stack)`

Feed a modem_message event ({ "modem_message", side, channel, replyChannel, message, distance }) to the right interface.
With `stack`, only the drivers of that stack are considered (tests run several computers in one Lua state).

## `M.unseal(d, data)`

Open a sealed frame (see sealFrame). Returns the frame, or nil for damaged, forged or replayed ones.
