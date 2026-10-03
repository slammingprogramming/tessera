# tsr.inet.switch.cli

Package: `inet-switch`

The swctl command (management of the switch running on this computer):
  swctl show [ports|vlan|mac|stp|neighbors|status]
  swctl port <name> access <vlan>          | trunk [allowed 10,20] [native <vlan>]   | enable | disable
  swctl port <name> security <max> [shutdown|restrict|protect] | security off | storm <packets/s> | storm off | cost <n>
  swctl vlan add <id> [name] | vlan del <id>
  swctl mac add <vlan> <mac> <port> | mac flush [port]
  swctl mirror <dest-port> <source,source...> | mirror off
  swctl svi <vlan> <a.b.c.d/n>            (an IP interface of the switch in a VLAN)
  swctl stp on|off | stp priority <n>
  swctl save                               write the running configuration to /etc/tsr/inet/switch.lua

## `M.snapshot(sw)`

The running configuration as a table that M.CONFIG can hold.
