# tsr.av.rules

Package: `av`

What the scanner looks for in a Lua program: behaviours that harm other players' computers or servers. Each rule has an id, a score and a test; a program's score
is the sum of the rules that fire (each counted once). Rules are about *what the code does* (wipes the disk, downloads and runs unknown code, copies itself to
floppies, disables Ctrl+T, sends passwords out ...), not about names, so they also catch new variants. Scores: 5 and above = suspicious, 10 and above = malicious.

These are heuristics: they find the usual mischief written by players and by copy-pasted "free op" scripts. They cannot find everything and a determined author
can hide from them; the sandbox package is the protection for code you do not trust.

## `M.strip(src)`

Remove comments (keeps strings, keeps line breaks so that line numbers stay right).

## `M.entropy(s)`

Shannon entropy (bits per character) of a string.

## `M.looksLikeLua(data)`

Does the text look like Lua source (so the behaviour rules make sense)?

## `M.run(code, path)`

Run all rules over a prepared source. Returns a list of findings { id, score, description, line } and the total score.
