# tsr.inet.config

Package: `inet`

The network configuration file /etc/tsr/inet/network.lua and how it is applied to a running stack:

  return {
    hostname = "gw1",
    forwarding = false,                         -- route packets between interfaces (a router)
    interfaces = {
      eth0 = { modem = "back", channel = 7101, addresses = { "10.0.0.2/24" }, gateway = "10.0.0.1", mtu = 1500 },
      wlan0 = { modem = "top", channel = 7102, dhcp = true, key = "link passphrase" },
      ["eth0.20"] = { vlan = 20, parent = "eth0", addresses = { "10.20.0.1/24" } },
    },
    routes = { { "10.9.0.0/16", "10.0.0.254", metric = 5 } },
    hosts = { alpha = "10.0.0.7" },
    dns = { "10.0.0.53" }, search = { "lan" },
  }

With no file (or no `interfaces`) every modem found gets an interface and asks for an address by DHCP when the dhcp package is installed.

## `M.detectModems()`

Modems attached right now: list of { name, wireless }.

## `M.automatic()`

What to do when there is no configuration: one interface per modem, addresses by DHCP.

## `M.apply(stack, cfg)`

Apply a configuration to a stack. Returns a list of problems (strings); the rest is applied as far as possible.

## `M.snapshot(stack)`

Describe the running stack as a configuration table (what `ip save` writes).
