# tsr.home.daemon

Package: `smarthome`

The homed service: runs the schedule of scenes and, when an MQTT broker is configured, keeps the broker informed about every device and obeys the "set" topics.

## `M.clock(kind)`

The clock the schedule uses: { hour, min, day, date }.
