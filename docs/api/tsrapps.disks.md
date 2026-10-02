# tsrapps.disks

Package: `disk-tools`

disks: everything you want to do with floppy disks and disk drives.
  disks                      list drives: side, label, id and free space
  disks info [side]          contents of a disk (files, sizes, free space)
  disks label <side> <text>  set the label ("" clears it)
  disks copy <from> <to>     copy a file or folder; a disk side like "right" stands for its mount path
  disks wipe <side> [-y]     delete everything on a disk
  disks startup <side> <program>   make the disk run <program> (a path on the disk) when inserted and booted
  disks eject <side>

## `M.drives(env)`

Sides that have a drive attached (with or without a disk).

## `M.describe(side, env)`

One line describing a drive.

## `M.resolve(spec, env)`

Resolve "right" to its mount path when it names a drive with a disk; otherwise the text is a path.

## `M.tree(path)`

List files under `path`: array of { path, size, dir }.

## `M.wipe(path)`

Delete everything inside `path` (not the path itself). Returns the number of entries removed.

## `M.makeStartup(mount, program)`

Write a startup file that runs `program` (a path relative to the disk).
