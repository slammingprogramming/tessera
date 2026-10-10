// SPDX-License-Identifier: AGPL-3.0-or-later
// The paste manager: keeps a Pastebin mirror of everything that is officially packaged — the installer, the signed registry, every package document and every file.
//
//   * one paste per file (so a program can be fetched with `pastebin get`), one per package document, one each for the registry index and its signature;
//   * a file that does not fit in one paste (or is not text) is split over several pastes; a reference like "abc+def" or "b64:abc+def" names them (see tsr.pkg.pasteref);
//   * a state file remembers what is already there (by SHA-256 of every part), so a run uploads only what is new or changed;
//   * the work is rate-limit aware: a daily budget, a pause between calls, back-off on errors, and a clean stop (state saved) when Pastebin says "enough" — run it again later;
//   * a "snapshot" paste says which paste holds what; the installer paste carries the id of the snapshot. Pastes are PUBLIC (they do not count against the limits of
//     private and unlisted pastes).
//
// Pastebin's API cannot edit a paste. An update therefore creates a new paste for exactly the parts that changed; the old ones are *retired* and deleted by `prune` once no recent
// snapshot refers to them (computers that still hold an older installer keep working for that long). Deleting needs the account (user key) that created the pastes.
//
// Secrets (developer key, account name and password) come from the environment or a key file outside the repository and are never written anywhere.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';

export const sha256 = (b) => createHash('sha256').update(b).digest('hex');

export const DEFAULTS = {
  chunk: 400_000,            // bytes per paste (Pastebin allows 512 KB for guests and free accounts)
  delay: 3000,               // ms between calls
  limit: 20,                 // pastes per rolling 24 hours (free account: 20; guests: 10; Pro: much more)
  keep: 2,                   // snapshot generations whose pastes are kept (the current one and the one before)
  endpoint: 'https://pastebin.com/api/api_post.php',
  loginEndpoint: 'https://pastebin.com/api/api_login.php',
  rawBase: 'https://pastebin.com/raw/',
};

const DAY = 24 * 3600 * 1000;

/** Packages that the installer and a first boot need come first, so a half-seeded mirror already works for the basics. */
export const BASE_ORDER = ['core', 'crypto', 'pkg', 'installer', 'ui-tui', 'shell'];

export class RateLimited extends Error {
  /** afterMs: how long to wait; `until` is that from now (a caller with its own clock sets it again). */
  constructor(message, afterMs) { super(message); this.name = 'RateLimited'; this.afterMs = afterMs; this.until = Date.now() + afterMs; }
}

// ------------------------------------------------------------------------------------------------------------------
// Splitting content into pastes
// ------------------------------------------------------------------------------------------------------------------

const decoder = new TextDecoder('utf-8', { fatal: true });

