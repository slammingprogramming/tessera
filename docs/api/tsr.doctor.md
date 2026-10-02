# tsr.doctor

Package: `doctor`

doctor: checks a Tessera computer from the inside and writes a report. It exists because most of this system was developed in an
emulator: run it in the real game (any ComputerCraft version) to find out what behaves differently, how fast the cryptography really is
on that server, and what is wrong, then send the report file to the project. The report never contains keys, passwords or user names.

  doctor                 all checks (the benchmarks take a few seconds)
  doctor --quick         skip the benchmarks and network checks
  doctor --out <file>    where the report goes (default /var/log/doctor.txt)
  doctor <check> ...     only the named checks (see `doctor --list`)

Each check returns "ok", "warn", "fail" or "skip" and a sentence of detail. A check that crashes is reported as a failure (with the error):
that is information too.

## `M.run(opts)`

Run checks. opts: only (list of ids), quick (skip slow and network checks). Returns a list of { id, title, status, detail }.

## `M.report(results)`

The report text: system line, one line per check, counts.
