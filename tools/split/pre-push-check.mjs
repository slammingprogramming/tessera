// SPDX-License-Identifier: AGPL-3.0-or-later
// git pre-push guard (called by .githooks/pre-push).  argv: <remote-name> <remote-url>; stdin: git's ref list.
// Rules for the public remote (name "github" or a github.com URL):
//   * never the `private` branch, never a private path (tools/split/private-paths.txt);
//   * while tools/split/github-allow.txt has entries (documentation-only stage), nothing outside that allowlist —
//     in the pushed tip or anywhere in the pushed history. Source code cannot reach GitHub by accident.
import { readFileSync } from 'node:fs';
import { git, tryGit, privatePaths, githubAllow, isGithubAllowed } from '../lib/git.mjs';

const [remote = '', url = ''] = process.argv.slice(2);
const isPublic = remote === 'github' || /github\.com/i.test(url);
if (!isPublic) process.exit(0);

const priv = privatePaths();
const allow = githubAllow();
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
  const leaks = [...files].filter((f) => !isGithubAllowed(f, allow, priv));
  if (leaks.length) {
    const why = allow ? 'not on the GitHub allowlist (tools/split/github-allow.txt) or private' : 'private';
    console.error(`tessera: refusing to push '${localRef}' to public remote '${remote}'; paths ${why}:\n  ${leaks.slice(0, 25).join('\n  ')}${leaks.length > 25 ? `\n  ... and ${leaks.length - 25} more` : ''}`);
    bad = true;
  }
}
process.exit(bad ? 1 : 0);
