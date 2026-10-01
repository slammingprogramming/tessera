-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Web gateway: exposes chosen services to HTTP through an external gateway program",
  packages = { "net", "webgw" },
  services = { "netd", "webgwd" },
  notes = "Run tools/gateway/gateway.mjs on your own machine, then 'webgw setup ws://host:8080/ws <token>' here.",
}
