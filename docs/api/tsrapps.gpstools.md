# tsrapps.gpstools

Package: `gps`

gps tools.
  gpshost setup | run | status      host a GPS beacon (needs a wireless/ender modem); setup stores the coordinates
  where [--save name] | list | to <name> | remove <name>     your position, waypoints, distance and bearing
A GPS constellation needs 4 hosts (three at the corners of a flat triangle plus one above); coordinates come from the
F3 debug screen of the block the computer stands on. All hosts must stay loaded. Waypoints live in /etc/tsr/waypoints.

## `M.wirelessModem(env)`

Is a modem that can transmit far attached? (wireless modems only; ender modems are wireless too)

## `M.bearing(x1, z1, x2, z2)`

Distance and compass bearing from (x1,z1) to (x2,z2). North is -z.
