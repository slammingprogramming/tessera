# The in-game internet

Tessera can give a Minecraft world a **complete, working internet** of its own: Ethernet and Wi-Fi at the bottom, IPv4 with ICMP, UDP and TCP
above it, DHCP and DNS, switches and routers, firewalls and NAT, routing protocols, a web, mail and the protocols of the Internet of Things.
Players build the network the way real networks are built: a cable here, an access point there, a router between two bases, a peering agreement
between two players' networks. Everything runs **inside the game** on ComputerCraft computers. Nothing in it connects to the real Internet; the
only things that may (HTTP, if the server allows it, for installing packages and for an optional UTC clock) are the same as before.

> Status: built and tested in CraftOS-PC with a simulated network (hundreds of tests, including loss, reordering, duplication, jitter and multi-hop
> topologies). **Nothing has run in real Minecraft yet.** The honest limits are at the end of this page.

The networking packages are all **optional**: a computer without them keeps the small, `rednet`-based `net` package. Install what you need.

## The layers

The stack follows the layering model of the Internet (and the OSI model it is usually taught with). Each layer is a separate module that talks to
the one below it through a small interface, so every layer can be tested alone.

| Layer | What it does here | Standards followed | Package |
|---|---|---|---|
| 1 Physical | A modem (wired or wireless) on a channel is the "cable" or the "radio"; computers on the same channel hear each other. Optional link encryption. | CC: Tweaked modem API | `inet` (`link`) |
| 2 Data link | Ethernet II frames with MAC addresses, ARP, VLAN tags, switches that learn addresses and block loops, Wi-Fi-style access points and stations. | IEEE 802.3 framing, 802.1Q, 802.1D, LLDP; WPA2-style handshake | `inet`, `inet-switch`, `wifi` |
| 3 Network | IPv4 with fragmentation and reassembly, routing tables, ICMP (echo, errors, traceroute), forwarding, NAT, packet filtering, routing protocols. | RFC 791, 792, 1918, 2453 (RIPv2), 4271 (BGP-4) | `inet`, `inet-fw`, `inet-route`, `bgp` |
| 4 Transport | UDP, and TCP with the real state machine, retransmission, congestion control (Reno/NewReno), window handling. | RFC 768, RFC 9293, 6298, 5681 | `inet` |
| 5–7 Session to application | Sockets, DHCP, DNS, HTTP/1.1 (server, client, text browser), TLS-style encryption with certificates, NTP over UDP, SMTP and POP3, MQTT, Modbus/TCP, and `tsr.net` (the rednet-style services: remote shell, file access, pairing) carried over IP. | RFC 2131, 1035, 9110/9112, 5321, 1939, 5905 (NTPv4); MQTT 3.1.1; Modbus/TCP | `dhcp`, `inet-dns`, `web`, `tls`, `ntp`, `mail`, `mqtt`, `modbus` |

Messages are real: a ping really is an ICMP echo inside an IPv4 packet inside an Ethernet frame, with the real checksums. `tcpdump` shows them
decoded, and `netmon` can listen to a channel from outside. Where the real protocol would not fit ComputerCraft (the Wi-Fi radio details, TLS
certificates, BGP security), the replacement is described in the sections below.

## First steps

Install the stack (a modem must be attached):

```
pkg install inet dhcp web
svc start inetd        # the network stack (it also starts at boot)
ip addr                # your interfaces; with a DHCP server on the network you get an address
ping 10.0.0.1
traceroute 10.2.0.7
nc 10.0.0.1 80         # a plain TCP connection
```

With no configuration file, every modem becomes an interface and asks for an address by DHCP. For fixed addresses write
`/etc/tsr/inet/network.lua` (or build it with `ip addr add ...` and save it with `ip save`):

```lua
return {
  hostname = "gw1",
  forwarding = false,                     -- true on a router
  interfaces = {
    eth0 = { modem = "back", channel = 7101, addresses = { "10.0.0.2/24" }, gateway = "10.0.0.1" },
    wlan0 = { modem = "top", channel = 7110, dhcp = true },
    ["eth0.20"] = { vlan = 20, parent = "eth0", addresses = { "10.20.0.1/24" } },
  },
  routes = { { "10.9.0.0/16", "10.0.0.254", metric = 5 } },
  dns = { "10.0.0.53" },
}
```

