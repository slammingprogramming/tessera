# tsr.cron

Package: `ops`

Cron: run commands on a schedule. The table lives in /etc/tsr/cron.tab, one job per line:
    every 10m   rs set top on          every <n>s|m|h|d   (real time, from when the scheduler started)
    at 06:00    tsr-backup             every day at that in-game time
    boot        svc start netd         once when the scheduler starts
  Lines starting with # are comments.
Commands run in a tsh session (or the CraftOS shell without tsh) inside their own process with a time limit;
what they print goes to /var/log/cron.log.

## `M.parseLine(line)`

Parse one line. Returns a job { kind, seconds | hour, command, text } or nil + error. Blank/comment lines return false.

## `M.load()`

Read the table. Returns jobs, problems (strings).

## `M.remove(n)`

Remove the nth job (counting only real jobs, as `crontab list` numbers them).

## `M.now()`

Time source: { seconds = real seconds (monotonic enough), hour = in-game hour 0-24, day = in-game day number }.

## `M.due(job, now, state)`

Does `job` need to run at `now`? state is the job's memory ({ last = seconds, lastDay = n, ran = bool }) and is updated.

## `M.run(command, timeout)`

Run one command line now. Returns status, output.

## `M.tick(jobs, states, now)`

Check every job once and run those that are due. Returns the number started.

## `M.daemon()`

The crond service: re-reads the table whenever it changes.

## `M.crontab(args, io)`

crontab list | add <schedule line...> | remove <n> | run <n> | log
