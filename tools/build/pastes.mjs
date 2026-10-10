// SPDX-License-Identifier: AGPL-3.0-or-later
// Manages the Pastebin mirror of the registry and the installer (see tools/lib/pastes.mjs for how it works).
//
//   node tools/build/pastes.mjs plan                  what would be created (no network, no key)
//   node tools/build/pastes.mjs status                what is on Pastebin, how much of the daily budget is used
//   node tools/build/pastes.mjs sync    --confirm-public     create the pastes that are missing or changed, within the rate limit; run it again later to continue
//   node tools/build/pastes.mjs publish --confirm-public     snapshot + installer paste, verification, docs/PASTEBIN.md, config; then prune
//   node tools/build/pastes.mjs verify                read every paste back and compare
//   node tools/build/pastes.mjs prune [--yes]         delete retired pastes that no recent snapshot needs (needs the account)
//   node tools/build/pastes.mjs adopt                 rebuild the state file from the account's list of pastes
//
// Options: --packages all|core,pkg,...   --limit N (pastes per 24 h, default 20)   --delay ms (default 3000)   --max N (stop after N pastes this run)
//          --keep N (generations kept, default 2)   --state <file>   --key-file <json>   --no-build
// Secrets: PASTEBIN_DEV_KEY (required to talk to Pastebin), PASTEBIN_USER + PASTEBIN_PASSWORD (to delete and to list; also makes the pastes belong to your account),
//          or PASTEBIN_USER_KEY. A --key-file outside the repository may hold { "devKey", "user", "password" }. Nothing is written anywhere.
// Everything uploaded is PUBLIC and contains the source code of the packages: --confirm-public says you know.
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { root } from '../lib/craftos.mjs';
import * as P from '../lib/pastes.mjs';

const args = process.argv.slice(2);
const command = args[0];
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const flag = (n) => args.includes(n);

const site = join(root, 'dist', 'site');
const statePath = opt('--state', join(root, 'tools', 'build', 'pastes.json'));
const configPath = join(root, 'tools', 'build', 'config.json');
const mirrorsPath = join(root, 'tools', 'build', 'mirrors.json');

function usage() {
  console.log(readFileSync(new URL(import.meta.url), 'utf8').split('\n').filter((l) => l.startsWith('//')).map((l) => l.slice(3)).join('\n'));
}
if (!command || command === 'help' || flag('--help')) { usage(); process.exit(0); }

if (!existsSync(join(site, 'registry', 'index.json'))) { console.error('dist/site not found - run node tools/build/build.mjs first'); process.exit(1); }

const packages = opt('--packages', 'all');
const p = P.plan(site, { packages: packages === 'all' ? 'all' : packages.split(',') });
const state = P.loadState(statePath);
const save = () => P.saveState(statePath, state);
const limit = Number(opt('--limit', P.DEFAULTS.limit));
const delay = Number(opt('--delay', P.DEFAULTS.delay));
const keep = Number(opt('--keep', P.DEFAULTS.keep));
const when = (t) => new Date(t).toLocaleString();

function secrets() {
  let file = {};
  const kf = opt('--key-file');
  if (kf) file = JSON.parse(readFileSync(kf, 'utf8'));
  else if (existsSync(join(homedir(), '.tessera', 'pastebin.json'))) file = JSON.parse(readFileSync(join(homedir(), '.tessera', 'pastebin.json'), 'utf8'));
  return {
    devKey: process.env.PASTEBIN_DEV_KEY ?? file.devKey,
    userKey: process.env.PASTEBIN_USER_KEY ?? file.userKey,
    user: process.env.PASTEBIN_USER ?? file.user,
    password: process.env.PASTEBIN_PASSWORD ?? file.password,
  };
}

