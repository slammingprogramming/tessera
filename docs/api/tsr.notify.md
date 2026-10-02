# tsr.notify

Package: `mobile`

Notifications: a small persistent inbox that services push to and the phone interface shows.
  notify.push("Reactor", "Temperature high", { level = "warn" })     (also queues the event "tsr_notify")
  notify.list() -> newest first        notify.unread()        notify.markRead()        notify.clear()

## `M.push(title, text, opts)`

Add a notification. opts: level ("info" default, "warn", "error"), source.

## `M.list()`

All notifications, newest first.