/** The content as text if Pastebin can hold it as it is (valid UTF-8, no control characters but tab/newline/return), else null. */
export function asText(buf) {
  let text;
  try { text = decoder.decode(buf); } catch { return null; }
  // eslint-disable-next-line no-control-regex
  if (/[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(text)) return null;
  return text;
}

/** Cut text into pieces of at most `chunk` bytes at line ends; null when a single line is longer than that. */
function splitLines(text, chunk) {
  const parts = [];
  let cur = '', curBytes = 0;
  for (const line of text.split(/(?<=\n)/)) {
    const n = Buffer.byteLength(line);
    if (n > chunk) return null;
    if (curBytes + n > chunk) { parts.push(cur); cur = ''; curBytes = 0; }
    cur += line;
    curBytes += n;
  }
  if (cur !== '' || parts.length === 0) parts.push(cur);
  return parts;
}

/** How a file becomes pastes: { enc: undefined | 'b64', texts: [string] }. Plain text stays plain (runnable programs); the rest is base64. */
export function toParts(buf, chunk = DEFAULTS.chunk) {
  const text = asText(buf);
  if (text !== null) {
    if (Buffer.byteLength(text) <= chunk) return { enc: undefined, texts: [text] };
    const parts = splitLines(text, chunk);
    if (parts) return { enc: undefined, texts: parts };
  }
  const b64 = Buffer.from(buf).toString('base64');
  const texts = [];
  for (let i = 0; i < b64.length; i += chunk) texts.push(b64.slice(i, i + chunk));
  if (texts.length === 0) texts.push('');
  return { enc: 'b64', texts };
}

/** The reference string for pastes: "id", "id+id", "b64:id+id". */
export function refOf(enc, ids) { return (enc === 'b64' ? 'b64:' : '') + ids.join('+'); }

export function parseRef(ref) {
  const b64 = ref.startsWith('b64:');
  return { enc: b64 ? 'b64' : undefined, ids: (b64 ? ref.slice(4) : ref).split('+') };
}

/** Put the content of pastes back together. texts are the raw texts in order. */
export function fromParts(enc, texts) {
  const joined = texts.join('');
  return enc === 'b64' ? Buffer.from(joined.replace(/\s+/g, ''), 'base64') : Buffer.from(joined, 'utf8');
}

// ------------------------------------------------------------------------------------------------------------------
// The Pastebin API
// ------------------------------------------------------------------------------------------------------------------

export class Pastebin {
  /** opts: devKey, userKey, endpoint, loginEndpoint, rawBase, fetchFn, sleep(ms), retries. */
  constructor(opts) {
    this.o = { ...DEFAULTS, retries: 3, fetchFn: fetch, sleep: (ms) => new Promise((r) => setTimeout(r, ms)), ...opts };
    this.userKey = opts.userKey;
  }

  clean(text) {
    let t = String(text);
    for (const secret of [this.o.devKey, this.userKey]) if (secret) t = t.split(secret).join('***');
    return t.slice(0, 300);
  }

  async post(url, fields) {
    let last;
    for (let attempt = 0; attempt <= this.o.retries; attempt++) {
      try {
        const res = await this.o.fetchFn(url, { method: 'POST', body: new URLSearchParams(fields) });
        const answer = (await res.text()).trim();
        if (res.status === 429) throw new RateLimited('Pastebin answered 429 (too many requests)', 10 * 60 * 1000);
        if (res.status >= 500) { last = new Error(`Pastebin error ${res.status}`); await this.o.sleep(2000 * 2 ** attempt); continue; }
        return answer;
      } catch (e) {
        if (e instanceof RateLimited) throw e;
        last = e;
        await this.o.sleep(2000 * 2 ** attempt);
      }
    }
    throw new Error(`cannot reach Pastebin: ${this.clean(last?.message ?? last)}`);
  }

  /** Create a public paste. Returns its id. */
  async create({ name, text, format = 'text' }) {
    const answer = await this.post(this.o.endpoint, {
      api_dev_key: this.o.devKey, api_option: 'paste', api_paste_code: text, api_paste_name: name.slice(0, 100),
      api_paste_private: '0', api_paste_expire_date: 'N', api_paste_format: format, ...(this.userKey ? { api_user_key: this.userKey } : {}),
    });
    const m = answer.match(/pastebin\.com\/(?:raw\/)?(\w+)$/);
    if (m) return m[1];
    if (/limit|too many|maximum|exceed/i.test(answer)) throw new RateLimited(this.clean(answer), DAY);
    throw new Error(`Pastebin refused: ${this.clean(answer)}`);
  }

  async login(user, password) {
    const answer = await this.post(this.o.loginEndpoint, { api_dev_key: this.o.devKey, api_user_name: user, api_user_password: password });
    if (!/^\w{20,}$/.test(answer)) throw new Error(`Pastebin login failed: ${this.clean(answer)}`);
    this.userKey = answer;
    return answer;
  }

  async delete(id) {
    if (!this.userKey) throw new Error('deleting pastes needs the account that made them (PASTEBIN_USER and PASTEBIN_PASSWORD)');
    const answer = await this.post(this.o.endpoint, { api_dev_key: this.o.devKey, api_user_key: this.userKey, api_option: 'delete', api_paste_key: id });
    if (!/removed/i.test(answer)) throw new Error(`could not delete ${id}: ${this.clean(answer)}`);
    return true;
  }

  /** The account's pastes: [{ id, title }] (at most 1000). */
  async list() {
    if (!this.userKey) throw new Error('listing pastes needs the account that made them');
    const xml = await this.post(this.o.endpoint, { api_dev_key: this.o.devKey, api_user_key: this.userKey, api_option: 'list', api_results_limit: '1000' });
    const out = [];
    for (const m of xml.matchAll(/<paste>([\s\S]*?)<\/paste>/g)) {
      const id = m[1].match(/<paste_key>(.*?)<\/paste_key>/)?.[1];
      const title = m[1].match(/<paste_title>(.*?)<\/paste_title>/)?.[1] ?? '';
      if (id) out.push({ id, title: title.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>') });
    }
    return out;
  }

  async raw(id) {
    const res = await this.o.fetchFn(this.o.rawBase + id);
    return res.ok ? await res.text() : null;
  }
}

// ------------------------------------------------------------------------------------------------------------------
// State
// ------------------------------------------------------------------------------------------------------------------

export function emptyState() {
  return { format: 2, items: {}, uploads: [], retired: [], generations: [], gen: 0, blockedUntil: 0 };
}

export function loadState(path) {
  if (!existsSync(path)) return emptyState();
  return { ...emptyState(), ...JSON.parse(readFileSync(path, 'utf8')) };
}

export function saveState(path, state) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(state, null, 1) + '\n');
}

// ------------------------------------------------------------------------------------------------------------------
// The plan: what should be on Pastebin
// ------------------------------------------------------------------------------------------------------------------

/**
 * Items for the registry in `site` (the folder tools/build/build.mjs writes): index, signatures, trust files, package documents, files, and the installer.
 * opts: packages ('all' or a list; dependencies are added), chunk.
 * Returns { items, names, problems } with items = [{ key, kind, label, format, priority, buf, sha, enc, parts: [{ text, sha }] }].
 */
export function plan(site, opts = {}) {
  const chunk = opts.chunk ?? DEFAULTS.chunk;
  const reg = join(site, 'registry');
  const index = JSON.parse(readFileSync(join(reg, 'index.json'), 'utf8'));
  const all = Object.keys(index.packages).sort();
  const wanted = !opts.packages || opts.packages === 'all' ? all : opts.packages;
  const names = new Set();
  const visit = (n) => {
    if (names.has(n)) return;
    if (!index.packages[n]) throw new Error(`unknown package ${n}`);
    names.add(n);
    const doc = JSON.parse(readFileSync(join(reg, 'packages', `${n}.json`), 'utf8'));
    for (const dep of Object.keys(doc.versions[doc.latest].requires ?? {})) if (index.packages[dep]) visit(dep);
  };
  wanted.forEach(visit);
  const rank = (n) => { const i = BASE_ORDER.indexOf(n); return i >= 0 ? i : 100; };
  const items = [];
  const problems = [];
  const add = (key, kind, label, format, priority, buf) => {
    const p = toParts(buf, chunk);
    items.push({ key, kind, label, format, priority, buf, sha: sha256(buf), enc: p.enc, parts: p.texts.map((text) => ({ text, sha: sha256(Buffer.from(text, 'utf8')) })) });
  };
  const optional = (file, key, label, format) => { const p = join(reg, file); if (existsSync(p)) add(key, 'registry', label, format, -1, readFileSync(p)); };
  add('index', 'registry', 'registry index', 'json', -2, readFileSync(join(reg, 'index.json')));
  optional('index.json.sig', 'index.sig', 'registry index signature', 'text');
  optional('trust.json', 'trust', 'registry key updates', 'json');
  optional('trust.json.sig', 'trust.sig', 'registry key updates signature', 'text');
  const blobPriority = new Map();
  const blobLabels = new Map();
  for (const n of [...names].sort()) {
    const docText = readFileSync(join(reg, 'packages', `${n}.json`));
    add(`doc/${n}`, 'doc', `package ${n}`, 'json', rank(n), docText);
    const doc = JSON.parse(docText.toString('utf8'));
    for (const f of doc.versions[doc.latest].files) {
      blobPriority.set(f.sha256, Math.min(blobPriority.get(f.sha256) ?? 1e9, rank(n)));
      if (!blobLabels.has(f.sha256)) blobLabels.set(f.sha256, `${n} ${f.path}`);
    }
  }
  for (const [sha, priority] of [...blobPriority].sort()) {
    const file = join(site, 'blobs', sha);
    if (!existsSync(file)) { problems.push(`blob ${sha} (${blobLabels.get(sha)}) is missing from the site`); continue; }
    const buf = readFileSync(file);
    if (sha256(buf) !== sha) { problems.push(`blob ${blobLabels.get(sha)} does not match its checksum`); continue; }
    add(`blob/${sha}`, 'blob', blobLabels.get(sha), blobLabels.get(sha).endsWith('.lua') ? 'lua' : 'text', priority, buf);
  }
  const kindOrder = { registry: 0, doc: 1, blob: 2 };
  items.sort((a, b) => a.priority - b.priority || (kindOrder[a.kind] ?? 9) - (kindOrder[b.kind] ?? 9) || a.key.localeCompare(b.key));
  return { items, names: [...names].sort(), problems };
}

/** The installer as an item (it is rebuilt after the snapshot id is known, so it is planned separately). */
export function installerItem(site, chunk = DEFAULTS.chunk) {
  const file = join(site, 'install.lua');
  if (!existsSync(file)) throw new Error('dist/site/install.lua not found - run tools/build/build.mjs');
  const buf = readFileSync(file);
  const p = toParts(buf, chunk);
  if (p.texts.length !== 1 || p.enc) throw new Error('the installer must fit in one plain paste (so that `pastebin run` works)');
  return { key: 'installer', kind: 'installer', label: 'Tessera installer', format: 'lua', priority: -3, buf, sha: sha256(buf), enc: undefined, parts: [{ text: p.texts[0], sha: sha256(Buffer.from(p.texts[0], 'utf8')) }] };
}

// ------------------------------------------------------------------------------------------------------------------
// Comparing with what is already on Pastebin
// ------------------------------------------------------------------------------------------------------------------

/** Which parts of an item are missing or changed? [] = the item is complete. */
export function missingParts(item, state) {
  const rec = state.items[item.key];
  const out = [];
  item.parts.forEach((p, i) => { if (!rec || rec.enc !== item.enc || rec.parts?.[i]?.sha !== p.sha || !rec.parts[i].id) out.push(i); });
  return out;
}

/** A summary without any network: { upload: pastes to create, items: {new, changed, unchanged, removed}, removed: keys } */
export function diff(p, state, extra = []) {
  const keys = new Set();
  const res = { upload: 0, new: [], changed: [], unchanged: [], removed: [], bytes: 0 };
  for (const item of [...p.items, ...extra]) {
    keys.add(item.key);
    const miss = missingParts(item, state);
    if (!miss.length) { res.unchanged.push(item.key); continue; }
    (state.items[item.key] ? res.changed : res.new).push(item.key);
    res.upload += miss.length;
    for (const i of miss) res.bytes += Buffer.byteLength(item.parts[i].text);
  }
  for (const key of Object.keys(state.items)) if (!keys.has(key) && key !== 'snapshot') res.removed.push(key);
  return res;
}

export function usedInLast24h(state, now = Date.now()) {
  return state.uploads.filter((t) => now - t < DAY);
}

/** When may the next paste be made? (now if the budget allows) */
export function nextSlot(state, limit, now = Date.now()) {
  if (state.blockedUntil > now) return state.blockedUntil;
  const recent = usedInLast24h(state, now).sort((a, b) => a - b);
  if (recent.length < limit) return now;
  return recent[recent.length - limit] + DAY;
}

// ------------------------------------------------------------------------------------------------------------------
// Uploading
// ------------------------------------------------------------------------------------------------------------------

/**
 * Create the missing pastes of one item (a new paste per changed part; unchanged parts keep theirs; replaced ones are retired).
 * ctx: api, state, save(), log, limit, delay, now(), sleep(ms). Throws RateLimited when the budget or Pastebin says stop; what was made is kept.
 */
export async function putItem(item, ctx) {
  const { api, state } = ctx;
  const now = ctx.now ?? Date.now;
  const rec = state.items[item.key] ?? (state.items[item.key] = { parts: [] });
  if (rec.enc !== item.enc && rec.parts.length) {
    for (const old of rec.parts) if (old.id) state.retired.push({ id: old.id, label: item.label, gen: state.gen });
    rec.parts = [];
  }
  rec.enc = item.enc;
  rec.label = item.label;
  rec.kind = item.kind;
  for (let i = 0; i < item.parts.length; i++) {
    const part = item.parts[i];
    const old = rec.parts[i];
    if (old && old.id && old.sha === part.sha) continue;
    const slot = nextSlot(state, ctx.limit ?? DEFAULTS.limit, now());
    if (slot > now()) { const e = new RateLimited(`the budget of ${ctx.limit ?? DEFAULTS.limit} pastes per 24 hours is used up`, slot - now()); e.until = slot; throw e; }
    if (ctx.delay && ctx.lastCall) {
      const wait = ctx.lastCall + ctx.delay - now();
      if (wait > 0) await (ctx.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))))(wait);
    }
    const suffix = item.parts.length > 1 ? ` (${i + 1}/${item.parts.length})` : '';
    let id;
    try {
      ctx.lastCall = now();
      id = await api.create({ name: `tessera ${item.label}${suffix}`, text: part.text, format: item.format });
    } catch (e) {
      if (e instanceof RateLimited) { e.until = now() + e.afterMs; state.blockedUntil = e.until; ctx.save?.(); }
      throw e;
    }
    state.uploads.push(now());
    if (old && old.id) state.retired.push({ id: old.id, label: item.label, gen: state.gen });
    rec.parts[i] = { sha: part.sha, id };
    ctx.save?.();
    ctx.log?.(`created ${item.label}${suffix} -> ${id}`);
  }
  // the item got shorter: the surplus parts are retired
  while (rec.parts.length > item.parts.length) {
    const old = rec.parts.pop();
    if (old?.id) state.retired.push({ id: old.id, label: item.label, gen: state.gen });
  }
  rec.sha = item.sha;
  ctx.save?.();
  return refOf(item.enc, rec.parts.map((p) => p.id));
}