async function connect({ needUser = false } = {}) {
  const s = secrets();
  if (!s.devKey) { console.error('Set PASTEBIN_DEV_KEY (your Pastebin API developer key; see https://pastebin.com/doc_api).'); process.exit(1); }
  const api = new P.Pastebin({ devKey: s.devKey, userKey: s.userKey });
  if (!s.userKey && s.user && s.password) { await api.login(s.user, s.password); console.log(`logged in as ${s.user}`); }
  if (needUser && !api.userKey) { console.error('This needs your Pastebin account: set PASTEBIN_USER and PASTEBIN_PASSWORD (or PASTEBIN_USER_KEY).'); process.exit(1); }
  if (!api.userKey) console.log('note: no account given - pastes are created as a guest (smaller daily limit) and cannot be deleted by this tool later.');
  return api;
}

function requireConfirm() {
  if (!flag('--confirm-public')) {
    console.error('Everything here becomes PUBLIC on pastebin.com, including the source code of every package. Add --confirm-public when you really want that.');
    process.exit(1);
  }
}

function report(d) {
  console.log(`${p.items.length} items for ${p.names.length} package(s): ${d.new.length} new, ${d.changed.length} changed, ${d.unchanged.length} up to date, ${d.removed.length} no longer wanted`);
  console.log(`${d.upload} paste(s) to create (${(d.bytes / 1024).toFixed(0)} KB)`);
  const slot = P.nextSlot(state, limit);
  const used = P.usedInLast24h(state).length;
  console.log(`budget: ${used} of ${limit} pastes used in the last 24 hours${slot > Date.now() ? `; the next one is possible at ${when(slot)}` : ''}`);
  if (d.upload > 0) {
    const free = Math.max(0, limit - used);
    const days = Math.ceil(Math.max(0, d.upload - free) / limit);
    console.log(`at ${limit} per day that takes ${days === 0 ? 'today' : `${days + 1} day(s)`} (${Math.ceil(d.upload * delay / 1000 / 60)} minutes of calls)`);
  }
}

for (const pr of p.problems) console.error('problem: ' + pr);
if (p.problems.length) process.exit(1);

if (command === 'plan') {
  const d = P.diff(p, state);
  report(d);
  if (flag('--list')) for (const i of p.items) console.log(`  ${String(i.buf.length).padStart(8)} B  ${i.parts.length > 1 ? `${i.parts.length} parts ` : ''}${i.enc ? 'b64 ' : ''}${i.label}${P.missingParts(i, state).length ? '' : '  (done)'}`);
  const multi = p.items.filter((i) => i.parts.length > 1 || i.enc);
  console.log(`${multi.length} item(s) need several pastes or base64`);
  process.exit(0);
}

if (command === 'status') {
  report(P.diff(p, state));
  const g = state.generations[0];
  console.log(g ? `published: generation ${g.gen} (${g.at}); snapshot ${g.snapshot}; installer ${g.installer}` : 'not published yet');
  console.log(`${state.retired.length} retired paste(s), ${P.prunable(state, keep).length} ready to delete`);
  process.exit(0);
}

const ctxBase = (api) => ({ api, state, save, log: console.log, limit, delay });

if (command === 'sync') {
  requireConfirm();
  const api = await connect();
  const max = opt('--max');
  const r = await P.sync(p, { ...ctxBase(api), max: max === undefined ? undefined : Number(max) });
  console.log(`${r.created} paste(s) created this run`);
  if (!r.done) {
    console.log(`not finished: ${r.remaining} paste(s) still to create${r.until ? `; run this again after ${when(r.until)}` : '; run it again to continue'}${r.reason ? ` (${r.reason})` : ''}`);
    process.exit(75);
  }
  console.log('everything is on Pastebin. Next: node tools/build/pastes.mjs publish --confirm-public');
  process.exit(0);
}

