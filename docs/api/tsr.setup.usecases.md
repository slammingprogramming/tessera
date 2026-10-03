# tsr.setup.usecases

Package: `installer`

Use cases: what a computer is *for*, beyond the kind of computer it is (the profile). Each use case is a bundle of packages, services, settings and
starting files, so that a new computer can become a home router, a managed switch, a mail server, a smart-home hub or an industrial controller in one step.
  M.available(probe, profile)  the list for the wizard: { id, group, label, summary, blocked, recommended, reason }
  M.plan(id, probe, opts)      what applying it would do: { packages, services, files, config, notes }   (files are produced by apply, once the packages are there)
  M.apply(id, probe, env)      write the files that do not exist yet, set the settings, enable the services. Returns { written, kept, enabled, notes, problems }
Starting files never overwrite an existing file; generated secrets (Wi-Fi passphrase, routing key) are returned in `notes` once.

## `M.available(probe, profile)`

Use cases for the wizard. profile: the chosen profile (use cases made for other kinds of computer are blocked with a reason).

## `M.plan(id, probe, opts)`

What a use case would install and enable. opts: hostname.

## `M.apply(id, probe, env)`

Apply a use case after its packages are installed. env: vfs, config, svc (each optional; default the real modules), hostname, force.
Returns { written = {paths}, kept = {paths that existed}, enabled = {services}, notes = {text}, problems = {text} }.