/**
 * Upload everything that is missing (not the installer), most important first.
 * Returns { done, created, remaining, until } — `done` false means it stopped on the rate limit (run again later).
 */
export async function sync(p, ctx) {
  let created = 0;
  const before = ctx.state.uploads.length;
  try {
    for (const item of p.items) {
      if (!missingParts(item, ctx.state).length) continue;
      if (ctx.max !== undefined && ctx.state.uploads.length - before >= ctx.max) {
        return { done: false, created: ctx.state.uploads.length - before, remaining: diff(p, ctx.state).upload, until: null };
      }
      await putItem(item, ctx);
    }
  } catch (e) {
    if (e instanceof RateLimited) return { done: false, created: ctx.state.uploads.length - before, remaining: diff(p, ctx.state).upload, until: e.until, reason: e.message };
    throw e;
  }
  created = ctx.state.uploads.length - before;
  return { done: true, created, remaining: 0 };
}

export function itemRef(state, key) {
  const rec = state.items[key];
  if (!rec || !rec.parts.length || rec.parts.some((x) => !x.id)) return null;
  return refOf(rec.enc, rec.parts.map((x) => x.id));
}

/** The snapshot document (format 2) built from the pastes that exist. Returns { snapshot, missing }. */
export function buildSnapshot(p, state) {
  const snap = { format: 2, docs: {}, blobs: {} };
  const missing = [];
  for (const item of p.items) {
    if (missingParts(item, state).length) { missing.push(item.key); continue; }
    const ref = itemRef(state, item.key);
    if (item.key === 'index') snap.index = ref;
    else if (item.key === 'index.sig') snap.indexSig = ref;
    else if (item.key === 'trust') snap.trust = ref;
    else if (item.key === 'trust.sig') snap.trustSig = ref;
    else if (item.kind === 'doc') snap.docs[item.key.slice(4)] = ref;
    else if (item.kind === 'blob') snap.blobs[item.key.slice(5)] = ref;
  }
  return { snapshot: snap, missing };
}