Addresses follow the real rules (RFC 1918 private ranges are what you will use). **Start with the installer**: `tsr-setup` asks what the computer is
for (see "Use cases" below) and writes these files for you.

## The commands

| Command | What it does |
|---|---|
| `ip`, `ifconfig` | Interfaces, addresses, routes, neighbours (`ip addr`, `ip route`, `ip neigh`, `ip link`). |
| `ping`, `traceroute` | ICMP echo and the path to a host. |
| `netstat`, `nc` | Open sockets and listeners; a TCP/UDP swiss-army knife. |
| `tcpdump` | Decoded packets on an interface (filters by host, port, protocol). |
| `arp` | The ARP table. |
| `dhcp` | DHCP client status and leases; the server's pools and leases. |
| `nslookup`, `dnsctl` | Ask a name server; manage zones and records on yours. |
| `swctl` | Switch: ports, MAC table, VLANs, Spanning Tree, port security, mirroring. |
| `wifi` | Scan, join, status of stations; clients of an access point. |
| `iptables`, `iptables-save`, `iptables-restore`, `conntrack` | The packet filter and NAT, in the familiar syntax. |
| `routectl` | The routing table, RIP, and BGP sessions and policy. |
| `fetch`, `www` | HTTP client and a text browser (also an information-board mode). |
| `tlsctl` | Certificate authority, certificates, trust, revocation. |

## Building networks

### A LAN

Computers whose modems are on the same channel form one segment. Give them addresses by DHCP (`dhcpd`) or by hand. A **managed switch**
(`inet-switch`: one computer with several modems) joins separate cables into one network: it learns which address lives behind which port,
supports VLANs (access and trunk ports, tagged frames), runs Spanning Tree so that you may wire loops for redundancy, can limit the addresses
on a port, limit broadcast storms and mirror a port for `tcpdump`. A **switch virtual interface** gives the switch its own address inside a VLAN.

### A wireless network (a "PAN" or a Wi-Fi LAN)

An access point (`wifi`, service `wifiap`) announces an SSID, answers scans, authenticates stations and runs a four-way handshake derived from a
passphrase (WPA2-style, our own construction) so that traffic is encrypted. It bridges the stations to a wired segment and works as a small switch,
so VLANs per SSID, client isolation and MAC filters are available. Stations (`wifi scan`, `wifi join <ssid>`) behave like any other interface.
Range is whatever the wireless modem has in the game: a **personal area network** is a pocket computer or a few turtles around you.

### A router and the internet connection

A router is a computer with `forwarding = true` and an interface in each network. Add `inet-fw` for NAT, so a whole private network shares one
address (`iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE`), port forwards (`DNAT`), and a stateful firewall:

```
iptables -P FORWARD DROP
iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o eth1 -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables-save
```

The firewall hooks (prerouting, input, forward, output, postrouting) are the real ones; connection tracking understands TCP, UDP and ICMP (including
the errors that come back through NAT). Rules have counters, `LOG`, rate limits (`-m limit`) and connection limits.

### A wide area network and peering

Two bases far apart are two networks joined by a link (a wired cable over a chunk-loaded run, a wireless modem pair, a relay of routers). On a link
between your own routers use **RIP** (`inet-route`, service `ripd`) with a shared key (`auth = { type = "hmac", key = ... }`) so that nobody can inject routes.

Between networks run by **different players** use **BGP** (`bgp`, service `bgpd`). Every network is an autonomous system with a number; neighbours
exchange the prefixes they can reach and each router picks the best path. Peering agreements are first-class: each neighbour has a `relationship` that sets the policy:

| Relationship | Meaning | You prefer their routes | You tell them |
|---|---|---|---|
| `customer` | pays you for transit | most | everything you know |
| `peer` | exchanges traffic for free | middle | your own and your customers' routes |
| `provider` | you pay them | least | your own and your customers' routes |

On top: prefix filters in both directions, a maximum number of prefixes per neighbour, AS-path prepending, communities, origin validation against a list
of signed statements (route origin authorisations, "RPKI") that you keep, and a shared secret. Two players who make an agreement exchange AS numbers and
prefixes, point their `bgp.lua` at each other, and their networks are one internet. Nothing in the system forces anybody to peer.

### Names

