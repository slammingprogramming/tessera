# tsr.inet.wifi.sta

Package: `wifi`

A Wi-Fi station: the network card of a computer that connects to an access point. To the IP stack it is an ordinary Ethernet interface (wlan0); underneath
it scans the channels for the network, authenticates, associates, runs the four-way handshake, encrypts what it sends, and looks for a better
access point when the signal drops or the beacons stop. Signal strength is estimated from the distance the modem reports.

  local sta = require("tsr.inet.wifi.sta").new(stack, { name = "wlan0", modem = "top", ssid = "home", passphrase = "correct horse" })
  sta:run()                  -- blocks forever: (re)connects whenever the link is down
  sta:scan() -> list of networks

## `M.new(stack, cfg)`

cfg: name (wlan0), modem (peripheral name or object), modemName (when modem is an object), ssid, passphrase (none = open network), channels (list, default 1..14),
mac, iterations, bssid (connect only to this access point), roamThreshold (signal % below which a better AP is looked for, 35), roamMargin (15).

## `Sta:scan(ssid)`

Look for networks on every channel. Returns a list sorted by signal: { ssid, bssid, channel, security, signal }.

## `Sta:connect(ssid, passphrase)`

One connection attempt to the named network. Returns true or nil + reason.

## `Sta:run()`

Keep the connection up: connect, watch the beacons and the signal, roam, reconnect.
