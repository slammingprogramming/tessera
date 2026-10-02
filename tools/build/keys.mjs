// SPDX-License-Identifier: AGPL-3.0-or-later
// Registry signing keys.
//
//   node tools/build/keys.mjs gen [--out <file>] [--name <text>]   create a key pair (default file: ~/.tessera/registry-signing.key)
//   node tools/build/keys.mjs show [--key <file>]                  print the public part: key id and the line for tools/build/config.json
//
// The SECRET file is the project's release credential: keep it outside the repository (the default location is in your home
// folder), back it up, and never commit it. `gen` refuses to overwrite an existing file and refuses to write inside the repo.
// The build signs the registry when it finds the key through TSR_SIGNING_KEY_FILE or config.json "signingKeyFile";
// clients trust the keys listed in config.json "trustedKeys" (public keys only; those are built into the installer and `pkg`).
// In CI, put the key file's content in a repository secret and write it to a file before building.
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute, join, resolve, relative } from 'node:path';
import { root } from '../lib/craftos.mjs';
import { generateKey, loadKey, saveKey } from '../lib/sign.mjs';

const args = process.argv.slice(2);
const cmd = args[0];
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const defaultFile = join(homedir(), '.tessera', 'registry-signing.key');

if (cmd === 'gen') {
  const out = resolve(opt('--out', defaultFile));
  const rel = relative(root, out);
  if (!rel.startsWith('..') && !isAbsolute(rel) && !rel.startsWith('.scratch')) {
    console.error('refusing to write a secret key inside the repository: ' + out);
    process.exit(1);
  }
  if (existsSync(out)) { console.error('refusing to overwrite ' + out); process.exit(1); }
  const key = generateKey(opt('--name', 'Tessera registry key'));
  saveKey(out, key);
  console.log(`wrote ${out}  (keep it secret, keep a backup)`);
  console.log(`key id: ${key.keyid}`);
  console.log('add this entry to "trustedKeys" in tools/build/config.json:');
  console.log(JSON.stringify({ name: key.name, public: key.public }));
} else if (cmd === 'show') {
  const key = loadKey(resolve(opt('--key', process.env.TSR_SIGNING_KEY_FILE ?? defaultFile)));
  console.log(`key id: ${key.keyid}`);
  console.log(JSON.stringify({ name: key.name, public: key.public }));
} else {
  console.error('usage: node tools/build/keys.mjs gen [--out file] [--name text] | show [--key file]');
  process.exit(1);
}
