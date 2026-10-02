// SPDX-License-Identifier: AGPL-3.0-or-later
// Publishes a minimal registry snapshot to Pastebin, as the backup channel for computers that cannot reach the web site.
//
//   node tools/build/pastebin.mjs --plan                       show what would be uploaded (no network, no key needed)
//   PASTEBIN_DEV_KEY=... node tools/build/pastebin.mjs [--user-key <key>] [--packages core,pkg,ui-tui] [--delay 3000]
//
// Pastebin allows few pastes per day without an account and none without an API key, and every file of a package needs a paste of its
// own, so only a SMALL set of packages is mirrored (default: the packages the installer needs: core, pkg). A snapshot paste maps the
// registry files to those pastes (see src/pkg/root/sys/lib/tsr/pkg/source.lua). Progress is kept in .scratch/pastebin-state.json so an
// interrupted run continues where it stopped. The key is read from the environment or argv, used for the API calls only and
// never written anywhere. On success tools/build/mirrors.json is updated with the snapshot id.
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { root } from '../lib/craftos.mjs';

const sha256 = (b) => createHash('sha256').update(b).digest('hex');

/** Everything that must become a paste for `packages` (plus their dependencies): [{ key, text, label }] and the snapshot index. */
export function plan(site, packages) {
  const index = JSON.parse(readFileSync(join(site, 'registry', 'index.json'), 'utf8'));
  const names = new Set();
  const visit = (n) => {
    if (names.has(n)) return;
    if (!index.packages[n]) throw new Error(`unknown package ${n}`);
    names.add(n);
    const doc = JSON.parse(readFileSync(join(site, 'registry', 'packages', `${n}.json`), 'utf8'));
    for (const dep of Object.keys(doc.versions[doc.latest].requires ?? {})) if (index.packages[dep]) visit(dep);
  };
  packages.forEach(visit);
  const items = [];
  const subIndex = { format: 1, packages: {} };
  const seen = new Set();
  const problems = [];
  for (const n of [...names].sort()) {
    subIndex.packages[n] = index.packages[n];
    const docText = readFileSync(join(site, 'registry', 'packages', `${n}.json`), 'utf8');
    items.push({ key: `packages/${n}`, text: docText, label: `package ${n}` });
    const doc = JSON.parse(docText);
    for (const f of doc.versions[doc.latest].files) {
      if (seen.has(f.sha256)) continue;
      seen.add(f.sha256);
      const buf = readFileSync(join(site, 'blobs', f.sha256));
      const text = buf.toString('utf8');
      if (!Buffer.from(text, 'utf8').equals(buf)) { problems.push(`${n}: ${f.path} is not valid UTF-8 text (Pastebin holds text only)`); continue; }
      if (sha256(Buffer.from(text, 'utf8')) !== f.sha256) { problems.push(`${n}: ${f.path} does not match its checksum`); continue; }
      items.push({ key: f.sha256, text, label: `${n} ${f.path}` });
    }
  }
  return { items, index: subIndex, names: [...names].sort(), problems };
}

/** Create one paste. Returns the paste id. fetchFn defaults to fetch. */
export async function createPaste({ endpoint, devKey, userKey, name, text, fetchFn = fetch }) {
  const body = new URLSearchParams({
    api_dev_key: devKey, api_option: 'paste', api_paste_code: text, api_paste_name: name,
    api_paste_private: '1', api_paste_expire_date: 'N',
  });
  if (userKey) body.set('api_user_key', userKey);
  const res = await fetchFn(endpoint, { method: 'POST', body });
  const answer = (await res.text()).trim();
  const m = answer.match(/pastebin\.com\/(?:raw\/)?(\w+)$/);
  if (!m) throw new Error(`Pastebin refused: ${answer.slice(0, 200)}`);
  return m[1];
}

/** Upload the plan. opts: devKey, userKey, endpoint, delay, statePath, fetchFn, log. Returns the snapshot paste id. */
export async function publish(p, opts) {
  const log = opts.log ?? (() => {});
  const statePath = opts.statePath;
  const state = existsSync(statePath) ? JSON.parse(readFileSync(statePath, 'utf8')) : { pastes: {} };
  const save = () => { mkdirSync(join(statePath, '..'), { recursive: true }); writeFileSync(statePath, JSON.stringify(state)); };
  const call = (name, text) => createPaste({ endpoint: opts.endpoint, devKey: opts.devKey, userKey: opts.userKey, name, text, fetchFn: opts.fetchFn });
  let n = 0;
  for (const item of p.items) {
    if (state.pastes[item.key]) { log(`skip ${item.label} (already uploaded)`); continue; }
    if (n++ > 0 && opts.delay) await new Promise((r) => setTimeout(r, opts.delay));
    state.pastes[item.key] = await call(`tessera ${item.label}`, item.text);
    save();
    log(`uploaded ${item.label} -> ${state.pastes[item.key]}`);
  }
  const snapshot = { index: p.index, pastes: state.pastes };
  if (opts.delay) await new Promise((r) => setTimeout(r, opts.delay));
  const id = await call('tessera snapshot', JSON.stringify(snapshot));
  state.snapshot = id;
  save();
  return id;
}

// CLI
if (process.argv[1] && process.argv[1].endsWith('pastebin.mjs')) {
  const args = process.argv.slice(2);
  const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
  const site = join(root, 'dist', 'site');
  if (!existsSync(join(site, 'registry', 'index.json'))) { console.error('dist/site not found - run tools/build/build.mjs first'); process.exit(1); }
  const p = plan(site, (opt('--packages', 'core,pkg')).split(','));
  console.log(`${p.items.length} pastes (+1 snapshot) for: ${p.names.join(', ')}`);
  for (const pr of p.problems) console.error('problem: ' + pr);
  if (p.problems.length) process.exit(1);
  if (args.includes('--plan')) {
    for (const i of p.items) console.log(`  ${String(i.text.length).padStart(7)} B  ${i.label}`);
    process.exit(0);
  }
  const devKey = process.env.PASTEBIN_DEV_KEY;
  if (!devKey) { console.error('Set PASTEBIN_DEV_KEY (your Pastebin API developer key) first, or use --plan.'); process.exit(1); }
  const id = await publish(p, {
    devKey, userKey: opt('--user-key', process.env.PASTEBIN_USER_KEY), endpoint: opt('--api', 'https://pastebin.com/api/api_post.php'),
    delay: Number(opt('--delay', 3000)), statePath: join(root, '.scratch', 'pastebin-state.json'), log: console.log,
  });
  const mirrorsPath = join(root, 'tools', 'build', 'mirrors.json');
  const mirrors = existsSync(mirrorsPath) ? JSON.parse(readFileSync(mirrorsPath, 'utf8')) : { pastebin: {} };
  mirrors.pastebin = { ...(mirrors.pastebin ?? {}), snapshot: id };
  writeFileSync(mirrorsPath, JSON.stringify(mirrors, null, 2) + '\n');
  console.log(`Snapshot paste: ${id}. Recorded in tools/build/mirrors.json; set pastebinSnapshot in tools/build/config.json and rebuild to bake it into install.lua.`);
}
