// SPDX-License-Identifier: AGPL-3.0-or-later
// Tiny helpers around the git CLI (no dependencies).
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
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

function readList(file) {
  const path = join(repoRoot, 'tools', 'split', file);
  if (!existsSync(path)) return null;
  return readFileSync(path, 'utf8').split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
}

/** Parse tools/split/private-paths.txt into a list of prefixes. */
export function privatePaths() {
  return readList('private-paths.txt') ?? [];
}

/** Paths allowed on GitHub at the current stage, or null when the stage is unrestricted (no allowlist entries). */
export function githubAllow() {
  const list = readList('github-allow.txt');
  return list && list.length ? list : null;
}

function matches(path, list) {
  return list.some((p) => (p.endsWith('/') ? path.startsWith(p) : path === p));
}

/** True when `path` (repo-relative, forward slashes) is private. */
export function isPrivate(path, paths = privatePaths()) {
  return matches(path, paths);
}

/** True when `path` may be published on GitHub now (never true for private paths). */
export function isGithubAllowed(path, allow = githubAllow(), priv = privatePaths()) {
  if (matches(path, priv)) return false;
  return allow === null ? true : matches(path, allow);
}

/** The Co-Authored-By trailer every commit made by the AI assistant must carry. */
export const CO_AUTHOR = 'Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>';
