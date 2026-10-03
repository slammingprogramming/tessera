# tsr.inet.nodebridge

Package: `inet`

Lets everything that talks through tsr.net (pairing, remote calls, ssh, rsh, netfs, torrent, the key server, ...) run over the IP network instead of
plain rednet: the same messages travel in UDP datagrams on port 7777. Computers are still addressed by their computer id:
  * a message for an id whose address we know (from the configuration, from earlier messages, from DNS name "cc<id>" or "<hostname>") is sent to that address;
  * otherwise it is broadcast on every network this computer is connected to, and the computer with that id answers (like rednet does);
  * `peers` in /etc/tsr/inet/nodes.lua are told about broadcasts too, so computers behind routers can find each other.
Turn it on with the setting net.transport = "ip" (settings app or `tsr config net.transport ip`).
  /etc/tsr/inet/nodes.lua:   return { ids = { [15] = "10.2.0.15", [16] = "fileserver.lan" }, peers = { "10.9.0.1" } }

## `M.transport(opts)`

opts: stack, id (this computer's id), config (instead of the file), domain (suffix for DNS names).