/** Every paste id that the current state refers to. */
export function liveIds(state) {
  const ids = new Set();
  for (const rec of Object.values(state.items)) for (const x of rec.parts) if (x.id) ids.add(x.id);
  return ids;
}

/** Items in the state that are no longer in the plan: their pastes are retired. */
export function retireMissing(p, state, keepKeys = []) {
  const keys = new Set([...p.items.map((i) => i.key), ...keepKeys, 'snapshot', 'installer']);
  let n = 0;
  for (const key of Object.keys(state.items)) {
    if (keys.has(key)) continue;
    for (const x of state.items[key].parts) if (x.id) { state.retired.push({ id: x.id, label: state.items[key].label ?? key, gen: state.gen }); n++; }
    delete state.items[key];
  }
  return n;
}

/**
 * Publish a release: needs every item to exist. Makes the snapshot paste, calls ctx.afterSnapshot(ref) (which must rebuild the installer with that id),
 * uploads the installer, and records the generation. Returns { snapshot, installer, generation }.
 */
export async function publish(p, ctx) {
  const { state } = ctx;
  const { snapshot, missing } = buildSnapshot(p, state);
  if (missing.length && !ctx.allowPartial) throw new Error(`${missing.length} item(s) are not on Pastebin yet (run sync first): ${missing.slice(0, 5).join(', ')}${missing.length > 5 ? ' ...' : ''}`);
  retireMissing(p, state);
  const text = JSON.stringify(snapshot);
  const snapItem = { key: 'snapshot', kind: 'snapshot', label: 'registry snapshot', format: 'json', priority: -4, buf: Buffer.from(text), sha: sha256(Buffer.from(text)), ...(() => { const t = toParts(Buffer.from(text), ctx.chunk ?? DEFAULTS.chunk); return { enc: t.enc, parts: t.texts.map((x) => ({ text: x, sha: sha256(Buffer.from(x, 'utf8')) })) }; })() };
  const snapRef = await putItem(snapItem, ctx);
  const installerItemNow = await ctx.afterSnapshot(snapRef);
  const instRef = await putItem(installerItemNow, ctx);
  state.gen += 1;
  const ids = new Set([...liveIds(state)]);
  state.generations.unshift({ gen: state.gen, at: new Date(ctx.now ? ctx.now() : Date.now()).toISOString(), snapshot: snapRef, installer: instRef, ids: [...ids] });
  ctx.save?.();
  return { snapshot: snapRef, installer: instRef, generation: state.gen };
}

