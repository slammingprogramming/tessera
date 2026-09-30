// SPDX-License-Identifier: AGPL-3.0-or-later
// Scaffold a Tessera app package.
//
//   node tools/dev/new-app.mjs <package> --desc "..." [--cmds cmd1,cmd2] [--module tsrapps/name] [--requires a,b]
//                              [--type app|lib|meta] [--turtle] [--budget N]
//
// Creates src/<package>/package.json and, for each command, src/<package>/root/usr/bin/<cmd>.lua: a two-line launcher
// that loads the module `tsrapps.<module>` through the shared loader and calls `main` (or `<cmd>` when the module
// exports one per command, see --per-command). The module itself (src/<package>/root/usr/lib/tsrapps/<name>.lua) is
// yours to write; an empty skeleton is created if it does not exist.
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { root } from '../lib/craftos.mjs';

const args = process.argv.slice(2);
const name = args[0];
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const flag = (n) => args.includes(n);
if (!name || name.startsWith('--') || !opt('--desc')) {
  console.error('usage: new-app.mjs <package> --desc "..." [--cmds a,b] [--module name] [--requires a,b] [--type app|lib|meta] [--turtle] [--per-command]');
  process.exit(2);
}

const dir = join(root, 'src', name);
if (existsSync(join(dir, 'package.json'))) { console.error(`src/${name} already has a package.json`); process.exit(1); }
const cmds = (opt('--cmds', name) || '').split(',').filter(Boolean);
const module = opt('--module', name);
const type = opt('--type', 'app');
const requires = { core: '>=0.1.0' };
for (const r of (opt('--requires', '') || '').split(',').filter(Boolean)) requires[r] = '>=0.1.0';

const pkg = {
  name, version: '0.1.0', type, description: opt('--desc'), license: 'AGPL-3.0-or-later', requires,
  ...(flag('--turtle') ? { platforms: { profiles: ['turtle'] } } : {}),
  budget: Number(opt('--budget', 16000)),
};
mkdirSync(join(dir, 'root', 'usr', 'bin'), { recursive: true });
mkdirSync(join(dir, 'root', 'usr', 'lib', 'tsrapps'), { recursive: true });
writeFileSync(join(dir, 'package.json'), JSON.stringify(pkg, null, 2) + '\n');

if (type !== 'meta') {
  for (const cmd of cmds) {
    const call = flag('--per-command') ? cmd : 'main';
    writeFileSync(join(dir, 'root', 'usr', 'bin', `${cmd}.lua`), [
      '-- SPDX-License-Identifier: AGPL-3.0-or-later',
      'local req = (rawget(_G, "tsr") and tsr.require) or dofile("/sys/lib/tsr/loader.lua").require',
      `return req("tsrapps.${module}").${call}({ ... })`,
      '',
    ].join('\n'));
  }
  const modPath = join(dir, 'root', 'usr', 'lib', 'tsrapps', `${module}.lua`);
  if (!existsSync(modPath)) {
    writeFileSync(modPath, [
      '-- SPDX-License-Identifier: AGPL-3.0-or-later',
      `-- ${name}: ${opt('--desc')}`,
      'local M = {}',
      '',
      'function M.main(args, io)',
      '  return true',
      'end',
      '',
      'return M',
      '',
    ].join('\n'));
  }
}
console.log(`created src/${name} (${type}); commands: ${type === 'meta' ? '-' : cmds.join(', ')}`);
