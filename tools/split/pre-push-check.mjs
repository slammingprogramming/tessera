// SPDX-License-Identifier: AGPL-3.0-or-later
// git pre-push guard (called by .githooks/pre-push).  argv: <remote-name> <remote-url>; stdin: git's ref list.
// Rule: the public remote (name "github" or a github.com URL) may only receive refs whose pushed history contains
// no private path, and never the `private` branch.
import { readFileSync } from 'node:fs';
import { git, tryGit, privatePaths, isPrivate } from '../lib/git.mjs';

const [remote = '', url = ''] = process.argv.slice(2);
const isPublic = remote === 'github' || /github\.com/i.test(url);
if (!isPublic) process.exit(0);

const paths = privatePaths();
const ZERO = /^0+$/;
let bad = false;
for (const line of readFileSync(0, 'utf8').split('\n').filter(Boolean)) {
  const [localRef, localSha, remoteRef, remoteSha] = line.split(' ');
  if (ZERO.test(localSha)) continue; // deleting a ref is fine
  if (/(^|\/)private$/.test(localRef) || /(^|\/)private$/.test(remoteRef)) {
    console.error(`tessera: refusing to push '${localRef}' to public remote '${remote}' (private branch)`);
    bad = true;
    continue;
  }
  const range = ZERO.test(remoteSha) ? localSha : `${remoteSha}..${localSha}`;
  const files = new Set(git(['log', '--name-only', '--format=', range]).split('\n').filter(Boolean));
  for (const f of tryGit(['ls-tree', '-r', '--name-only', localSha])?.split('\n') ?? []) files.add(f);
  const leaks = [...files].filter((f) => isPrivate(f, paths));
  if (leaks.length) {
    console.error(`tessera: refusing to push '${localRef}' to public remote '${remote}'; private paths present:\n  ${leaks.join('\n  ')}`);
    bad = true;
  }
}
process.exit(bad ? 1 : 0);