/** Retired pastes that no recent snapshot refers to. */
export function prunable(state, keep = DEFAULTS.keep) {
  const referenced = new Set(liveIds(state));
  for (const g of state.generations.slice(0, Math.max(1, keep))) for (const id of g.ids) referenced.add(id);
  return state.retired.filter((r) => !referenced.has(r.id));
}

/** Delete them (needs the user key). Returns { deleted, failed }. */
export async function prune(state, api, opts = {}) {
  const list = prunable(state, opts.keep ?? DEFAULTS.keep);
  const deleted = [], failed = [];
  for (const r of list) {
    try {
      await api.delete(r.id);
      deleted.push(r.id);
      state.retired = state.retired.filter((x) => x.id !== r.id);
      opts.save?.();
      opts.log?.(`deleted ${r.label} (${r.id})`);
    } catch (e) {
      failed.push({ id: r.id, error: e.message });
      if (/needs the account/.test(e.message)) break;
    }
    if (opts.delay) await (opts.sleep ?? ((ms) => new Promise((rr) => setTimeout(rr, ms))))(opts.delay);
  }
  state.generations = state.generations.slice(0, Math.max(1, opts.keep ?? DEFAULTS.keep));
  opts.save?.();
  return { deleted, failed };
}

/** Read every paste back and compare with what was meant to be there. Returns problems. */
export async function verify(p, state, api, opts = {}) {
  const problems = [];
  const items = [...p.items];
  if (opts.installer) items.push(opts.installer);
  const check = async (key, label, buf) => {
    const rec = state.items[key];
    if (!rec || !rec.parts.length) { problems.push(`${label}: was never uploaded`); return; }
    const texts = [];
    for (const x of rec.parts) {
      const t = await api.raw(x.id);
      if (t === null) { problems.push(`${label}: cannot be read back (paste ${x.id})`); return; }
      texts.push(t);
      if (opts.delay) await (opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))))(opts.delay);
    }
    const back = fromParts(rec.enc, texts);
    if (!back.equals(buf)) problems.push(`${label}: the pastes differ from the file (${rec.parts.map((x) => x.id).join('+')})`);
  };
  for (const item of items) await check(item.key, item.label, item.buf);
  if (opts.snapshotText) await check('snapshot', 'snapshot', Buffer.from(opts.snapshotText));
  return problems;
}

