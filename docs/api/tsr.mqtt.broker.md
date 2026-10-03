# tsr.mqtt.broker

Package: `mqtt`

The MQTT broker: devices connect and publish messages to topics; the broker passes each message on to everyone who subscribed to a matching filter.
Supported (MQTT 3.1.1): QoS 0 and 1, retained messages, will messages (sent when a device vanishes), persistent sessions (queued QoS 1 mail for a device that
is offline), wildcards, user names and passwords, access lists per user, limits. QoS 2 is not supported (a client asking for it is disconnected).
The broker does not touch sockets: a connection is a "sink" { send = function(bytes), close = function() } and packets are given to broker:handle(client, packet),
which makes it easy to test; tsr.mqtt.daemon connects it to TCP.

## `M.users(path, iterations)`

A user database: users:add(name, password), :remove(name), :check(name, password), :list().

## `M.new(opts)`

opts: allowAnonymous (default false), users (a user database, or authenticate = function(name, password) -> name|nil), acl = { [user or "*"] = { pub = { filters }, sub = { filters } } },
maxClients (50), maxSubscriptions (100 per client), maxRetained (1000), now (function), log (function).

## `Broker:open(sink)`

A new connection. Returns the client record to pass to handle().

## `Broker:route(topic, payload, qos)`

Pass a message to every subscriber. retain = the retain flag of the original publish (subscribers get it as false: only the stored copy delivered at subscribe time has it).

## `Broker:close(c, graceful)`

Close a connection. graceful = the client said goodbye (then its will is dropped).

## `Broker:handle(c, p)`

Process one packet from a client.

## `Broker:tick()`

Housekeeping: resend QoS 1 messages that were not acknowledged, drop silent clients. Call every few seconds.

## `Broker:sys()`

Broker statistics as topic/payload pairs ($SYS/...).

## `Broker:exportRetained()`

The retained messages as a plain table (for saving to disk) and back.
