# tsr.av.daemon

Package: `av`

The avd service: scans a floppy or other disk when it is inserted (before anything on it runs automatically), scans the folders named in the settings every few
hours, and fetches new definitions from the configured sources. What it finds goes to /var/log/av.log and, with action = quarantine, into the quarantine.

## `M.scanDisk(side, settings)`

Scan what is on a disk drive. Returns the summary.
