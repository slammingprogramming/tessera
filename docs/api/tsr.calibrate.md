# tsr.calibrate

Package: `calibrate`

Measures the limits of the ComputerCraft setup Tessera is running on. Several limits are not documented and differ between
versions and server configurations; the measurements decide chunk sizes and fallbacks (offline paste installs, file drops, the
sandbox). Run `tsr-calibrate` in the game and send /var/log/calibration.json (or the printed summary) to the developers.
  tsr-calibrate            everything that needs no help from you
  tsr-calibrate paste      asks you to paste a long line (make one with: node tools/dev/calibration-text.mjs 4000)
  tsr-calibrate files      asks you to drop a file onto the terminal

## `M.features()`

Which language and library features exist. Returns { name = true|false }.

## `M.facts()`

Basic facts about this computer.

## `M.yieldLimit(cap)`

How long can a program run without yielding before CC stops it? Runs a busy loop for at most `cap` seconds. Returns
{ limited = bool, seconds = n, message = text|nil }. The default cap is 12 s: CC's limit is about 7 s.

## `M.network()`

Network facts without making a request.

## `M.pasteText(length)`

The text the player should paste: `length` characters in lines-free form with a checksum-able pattern.

## `M.checkPaste(received, expectedLength)`

Check what arrived against what was sent. Returns { received, expected, intact (matches a prefix), truncated }.

## `M.measurePaste(expectedLength, pull)`

Wait for a paste event and report. `pull` is replaceable for tests. Returns the check result.

## `M.measureFiles(pull)`

Wait for a file_transfer event. Returns { files = { {name, size} ... } }.

## `M.collect(only, opts)`

Run the automatic probes (and the interactive ones named in `only`). Returns the report table.
