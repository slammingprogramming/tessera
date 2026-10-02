# tsr.vault

Package: `vault`

Encrypted volumes ("vaults"), like BitLocker, FileVault or LUKS+ext4 on a game computer: a folder that holds only ciphertext, and a
mount point where, after the passphrase, you see ordinary files. Close it (or reboot) and nothing readable is left on disk.

On disk (folder <dir>):
  vault.json   header: PBKDF2-SHA256 salt and iteration count, the 64-byte master key sealed (ChaCha20-Poly1305) under the key derived
               from the passphrase, and optionally a second copy sealed under a random RECOVERY KEY shown once at creation
  index.enc    the file tree (names, directories, which data file holds what), encrypted: names and structure are hidden
  d/<id>       one file per vault file, 4 KB chunks each sealed with its own nonce; the chunk's AAD binds it to the file id, its position
               and whether it is the last chunk, so chunks cannot be swapped between files, reordered or cut off
A changed file is written under a NEW id first and only then does the index point to it: a crash leaves the old content or the new one,
never half of each (orphaned data files are removed at the next open). Visible to an attacker with the disk: that a vault exists, how many
files it holds and their sizes. The decrypted tree lives in memory while mounted, so the vault should stay small (a few hundred KB).

  local v = vault.create("/safe", "passphrase")      -> vault, recoveryKey
  local v = vault.open("/safe", "passphrase")        -- or the recovery key
  v:mount("/secret")   ...   v:unmount()

## `M.create(dir, passphrase, opts)`

Create a new vault in the (empty or new) folder `dir`. opts: iterations, recovery (default true). Returns the vault, and the recovery key text.

## `M.open(dir, secret)`

Open an existing vault with its passphrase or recovery key. Returns the vault or nil + reason.

## `Vault:collectGarbage()`

Remove data files that the index does not know (left by a crash between writing data and updating the index).

## `Vault:readPlain(path)`

Read one file's plaintext (nil + reason when it is missing or fails authentication).

## `Vault:writePlain(path, plain)`

Store a file's plaintext under a fresh id, point the index at it, remove the old data file.

## `Vault:changePassphrase(newPassphrase)`

Change the passphrase (the master key stays, so the data files need no re-encryption). Returns true or nil + reason.

## `Vault:provider(capacity)`

The decrypted file system as a VFS provider: a RAM file system that writes every change through to the encrypted store.

## `Vault:mount(path, capacity)`

Mount the decrypted file system at `path`.
