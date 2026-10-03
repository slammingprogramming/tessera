# tsr.inet.wifi.frames

Package: `wifi`

Wi-Fi frames, in the spirit of IEEE 802.11 (beacons, probes, authentication, association, the four-way handshake, encrypted data) but simplified for
ComputerCraft modems: every frame is one modem message, a byte string. Wi-Fi channel n (1..14) uses modem channel 7110 + n, so APs and stations that
do not share a channel do not hear each other.

Header (19 bytes): type(1) bssid(6) source(6) destination(6).

## `M.parse(msg)`

Split a received message into header fields and body. Returns nil for anything that is not a Wi-Fi frame.

## `M.encodeBeacon(b)`

Beacon / probe response body.
