# tsrapps.redseq

Package: `redstone`

redseq: timed redstone sequences — piston doors, dispenser clocks, lighting shows, cannon volleys.
  redseq run <name|file> [--times N]     run a sequence (name = /etc/tsr/redseq/<name>.seq)
  redseq check <name|file>               parse only; prints the steps and the total time
  redseq list                            sequences in /etc/tsr/redseq
A sequence file has one command per line ("#" starts a comment):
  on <port>            off <port>         set <port> <0-15>
  pulse <port> <sec>   toggle <port>      wait <sec>
  repeat <n>  ...  end                    repeat the enclosed lines (may be nested)
Ports are as in `rs` (top, back:red, relay_0/left ...).

## `M.parse(text, env)`

Parse sequence text into a step list. Returns steps, or nil + "line N: reason".

## `M.duration(steps)`

Total running time of a step list in seconds.

## `M.count(steps)`

Number of primitive steps (repeats expanded).

## `M.run(steps, env, opts)`

Execute steps. env: redstone, peripheral, sleep (see tsrapps.rsio). opts.onStep(step) is called before each step.
Outputs that were switched on by the sequence are switched off again if it stops with an error.
