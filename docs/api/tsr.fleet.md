# tsr.fleet

Package: `fleet`

Fleet control for turtles.
  On each turtle:        the fleetd service offers the "turtle" service to paired computers that are on its allow list
  On the controller:     fleet list | run <turtle|all> <job> [args] | stop <turtle|all> | goto <turtle> x y z | log <turtle>
                         fleet add <peer> | remove <peer> | roster | allow <peer> | deny <peer> | allowed
Jobs are the installed turtle programs (bore, carve, stripmine, quarry, build, treefarm, cropfarm, cobblegen, guard,
tresume): a remote turtle runs only programs on its job whitelist, never arbitrary commands. Everything travels over
paired, signed (and for `run`, encrypted) net calls.

## `M.spawnJob(path, args, cap)`

Start a program as a background process with captured output. Replaceable in tests. Returns pid.

## `M.serve(node)`

Register the "turtle" service on `node`.

## `M.poll(node, names)`

Ask every roster turtle for its status. Returns an array of { name, ok, status | error }.

## `M.daemon()`

The fleetd service (on turtles).
