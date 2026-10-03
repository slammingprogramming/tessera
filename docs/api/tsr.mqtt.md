# tsr.mqtt

Package: `mqtt`

An MQTT 3.1.1 client: connect to a broker, publish messages, subscribe to topics, receive messages.
  local c, err = mqtt.connect(stack, "10.0.0.5", { clientId = "kitchen", username = "u", password = "p", keepalive = 60, will = { topic = "home/kitchen/online", payload = "0", retain = true } })
  c:subscribe("home/#", 1)     c:publish("home/kitchen/light", "on", { qos = 1, retain = true })
  local m = c:receive(5)       -- { topic, payload, qos, retain } or nil + "timeout"
  c:loop(function(m) print(m.topic, m.payload) end)      c:disconnect()

## `M.connect(stack, host, opts)`

Connect and log in. opts: port (1883), clientId, clean (true), keepalive (60), username, password, will, timeout.

## `Client:poll(timeout)`

Read one packet and deal with it. Returns the packet, or nil + reason ("timeout" when nothing came).

## `Client:publish(topic, payload, opts)`

Publish a message. opts: qos (0 or 1; with 1 the call waits for the broker's receipt), retain.

## `Client:subscribe(filter, qos)`

Subscribe to a filter (wildcards + and #). Returns the QoS the broker granted.

## `Client:receive(timeout)`

The next message (nil + "timeout" when none comes within the time). Keeps the connection alive meanwhile.

## `Client:loop(handler)`

Call handler(message) for every message until it returns false or the connection ends.
