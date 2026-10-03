# tsr.mqtt.daemon

Package: `mqtt`

The mqttd service: an MQTT broker on port 1883. Settings in /etc/tsr/mqtt/mqtt.lua:
  return { allowAnonymous = false, port = 1883, maxClients = 50,
           acl = { sensor = { pub = { "home/+/+/state" }, sub = {} }, ["*"] = { pub = {}, sub = { "home/#" } } } }
Accounts: mqttctl user add <name>.  Retained messages are kept in /var/lib/tsr/mqtt/retained.lua across restarts.

## `M.serve(broker, conn)`

Serve one TCP connection.
