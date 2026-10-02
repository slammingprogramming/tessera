# tsr.vm

Package: `sandbox`

Virtual computers: a sandbox with a disk of its own that you can start, leave and come back to.
  vm create <name> [kb]      a new virtual computer (default disk 200 KB)       vm list      vm delete <name>
  vm start <name>            run its CraftOS shell on this terminal (type `exit` to leave)
  vm run <name> <file> [args...]   run one program from the virtual disk
  vm put <name> <real file> [path in vm]    copy a file in      vm get <name> <path in vm> <real file>   copy a file out
A virtual computer cannot see the real file system, network, peripherals or other virtual computers, and cannot shut the real
computer down. Its disk is /var/vm/<name>/disk.

## `M.run(name, file, opts)`

Run a program from the virtual disk. opts: timeout, args. Returns the sandbox results (ok, ...).

## `M.start(name, opts)`

Start the CraftOS shell (after /startup.lua if the disk has one) inside the sandbox.

## `M.put(name, realPath, vmPath)`

Copy a real file into the virtual disk.
