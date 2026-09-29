// SPDX-License-Identifier: AGPL-3.0-or-later
// Helpers for locating CraftOS-PC and assembling an emulated computer from package overlays.
import { cpSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

export const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

export function findCraftOS() {
  const cands = [
    process.env.TSR_CRAFTOS,
    'C:\\Program Files\\CraftOS-PC\\CraftOS-PC_console.exe',
    'C:\\Program Files (x86)\\CraftOS-PC\\CraftOS-PC_console.exe',
    '/usr/local/bin/craftos',
    '/usr/bin/craftos',
  ].filter(Boolean);
  return cands.find((p) => existsSync(p)) ?? null;
}

/** Names of all packages under src/ (directories that contain a package.json). */
export function packageNames() {
  const srcDir = join(root, 'src');
  return readdirSync(srcDir).filter((d) => existsSync(join(srcDir, d, 'package.json'))).sort();
}

/** Copy every package overlay (src/<pkg>/root/**) onto `dest`, in package-name order. `only` restricts packages. */
export function installOverlays(dest, only = null) {
  const srcDir = join(root, 'src');
  for (const pkg of packageNames()) {
    if (only && !only.includes(pkg)) continue;
    const overlay = join(srcDir, pkg, 'root');
    if (existsSync(overlay)) cpSync(overlay, dest, { recursive: true });
  }
}
