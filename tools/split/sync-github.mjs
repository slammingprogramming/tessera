// SPDX-License-Identifier: AGPL-3.0-or-later
// Builds the local `github` branch: the tip of `private` reduced to the paths listed in tools/split/github-allow.txt,
// as ONE new signed commit whenever that reduced tree changed (so the code's commit history never reaches GitHub).
//
//   node tools/split/sync-github.mjs [--message "Update documentation"] [--check]
//
// --check verifies that the existing `github` branch (tip and every commit) contains only allowed paths.
// Commits are signed (-S) with whatever gpg.format/user.signingkey the repository is configured with (ssh-agent key) and
// carry the Co-Authored-By trailer; author and committer come from the repository config (the GitHub no-reply address).
import { git, tryGit, githubAllow, isGithubAllowed, privatePaths, repoRoot, CO_AUTHOR } from '../lib/git.mjs';
import { join } from 'node:path';
import { rmSync } from 'node:fs';

const SOURCE = 'private';
const TARGET = 'github';
const EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbf2340';
const args = process.argv.slice(2);
const allow = githubAllow();
const priv = privatePaths();

if (!allow) {
  console.error('tools/split/github-allow.txt has no entries: the GitHub stage is unrestricted, use sync-public.mjs instead');
  process.exit(1);
}
const bad = (ref) => {
  const files = new Set(git(['log', '--name-only', '--format=', ref]).split('\n').filter(Boolean));
  for (const f of git(['ls-tree', '-r', '--name-only', ref]).split('\n').filter(Boolean)) files.add(f);
  return [...files].filter((f) => !isGithubAllowed(f, allow, priv));
};

if (args.includes('--check')) {
  if (!tryGit(['rev-parse', '--verify', `refs/heads/${TARGET}`])) { console.log(`no ${TARGET} branch yet`); process.exit(0); }
  const leaks = bad(TARGET);
  if (leaks.length) { console.error(`LEAK: ${TARGET} contains paths that are not allowed on GitHub:\n  ${leaks.join('\n  ')}`); process.exit(1); }
  console.log(`ok: ${TARGET} contains only allowed paths (tip and history)`);
  process.exit(0);
}

const mi = args.indexOf('--message');
const subject = mi >= 0 ? args[mi + 1] : 'Update documentation';

const indexFile = join(repoRoot, '.git', 'github-index');
const env = { ...process.env, GIT_INDEX_FILE: indexFile };
rmSync(indexFile, { force: true });
git(['read-tree', SOURCE], { env });
const drop = git(['ls-files'], { env }).split('\n').filter((p) => p && !isGithubAllowed(p, allow, priv));
if (drop.length) git(['rm', '--cached', '-q', '-f', '--', ...drop], { env });
const tree = git(['write-tree'], { env });
rmSync(indexFile, { force: true });

const tip = tryGit(['rev-parse', '--verify', `refs/heads/${TARGET}`]);
const tipTree = tip ? git(['rev-parse', `${tip}^{tree}`]) : null;
if (tree === tipTree) { console.log('github branch already up to date'); process.exit(0); }
if (tree === EMPTY_TREE) { console.error('nothing allowed to publish'); process.exit(1); }

const message = `${subject}\n\n${CO_AUTHOR}\n`;
const commit = git(['commit-tree', '-S', tree, ...(tip ? ['-p', tip] : []), '-m', message]);
git(['update-ref', `refs/heads/${TARGET}`, commit]);
const leaks = bad(TARGET);
if (leaks.length) { console.error('LEAK after sync:', leaks); process.exit(1); }
console.log(`${TARGET} = ${commit.slice(0, 8)} (${git(['ls-tree', '-r', '--name-only', TARGET]).split('\n').length} files, signed)`);
