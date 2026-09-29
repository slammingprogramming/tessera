// SPDX-License-Identifier: AGPL-3.0-or-later
// Replays commits from the `private` branch onto `main` with all private paths removed.
//
//   node tools/split/sync-public.mjs          # update main from private
//   node tools/split/sync-public.mjs --check  # verify main contains no private paths (exit 1 if it does)
//
// `refs/split/synced` remembers the last private commit that has been replayed. Commits whose filtered tree is
// identical to main's tip (i.e. private-only commits) are skipped, so their messages never reach the public branch.
import { git, tryGit, privatePaths, isPrivate, repoRoot } from '../lib/git.mjs';
import { join } from 'node:path';
import { rmSync } from 'node:fs';

const PRIVATE = 'private';
const PUBLIC = 'main';
const SYNCED = 'refs/split/synced';
const EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbf2340';
const paths = privatePaths();

function publicLeaks(ref) {
  return git(['ls-tree', '-r', '--name-only', ref]).split('\n').filter((p) => p && isPrivate(p, paths));
}

if (process.argv.includes('--check')) {
  if (!tryGit(['rev-parse', '--verify', `refs/heads/${PUBLIC}`])) {
    console.log(`no ${PUBLIC} branch yet - nothing to check`);
    process.exit(0);
  }
  const history = git(['log', '--name-only', '--format=', PUBLIC]).split('\n').filter((p) => p && isPrivate(p, paths));
  const leaks = [...new Set([...publicLeaks(PUBLIC), ...history])];
  if (leaks.length) {
    console.error(`LEAK: ${PUBLIC} contains private paths:\n  ${leaks.join('\n  ')}`);
    process.exit(1);
  }
  console.log(`ok: ${PUBLIC} has no private paths in its tip or history`);
  process.exit(0);
}

if (!tryGit(['rev-parse', '--verify', `refs/heads/${PRIVATE}`])) {
  console.error(`branch ${PRIVATE} does not exist`);
  process.exit(1);
}
const base = tryGit(['rev-parse', '--verify', SYNCED]);
const range = base ? `${base}..${PRIVATE}` : PRIVATE;
const commits = git(['rev-list', '--reverse', '--first-parent', range]).split('\n').filter(Boolean);
if (!commits.length) { console.log('already in sync'); process.exit(0); }

const indexFile = join(repoRoot, '.git', 'split-index');
const env = { ...process.env, GIT_INDEX_FILE: indexFile };
let tip = tryGit(['rev-parse', '--verify', `refs/heads/${PUBLIC}`]);
let made = 0;

for (const c of commits) {
  rmSync(indexFile, { force: true });
  git(['read-tree', c], { env });
  const present = git(['ls-files'], { env }).split('\n').filter((p) => p && isPrivate(p, paths));
  if (present.length) git(['rm', '--cached', '-q', '-f', '--', ...present], { env });
  const tree = git(['write-tree'], { env });
  const tipTree = tip ? git(['rev-parse', `${tip}^{tree}`]) : null;
  if (tree === tipTree) continue;               // private-only commit
  if (!tip && tree === EMPTY_TREE) continue;    // nothing public yet
  const meta = git(['log', '-1', '--format=%an%x00%ae%x00%aI', c]).split('\0');
  const msg = git(['log', '-1', '--format=%B', c]);
  const cenv = {
    ...process.env,
    GIT_AUTHOR_NAME: meta[0], GIT_AUTHOR_EMAIL: meta[1], GIT_AUTHOR_DATE: meta[2],
  };
  tip = git(['commit-tree', tree, ...(tip ? ['-p', tip] : []), '-m', msg], { env: cenv });
  made++;
}
rmSync(indexFile, { force: true });
if (tip) git(['update-ref', `refs/heads/${PUBLIC}`, tip]);
git(['update-ref', SYNCED, commits[commits.length - 1]]);
console.log(`synced: ${made} public commit(s) from ${commits.length} private commit(s); ${PUBLIC} = ${tip ? tip.slice(0, 8) : '(none)'}`);
const leaks = tip ? publicLeaks(PUBLIC) : [];
if (leaks.length) { console.error('LEAK after sync:', leaks); process.exit(1); }
