# tsr.mobile.apps

Package: `mobile`

Screens of the built-in phone apps. Each builder is function(root, phone, env): it fills `root` (the content area).
`env` is optional and lets tests replace network, gps and configuration.

## `M.serveMessages(node, env)`

Register the "msg" service: incoming messages become notifications and are kept in the message log.
