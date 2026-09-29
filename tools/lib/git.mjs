// SPDX-License-Identifier: AGPL-3.0-or-later
// Tiny helpers around the git CLI (no dependencies).
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, '..', '..');

export function git(args, opts = {}) {
  return execFileSync('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    maxBuffer: 256 * 1024 * 1024,
    ...opts,
  }).replace(/\r?\n$/, '');
}

export function tryGit(args, opts) {
  try { return git(args, opts); } catch { return null; }
}

/** Parse tools/split/private-paths.txt into a list of prefixes. */
export function privatePaths() {
  const text = readFileSync(join(repoRoot, 'tools', 'split', 'private-paths.txt'), 'utf8');
  return text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
}

/** True when `path` (repo-relative, forward slashes) is private. */
export function isPrivate(path, paths = privatePaths()) {
  return paths.some((p) => (p.endsWith('/') ? path.startsWith(p) : path === p));
}
