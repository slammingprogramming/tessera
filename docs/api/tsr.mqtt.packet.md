# tsr.mqtt.packet

Package: `mqtt`

MQTT 3.1.1 packets (the publish/subscribe protocol of the Internet of Things), QoS 0 and 1.
Packets are tables:
  { type = "connect", clientId, clean, keepalive, username, password, will = { topic, payload, qos, retain } }   { type = "connack", sessionPresent, code }
  { type = "publish", topic, payload, qos, retain, dup, id }          { type = "puback", id }
  { type = "subscribe", id, topics = { { filter, qos } } }            { type = "suback", id, codes = { 0, 1, 128 } }
  { type = "unsubscribe", id, topics = { filter } }                   { type = "unsuback", id }
  { type = "pingreq" } { type = "pingresp" } { type = "disconnect" }
encode(packet) -> bytes;  read(socket, timeout) -> packet (or nil + reason): reads one packet from a connection.

## `M.decode(code, flags, body)`

Turn the bytes after the fixed header into a packet. Returns the packet or nil + reason (a protocol violation).

## `M.read(sock, timeout)`

Read one packet from a socket. Returns the packet, or nil + reason ("timeout", "closed", or a protocol error text).