/** Rebuild missing state from the account's list of pastes (titles are "tessera <label>"). Returns how many were recognised. */
export async function adopt(p, state, api) {
  const list = await api.list();
  let n = 0;
  const byTitle = new Map(list.map((x) => [x.title, x.id]));
  for (const item of p.items) {
    if (state.items[item.key]) continue;
    const ids = item.parts.map((_, i) => byTitle.get(`tessera ${item.label}${item.parts.length > 1 ? ` (${i + 1}/${item.parts.length})` : ''}`));
    if (ids.some((x) => !x)) continue;
    state.items[item.key] = { enc: item.enc, label: item.label, kind: item.kind, sha: item.sha, parts: item.parts.map((part, i) => ({ sha: part.sha, id: ids[i] })), adopted: true };
    n++;
  }
  return n;
}

/** A short public page about the mirror (docs/PASTEBIN.md). */
export function renderDoc(state, mirror) {
  const latest = state.generations[0];
  const counts = { blob: 0, doc: 0 };
  for (const rec of Object.values(state.items)) if (counts[rec.kind] !== undefined) counts[rec.kind]++;
  const lines = [
    '# The Pastebin mirror',
    '',
    'When the web site cannot be reached, Tessera can be installed from Pastebin: every package file, every package document and the signed registry index are separate public pastes,',
    'and a *snapshot* paste says which is which. Files that are too long for one paste are split over several (and binary files are stored as base64); the installer and the package',
    'manager put them back together and check the SHA-256 of every file, and the registry index must carry the project\'s signature, so a changed paste is refused.',
    '',
  ];
  if (!latest) {
    lines.push('*The mirror has not been published yet.*', '');
    return lines.join('\n');
  }
  lines.push(
    '## Install from Pastebin',
    '',
    'On a computer with HTTP enabled:',
    '',
    '```',
    `pastebin run ${latest.installer}`,
    '```',
    '',
    `The installer paste carries the snapshot \`${latest.snapshot}\`, so it works without any other address. To add the mirror to an installed system: \`pkg source add\` with type \`pastebin\` and snapshot \`${latest.snapshot}\`.`,
    '',
    '## Facts',
    '',
    `* Generation ${latest.gen}, published ${latest.at}.`,
    `* ${counts.doc} package documents and ${counts.blob} file pastes${mirror?.partsCount ? `, ${mirror.partsCount} pastes in all` : ''}.`,
    '* Pastebin cannot edit a paste, so every update creates new pastes for what changed and the installer id changes with each release; older pastes are deleted after a grace period.',
    '',
  );
  return lines.join('\n');
}
