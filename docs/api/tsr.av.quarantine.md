# tsr.av.quarantine

Package: `av`

The quarantine: a folder where files that were found to be malware are put aside. A quarantined file cannot run (it is renamed to <id>.q) and is kept with a
note of where it came from and why it was moved, so that it can be restored if the scanner was wrong.

## `M.add(path, result)`

Move a file into quarantine. result: the scan result (for the notes). Returns the id, or nil + reason.

## `M.restore(id, dest)`

Put a file back (to its old place unless dest is given). The file is not scanned again, so only do this for files you know are safe.

## `M.purge(days)`

Remove items older than `days`.
