# tsr.pkg.install

Package: `pkg`

Transactional install/remove.
  1. every payload is fetched, verified (SHA-256) and staged in /var/cache/tsr/stage — nothing else is touched yet
  2. a journal is written, then staged files are moved into place (fs.move costs no extra space); replaced files are
     first moved aside to <path>.tsr-old
  3. the package database is saved, the journal is marked done, old files are removed
A crash or failure before step 3 rolls everything back (M.recover() at boot); after it, cleanup is finished.
Files that existed before and are not owned by any package (e.g. the user's own startup.lua) are kept in
/etc/tsr/backup/ rather than deleted.

## `M.spaceNeeded(plan)`

Net bytes a plan adds to the disk (replaced files are subtracted).

## `M.recover()`

Repair an interrupted transaction. Returns "rolled back", "finished" or nil (nothing to do).

## `M.apply(plan, opts)`

plan: array from resolve.plan. opts: progress(event, ...), lazy (bool: install stubs only), keepCache (bool)
Returns true, or nil + error message.

## `M.remove(names, opts)`

Remove installed packages. opts.force skips the reverse-dependency and `core` checks.
