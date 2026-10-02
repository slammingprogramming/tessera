# Package & Registry Format (draft v0.1)

Modeled on CCPM's metadata-only registry (per-package metadata + one manifest per version listing file URLs and SHA-256).
Interop adapters for unicornpkg/CCPM/Pinestore are planned. Format is JSON (readable by `textutils.unserializeJSON`).

## Registry layout (static hosting: GitHub Pages / raw / jsDelivr)

```
index.json                       # { format, updated, serial, expires, packages: { name: {latest, summary, type, size, docSha256} } }
index.json.sig                   # { format, alg: "ed25519", keyid, sig } over the exact bytes of index.json (see SECURITY.md)
trust.json (+ .sig)              # optional: signed key updates (rotation)
packages/<name>/package.json     # name, description, author, license, homepage, type, tags, versions[]
packages/<name>/<version>.json   # manifest (below)
```

## Manifest `<version>.json`

```json
{
  "name": "integration-mekanism",
  "version": "0.1.0",
  "type": "integration",          // lib | app | driver | service | theme | profile | integration | meta
  "requires": { "core": ">=0.1", "hal-core": "*" },
  "provides": ["driver:mekanism.*"],
  "conflicts": [],
  "platforms": { "min_cc": "*", "profiles": ["server","client"], "needs": ["color?"] },
  "size": { "installed": 18342, "download": 6120 },
  "files": [
    { "path": "/usr/lib/mek/init.lua", "url": "https://.../init.lua", "sha256": "…", "mode": "lib" }
  ],
  "lazy": { "bin": { "/usr/bin/mek": "/usr/lib/mek/cli.lua" } },
  "hooks": { "post_install": "install.lua", "pre_remove": "remove.lua" },
  "license": "AGPL-3.0-or-later",   // SPDX; required
  "source": { "repo": "https://github.com/<org>/<repo>", "commit": "<sha>", "path": "src/…" },  // required (AGPL)
  "mirrors": { "pastebin": { "/usr/lib/mek/init.lua": "<paste id>" } },  // optional backup tiers
}
```

## Signatures

- `index.json.sig` is JSON: `{ "format": 1, "alg": "ed25519", "keyid": "<first 8 bytes of SHA-256(public key), hex>", "sig": "<base64>" }`.
  The signed message is `"tessera-signature-v1" 0x00 context 0x00 SHA-256(index.json bytes)`.
- `docSha256` in the index pins each package description; each description pins each file. One signature therefore covers every
  byte that is installed.
- `serial` only increases; clients remember the highest serial per source (`/var/lib/tsr/pkg/trust-state.json`) and refuse a
  smaller one. `expires` (UTC ms) bounds how long a captured index stays valid.
- Offline bundles contain the raw signed index (bundle record kind 4); Pastebin snapshots carry `indexJson` and `indexSig`.
- Keys: `/etc/tsr/trust.json` on the device, built-in keys from the build (`trustedKeys` in `tools/build/config.json`). The private key
  is generated with `node tools/build/keys.mjs gen` and kept outside the repository.

## Rules
- Every file pinned by SHA-256; installer verifies before swap; failed verification aborts the transaction.
- Types: `profile`/`meta` packages only list dependencies.
- `lazy.bin` creates stubs that fetch + cache the package on first run.
- Size fields feed the installer's storage plan; the wizard refuses/warns if the plan exceeds free space.
- Source list in `/etc/pkg/sources.d/*.json`; each source: `{name, url, priority, type: "official|community|lan|adapter"}`.
- Third-party registries are untrusted by default; the user confirms adding them; packages from them are labeled.
- Minified payloads are built by `tools/`; originals are kept in the repo, not on device. Because Tessera is AGPL-3.0,
  every manifest must link to the exact source (`source.repo` + `commit`); the build fails without it.
- **Offline bundles** (`.tsrbundle`): a single text/binary container holding the registry snapshot and/or selected
  packages. Encoded for paste as numbered chunks (`TSR1 <bundle-id> <n>/<total> <crc32> <base64-of-compressed-data>`),
  each independently verifiable, resumable, and finally checked against the SHA-256s in the manifests. Also accepted as
  a whole file via `file_transfer` drag-and-drop. Chunk size to be tuned after measuring real in-game paste limits.
