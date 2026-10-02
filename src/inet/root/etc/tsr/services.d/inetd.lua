-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The network stack: interfaces, ARP, IP, ICMP, UDP and TCP for every program on this computer.
return {
  description = "network stack (IPv4, ICMP, UDP, TCP)",
  module = "tsr.inet.daemon",
  entry = "main",
  autostart = true,
  restart = "on-failure",
}
