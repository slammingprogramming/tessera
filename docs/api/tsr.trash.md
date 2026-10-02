# tsr.trash

Package: `safety`

Recycle bin. Deleted things are moved to /var/trash/<id>/ together with a note of where they came from, and can be restored
until the bin is emptied or grows beyond its size limit (the oldest entries go first).
  trash <path>...    move to the bin        trash list         what is in it
  trash restore <n>  put entry n back       trash empty [days] delete everything (or entries older than that many days)

## `M.list()`

All entries, oldest first: { id, path (original), time (ms), size, name }.

## `M.put(path)`

Move `path` into the bin. Returns the entry id, or nil + reason.

## `M.restore(which)`

Restore an entry (by id or 1-based position in list()). Returns the path it came back to, or nil + reason.

## `M.empty(days)`

Delete entries for good: all, or those older than `days`. Returns how many were removed.

## `M.discard(path)`

For file managers: move to the bin when the safety package is active, otherwise delete. Returns true or nil + reason.