`inet-dns` is a real name server: authoritative zones from files, secondaries by zone transfer (AXFR) with notifications, recursion that starts at
**root servers a player runs** (so a world can have its own `.lan` hierarchy), caching, and `"upstream"` forwarding for a home router. Clients ask
`nslookup name`; programs just use names: `ping www.example.lan`.

### Time

`ntp` serves and asks time over UDP between computers (and can read an HTTPS clock where HTTP is allowed). DHCP can hand out time servers.

## The web

`web` is an HTTP/1.1 server (static files from `/srv/www`, routes in Lua, ranges, keep-alive), a client (`fetch`), and a text browser (`www`) that
renders a useful subset of HTML. With `tls` the server and client speak HTTPS inside the world: a **certificate authority** you run signs certificates
for your servers; clients trust the authority (or pin a server's certificate on first use, like SSH). It is hobby-grade cryptography: it keeps other
players from reading your traffic, it does not protect anything real.

`www --board <url> --monitor <name>` turns a monitor into an **information board** that reloads a page and turns the pages of a long one.
Combined with the `tv` kiosk (`kiosk set www --board ...`) it keeps running and ignores Ctrl+T.

## Use cases in the installer

`tsr-setup` asks what the computer is for, after what kind of computer it is. Pick one and it installs the packages, writes starting files (never over
existing ones), enables the services, and prints what it generated (a Wi-Fi passphrase, a routing key):

| Use case | Becomes |
|---|---|
| Client PC | DHCP client, browser, mail program, `ssh` |
| Server | remote login, time, firewall, cron, packet capture |
| **Home router** (consumer) | NAT to the provider, DHCP and DNS for the home network, Wi-Fi, a default-deny firewall |
| **Enterprise router** | several networks, RIP with a key, a firewall with management only from the inside, `ssh`, time, a BGP template |
| **Managed switch** | every modem a port; VLANs, Spanning Tree, a management address |
| **Wi-Fi access point** | the wireless network bridged to the cable |
| **Firewall appliance** | stateful rules between an inside and an outside network |
| DHCP, DNS and time server | the infrastructure of a network |
| Mail server | `maild` with spam and virus protection, TLS |
| Web server | `httpd`, HTTPS with a certificate |
| Package mirror | packages for computers without HTTP |
| Embedded / IoT device | a small node: MQTT client, redstone and machine access |
| Smart home hub | rooms, devices, scenes, schedule, MQTT bridge |
| Industrial control | a Modbus slave exposing redstone and machines, rules, power monitoring |
| Kiosk / information display | a screen that shows one page or program for ever |

`tsr-setup usecases` lists them and says which ones this computer's modems allow; `tsr-setup --usecase router-home --auto` applies one unattended.

## Security

* **Default deny where it matters.** The router and firewall use cases start with `INPUT` and `FORWARD` policies of DROP and allow only what is needed.
* **Radio is public.** Anyone with a modem in range can read plain traffic. Use link encryption (`key` on the interface), Wi-Fi passphrases, TLS and `ssh`. `netmon` shows
  what an eavesdropper sees.
* **Keep routers honest.** Use authentication on RIP; prefix filters and a maximum prefix count on BGP; management only from the inside.
* **Configuration under `/etc/tsr/inet`, `/etc/tsr/mail`, `/var/mail` is administrator-only** when the `auth` package is installed.
* **Industrial protocols have no security of their own** (Modbus certainly not). The slave refuses clients outside its `allow` list and can be read-only. Put it behind a firewall.
* Report vulnerabilities privately: see [SECURITY.md](SECURITY.md).

## Honest limits

* **Speed.** The stack is Lua on a cooperative scheduler. Expect a few packets per second per computer on a busy router, and handshakes with Ed25519/X25519
  (TLS, `ssh`) to take seconds on a real computer; `doctor` measures it. Retransmission timers and window sizes are conservative.
* **The real number of computers.** ComputerCraft limits how many messages a modem can send; large file transfers over many hops are slow. TCP congestion
  control keeps it fair rather than fast.
* **Wireless detail.** There is no radio physics: range and channel are what the modem has. The Wi-Fi handshake is *inspired by* WPA2, not compatible with it.
* **Not IPv6.** The stack is IPv4 only (the game's networks are small, the addresses are enough).
* **Only simulated so far.** All of this is verified in an emulator with a simulated network, not in the game. Real timing, modem channel limits and chunk loading will change details.
* **Security.** The cryptography is for a game. BGP's origin validation is a list you keep, not a global system.
