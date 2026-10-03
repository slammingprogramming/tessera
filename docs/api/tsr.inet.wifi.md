# tsr.inet.wifi

Package: `wifi`

Wi-Fi for the network stack. A station (wlan0) is configured in /etc/tsr/inet/network.lua:
  wlan0 = { modem = "top", wifi = { ssid = "home", passphrase = "correct horse", channels = { 1, 6, 11 } }, dhcp = true }
An access point is configured in /etc/tsr/inet/wifi-ap.lua (see tsr.inet.wifi.ap).

## `M.attachStation(stack, name, spec)`

Create the interface for a station and start listening. The wifid service runs the connection loop (sta:run()).
