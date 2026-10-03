# tsr.inet.wifi.keys

Package: `wifi`

Wi-Fi keys, in the manner of WPA2-Personal: the passphrase and the network name make a Pairwise Master Key (PBKDF2), the handshake mixes in two random
numbers and both addresses to make a Pairwise Transient Key that nobody can compute without the passphrase, and every data frame is sealed
(ChaCha20-Poly1305) with a packet number that must increase, which stops replays.
  PMK = PBKDF2-HMAC-SHA256(passphrase, ssid, iterations)           (the iteration count is lower than WPA2's 4096: this runs in Lua)
  PTK = HKDF(PMK, "tessera-wpa" .. sorted MACs .. ANonce .. SNonce, 64)  -> KCK (16, for MICs) | KEK (16, unused) | TK (32, for data)

## `M.mic(kck, data)`

A message integrity code over the handshake message (with the MIC field left out).

## `M.seal(tk, pn, direction, plain, aad)`

Seal an Ethernet frame for the air. `direction`: 0 station->AP, 1 AP->station. aad = the 19 header bytes.

## `M.open(tk, direction, body, aad)`

Returns the frame and its packet number, or nil.
