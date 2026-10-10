# tsr.pkg.pasteref

Package: `pkg`

Reading the Pastebin mirror. Every file of the registry is its own paste (so a program can be fetched with `pastebin get`), and a "snapshot" paste says which
paste holds what. A file that is too long for one paste (or is not text) is stored in several pastes; a *reference* names them:
    "abc123"            one paste, the text itself
    "abc123+def456"     several pastes, joined in this order
    "b64:abc123+def456" the joined text is base64 of the file (binary files, or very long ones)
Snapshot (format 2):  { format = 2, index = ref, indexSig = ref, trust = ref, trustSig = ref, docs = { [package] = ref }, blobs = { [sha256] = ref }, installer = ref }
Snapshot (format 1, older):  { indexJson, indexSig, pastes = { ["packages/<name>"] = id, [sha256] = id } }
`getter(id)` fetches the raw text of one paste (nil + reason on failure). The package manager and the bootstrap installer share this code.

## `M.parse(ref)`

Split a reference string into { ids = {...}, b64 = bool } (nil for anything that is not a reference).

## `M.fetch(ref, getter)`

The content a reference points to. Returns the data, or nil + reason.

## `M.read(snap, rel, getter)`

A registry file ("registry/index.json", "registry/packages/x.json", "blobs/<sha>" ...) from a snapshot table.

## `M.loadSnapshot(ref, getter)`

Load and parse the snapshot named by `ref` (an id, or several joined with +). Returns the table, or nil + reason.
