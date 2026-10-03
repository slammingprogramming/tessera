# tsr.inet.switch

Package: `inet-switch`

A managed Ethernet switch: it joins the interfaces of this computer (each connected to its own cable or radio channel) into one network.
  * learns which MAC address lives behind which port and forwards frames only there (floods what it does not know);
  * VLANs (IEEE 802.1Q): access ports belong to one VLAN, trunk ports carry tagged frames for several;
  * Spanning Tree (IEEE 802.1D) blocks redundant links so cables can form loops safely (see stp.lua);
  * port security (limit or fix the MAC addresses on a port), broadcast storm control, port mirroring, LLDP neighbour discovery;
  * switch virtual interfaces (SVI): an IP interface of the switch inside a VLAN, for management and routing between VLANs.
It plugs into the IP stack through the interfaces' rxhook, so the same computer can also run routing, DHCP and so on.

## `M.new(stack, cfg)`

cfg: name, aging (300 s), maxMacs (2048), ports = { name = { mode = "access"|"trunk", vlan, native, allowed = {..}, cost, secure = {...}, storm = pps } },
vlans = { [id] = name }, stp = { enabled, priority, ... }, svis = { [vlan] = "10.0.0.1/24" }, mirror = { dest, sources = {..} }, lldp = true.

## `Switch:addVirtualPort(name, spec)`

A port that is not a stack interface (a Wi-Fi client, a tunnel): spec.send(frame) puts a frame on it; feed frames from it with switch:ingress(port, frame).

## `Switch:configurePort(name, changes)`

Reconfigure a port at run time: mode, vlan, native, allowed (list or nil), cost, secure, storm.

## `Switch:flushPort(name)`

Remove learned addresses (all, or those of one port).

## `Switch:egress(port, f, vlan, original, taggedOriginal, from)`

Send the frame on `port` in the right form for its mode. `f` is the decoded frame (vlan field = the frame's own tag, if any).

## `Switch:ingress(port, frame)`

A frame arrived on a port.

## `Switch:cpuEgress(vlan, frame)`

A frame the switch itself sends into VLAN `vlan` (from an SVI).

## `Switch:sendRaw(port, dst, ethType, payload)`

Raw frame from this switch on one port (BPDU, LLDP).

## `Switch:macTable()`

Lines of the MAC address table.