if (command === 'publish') {
  requireConfirm();
  const api = await connect();
  const d = P.diff(p, state);
  if (d.upload > 0) {
    console.error(`${d.upload} paste(s) are still missing: run sync first.`);
    process.exit(1);
  }
  const result = await P.publish(p, {
    ...ctxBase(api),
    afterSnapshot: async (ref) => {
      // bake the snapshot id into the installer: config -> rebuild -> the installer item
      const cfg = JSON.parse(readFileSync(configPath, 'utf8'));
      cfg.pastebinSnapshot = ref;
      writeFileSync(configPath, JSON.stringify(cfg, null, 2) + '\n');
      if (!flag('--no-build')) {
        console.log('rebuilding the site with the snapshot id ...');
        const r = spawnSync(process.execPath, [join(root, 'tools', 'build', 'build.mjs')], { cwd: root, stdio: 'inherit' });
        if (r.status !== 0) throw new Error('the build failed');
      }
      return P.installerItem(site);
    },
  });
  console.log(`snapshot ${result.snapshot}, installer ${result.installer} (generation ${result.generation})`);
  const mirrors = existsSync(mirrorsPath) ? JSON.parse(readFileSync(mirrorsPath, 'utf8')) : { pastebin: {} };
  mirrors.pastebin = { ...(mirrors.pastebin ?? {}), snapshot: result.snapshot, installer: result.installer };
  writeFileSync(mirrorsPath, JSON.stringify(mirrors, null, 2) + '\n');
  writeFileSync(join(root, 'docs', 'PASTEBIN.md'), P.renderDoc(state, {}));
  console.log('wrote tools/build/mirrors.json and docs/PASTEBIN.md');
  if (!flag('--no-verify')) {
    console.log('reading everything back ...');
    const snapText = JSON.stringify(P.buildSnapshot(p, state).snapshot);
    const problems = await P.verify(p, state, api, { delay: 500, installer: P.installerItem(site), snapshotText: snapText });
    for (const pr of problems) console.error('verify: ' + pr);
    if (problems.length) process.exit(1);
    console.log('all pastes read back identical');
  }
  if (api.userKey) {
    const r = await P.prune(state, api, { keep, delay: 1000, save, log: console.log });
    console.log(`${r.deleted.length} old paste(s) deleted${r.failed.length ? `, ${r.failed.length} failed` : ''}`);
  } else {
    console.log(`${P.prunable(state, keep).length} old paste(s) could be deleted, but that needs your account (prune).`);
  }
  console.log('Commit tools/build/pastes.json, tools/build/mirrors.json and tools/build/config.json (private branch); docs/PASTEBIN.md goes to GitHub with the docs.');
  process.exit(0);
}

if (command === 'verify') {
  const api = new P.Pastebin({ devKey: 'none' });
  const g = state.generations[0];
  const snap = g ? JSON.stringify(P.buildSnapshot(p, state).snapshot) : undefined;
  const problems = await P.verify(p, state, api, { delay: 500, installer: existsSync(join(site, 'install.lua')) && state.items.installer ? P.installerItem(site) : undefined, snapshotText: snap });
  for (const pr of problems) console.error('verify: ' + pr);
  console.log(problems.length ? `${problems.length} problem(s)` : 'all pastes read back identical');
  process.exit(problems.length ? 1 : 0);
}

if (command === 'prune') {
  const list = P.prunable(state, keep);
  console.log(`${list.length} retired paste(s) are no longer referenced by the last ${keep} snapshot generation(s)`);
  for (const r of list) console.log(`  ${r.id}  ${r.label}`);
  if (!flag('--yes')) { console.log('add --yes to delete them'); process.exit(0); }
  const api = await connect({ needUser: true });
  const r = await P.prune(state, api, { keep, delay: 1000, save, log: console.log });
  console.log(`${r.deleted.length} deleted, ${r.failed.length} failed`);
  process.exit(r.failed.length ? 1 : 0);
}

if (command === 'adopt') {
  const api = await connect({ needUser: true });
  const n = await P.adopt(p, state, api);
  save();
  console.log(`${n} item(s) recognised from the account's pastes`);
  process.exit(0);
}

console.error(`unknown command ${command}`);
usage();
process.exit(1);
