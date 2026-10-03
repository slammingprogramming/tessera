# tsr.av

Package: `av`

The anti-virus engine. "Virus" in ComputerCraft means programs that harm other players' computers and servers: scripts that wipe disks, download and run unknown
code, copy themselves to floppies, switch off Ctrl+T, steal passwords or flood the network.
  local result = av.scanData(text, { path = "/disk/startup.lua" })    -- result.verdict is "clean", "suspicious" or "malicious"; result.findings tells why
  local summary = av.scanTree("/", { action = "quarantine" })
Three layers: (1) the checksum of the whole file against lists of known bad (and known good) files, (2) signature patterns from the definitions, (3) behaviour
rules (tsr.av.rules). Lists can be updated from signed definition files (tsr.av.defs). Other programs use it too: the package manager can scan what it installs
(config av.scan_packages), the mail server scans attachments (av.installMail), and the avd service scans floppies when they are inserted.

## `M.settings()`

The settings: defaults plus /etc/tsr/av/av.json.

## `M.loadDefs(force)`

The merged definitions (cached for a minute).

## `M.scanData(data, opts)`

Scan text. opts: path (the name the file will have; used for startup files), defs, settings.
Returns { verdict, score, findings = { { id, score, description, line } }, sha256, size, skipped, allowed }.

## `M.scanFile(path, opts)`

Scan a file. Returns the same table (plus path) or nil + reason.

## `M.knownFiles()`

path -> sha256 of the files that belong to installed packages (the package manager's records).

## `M.scanTree(root, opts)`

Scan a file or folder. opts: action ("report" | "quarantine" | "delete"), recursive (default true), progress(path, result), skipKnown (default true), settings.
Returns { scanned, clean, suspicious, malicious, skipped, errors, found = { result... } }.

## `M.blocks(result, strict)`

Does this scan result mean the file should be refused? (malicious always; suspicious when strict.)

## `M.describe(r)`

A one-line explanation of a result.

## `M.installMail(mail, cfg)`

Hook the scanner into a mail system (see tsr.mail): incoming mail with malware is refused, doubtful mail goes to the Spam folder with a header, and users cannot
send malware out. cfg: action ("reject" | "quarantine" | "tag").
