# tsr.inet.bytes

Package: `inet`

Byte-level helpers for the network stack: big-endian integers, the Internet checksum (RFC 1071), IPv4 and MAC address text forms,
CIDR arithmetic. Addresses are Lua numbers (IPv4: 0..2^32-1) or 6-byte strings (MAC).

## `M.rd16(s, i)`

Read a big-endian 16/32-bit number at position i of string s (1-based). Returns nil if the string is too short.

## `M.sum(data, init)`

The Internet checksum of `data` (RFC 1071): one's complement of the one's complement sum of 16-bit words. `init` is a partial sum
(for pseudo headers). Returns the 16-bit checksum to store; a packet that includes its checksum sums to 0 when intact.

## `M.ip(text)`

"10.0.0.1" -> 167772161, or nil when the text is not a dotted quad.

## `M.mask(plen)`

The netmask for a prefix length (0..32) as a number.

## `M.band(a, b)`

Bitwise AND of two 32-bit numbers (bit32 is available in ComputerCraft; this keeps results non-negative).

## `M.cidr(text)`

"10.0.0.0/24" -> network number, prefix length. A bare address is /32. Returns nil for bad input.

## `M.broadcast(net, plen)`

The broadcast address of net/plen.

## `M.maskToPrefix(text)`

Dotted-quad mask "255.255.255.0" -> 24, or nil when it is not a contiguous mask.

## `M.mac(text)`

"02:00:5e:00:00:01" -> 6 raw bytes (or nil).

## `M.makeMac(a, b, c)`

A locally administered unicast MAC (02:...) built from numbers, e.g. computer id and interface index.

## `M.seqLt(a, b)`

Sequence number arithmetic modulo 2^32 (TCP): is a before b, a before-or-equal b, difference.
