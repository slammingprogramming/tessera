// SPDX-License-Identifier: AGPL-3.0-or-later
// Configure remotes for the split-branch workflow.
//   node tools/split/setup-remotes.mjs --github <url> [--keybase <url>]
// github  <- main only            (refs/heads/main:refs/heads/main)
// keybase <- private as its main  (refs/heads/private:refs/heads/main) + public mirror (refs/heads/main:refs/heads/public)
import { git, tryGit } from '../lib/git.mjs';

const args = process.argv.slice(2);
const get = (flag) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : null; };
const gh = get('--github');
const kb = get('--keybase');
if (!gh && !kb) {
  console.error('usage: setup-remotes.mjs --github <url> [--keybase <url>]');
  process.exit(2);
}

function setRemote(name, url, pushRefspecs) {
  if (tryGit(['remote', 'get-url', name])) git(['remote', 'set-url', name, url]);
  else git(['remote', 'add', name, url]);
  tryGit(['config', '--unset-all', `remote.${name}.push`]);
  for (const r of pushRefspecs) git(['config', '--add', `remote.${name}.push`, r]);
  console.log(`remote ${name} -> ${url}\n  push: ${pushRefspecs.join(', ')}`);
}

git(['config', 'core.hooksPath', '.githooks']);
if (gh) setRemote('github', gh, ['refs/heads/main:refs/heads/main']);
if (kb) setRemote('keybase', kb, ['refs/heads/private:refs/heads/main', 'refs/heads/main:refs/heads/public']);
