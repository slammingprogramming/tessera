# tsr.setup.wizard

Package: `installer`

The setup wizard: welcome -> detect hardware -> profile -> use case -> modules -> interface -> name -> review -> install.
Everything it needs is injectable (env.ui / env.pkg / env.hw ...), which is how the tests drive it. It can be re-run
at any time to add or remove modules: installed packages start ticked, unticking one removes it.

## `M.summary(probe)`

One-screen summary lines of what the probe found.

## `M.autoUi()`

A non-interactive stand-in for the TUI: accepts every default and recommendation. Used by `tsr-setup --auto`
(unattended installs, scripting, tests). Informational screens are printed instead of shown.

## `M.run(env)`

env: ui, pkg, hw, config, importer, vfs (all optional, for tests) and auto (bool: unattended, no reboot).
