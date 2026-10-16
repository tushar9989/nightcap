// OpenSubtitles.com client (REST API v1).
//
// Needs the user's own API key (free: opensubtitles.com -> Consumers). Search
// is unlimited; downloads are not: a free key allows 5 per IP per 24 h
// without signing in, and signing in uses the account's own daily quota.
// The password is only sent to /login and never stored; the token is.
// Docs: https://opensubtitles.stoplight.io/docs/opensubtitles-api

import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { ROOT } from './util.js';
import { decodeText } from './subtext.js';

export const DEFAULT_BASE = 'https://api.opensubtitles.com/api/v1';
const VERSION = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8')).version;
const USER_AGENT = `Nightcap v${VERSION}`;
const SPACING_MS = 250; // the API allows 5 requests per second per IP
const SHOW_CACHE_MS = 30 * 86400e3;
const MAX_SUBTITLE_BYTES = 8 << 20;

// Some networks cut connections to OpenSubtitles at random: one internet
// provider was seen resetting about half of the TLS handshakes for
// *.opensubtitles.com, a few ms after the hello (the name is readable there).
// A connection reset before the reply never reached the API, so try again.
const RESET_CODES = new Set(['ECONNRESET', 'EPIPE', 'ECONNABORTED', 'UND_ERR_SOCKET']);
const ATTEMPTS = 10;
const BLOCKED = 'Your network keeps cutting the connection to OpenSubtitles (your internet provider may be blocking it). Try again in a moment.';

async function fetchRetrying(url, options, timeout) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await fetch(url, { ...options, signal: AbortSignal.timeout(timeout) });
    } catch (e) {
      const reset = RESET_CODES.has(e.cause?.code);
      if (!reset || attempt >= ATTEMPTS) {
        console.warn(`[opensubtitles] ${new URL(url).host}: ${e.cause?.code || e.name} (try ${attempt})`);
        throw new OpenSubtitlesError(reset ? BLOCKED : 'Could not reach OpenSubtitles (offline?)', 0);
      }
      await new Promise((r) => setTimeout(r, 100 + 50 * attempt));
    }
  }
}

// OpenSubtitles "moviehash": file size plus the 64-bit little-endian words of
// the first and last 64 KiB. Identifies the exact release, so subtitles made
// for this very file come first and are in sync.
export async function movieHash(filePath, size) {
  const CHUNK = 65536;
  const fh = await fsp.open(filePath, 'r');
  try {
    const head = Buffer.alloc(CHUNK);
    const tail = Buffer.alloc(CHUNK);
    await fh.read(head, 0, Math.min(CHUNK, size), 0);
    await fh.read(tail, 0, Math.min(CHUNK, size), Math.max(0, size - CHUNK));
    let hash = BigInt(size);
    for (const buf of [head, tail]) for (let i = 0; i < CHUNK; i += 8) hash += buf.readBigUInt64LE(i);
    return (hash & 0xffffffffffffffffn).toString(16).padStart(16, '0');
  } finally {
    await fh.close();
  }
}

// The API asks for sorted, lower-case parameters without defaults, and IDs
// without leading zeros, so requests hit its cache instead of redirecting.
export function canonicalQuery(params) {
  const q = new URLSearchParams();
  for (const k of Object.keys(params).sort()) {
    let v = params[k];
    if (v == null || v === '') continue;
    v = String(v).toLowerCase();
    if (/_id$|^id$/.test(k)) v = v.replace(/^tt/, '').replace(/^0+(?=\d)/, '');
    q.append(k, v);
  }
  return q.toString();
}

export class OpenSubtitlesError extends Error {
  constructor(message, status = 0, data = null) {
    super(message);
    this.status = status;
    this.data = data;
  }
}

function jwtExpiry(token) {
  try {
    const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString());
    return Number(payload.exp) || null;
  } catch {
    return null;
  }
}

const norm = (s) => String(s || '').toLowerCase().replace(/&/g, 'and').replace(/[^a-z0-9]+/g, ' ').replace(/^the /, '').trim();

export class OpenSubtitles {
  // store: JsonStore holding { apiKey, token, tokenExp, username, baseUrl, user, quota, shows }
  constructor(store, { base = process.env.OPENSUBTITLES_API || DEFAULT_BASE, envKey = process.env.OPENSUBTITLES_API_KEY } = {}) {
    this.store = store;
    this.base = base;
    this.envKey = envKey || '';
    this.chain = Promise.resolve();
    this.last = 0;
  }

  get key() {
    return this.envKey || this.store.data.apiKey || '';
  }

  get configured() {
    return !!this.key;
  }

  get signedIn() {
    const d = this.store.data;
    return !!d.token && (!d.tokenExp || d.tokenExp * 1000 > Date.now() + 60e3);
  }

  status() {
    const d = this.store.data;
    const key = this.key;
    const quota = d.quota && (!d.quota.resetAt || Date.parse(d.quota.resetAt) > Date.now()) ? d.quota : null;
    return {
      provider: 'OpenSubtitles.com',
      configured: !!key,
      keyHint: key ? `••••${key.slice(-4)}` : '',
      keyFromEnv: !!this.envKey,
      signedIn: this.signedIn,
      signInExpired: !!d.token && !this.signedIn,
      username: d.username || '',
      level: this.signedIn ? d.user?.level || '' : '',
      allowedDownloads: this.signedIn ? d.user?.allowedDownloads ?? null : 5,
      remaining: quota ? quota.remaining : null,
      resetAt: quota?.resetAt || null,
    };
  }

  // After signing in, requests go to the host /login returned (VIP accounts get their own).
  apiBase() {
    const host = this.signedIn && this.store.data.baseUrl;
    return host && this.base === DEFAULT_BASE && /^[a-z0-9.-]+\.opensubtitles\.com$/.test(host) ? `https://${host}/api/v1` : this.base;
  }

  async request(method, apiPath, { query, body, auth = true, key = this.key } = {}) {
    if (!key) throw new OpenSubtitlesError('Add an OpenSubtitles API key in Settings first', 0);
    const turn = this.chain.then(async () => {
      const wait = this.last + SPACING_MS - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      this.last = Date.now();
    });
    this.chain = turn;
    await turn;
    const url = `${this.apiBase()}${apiPath}${query ? `?${canonicalQuery(query)}` : ''}`;
    const headers = { 'Api-Key': key, 'User-Agent': USER_AGENT, Accept: 'application/json' };
    if (body) headers['Content-Type'] = 'application/json';
    if (auth && this.signedIn) headers.Authorization = `Bearer ${this.store.data.token}`;
    const r = await fetchRetrying(url, { method, headers, body: body ? JSON.stringify(body) : undefined }, 20000);
    const data = await r.json().catch(() => ({}));
    if (!r.ok) {
      const msg = data.message || (Array.isArray(data.errors) ? data.errors.join(', ') : '') || `OpenSubtitles answered ${r.status}`;
      throw new OpenSubtitlesError(msg, r.status, data);
    }
    return data;
  }

  // Checks a key with a cheap request before saving it.
  async setKey(apiKey) {
    apiKey = String(apiKey || '').trim();
    if (!apiKey) {
      delete this.store.data.apiKey;
      this.store.save();
      return;
    }
    if (!/^[A-Za-z0-9_-]{8,128}$/.test(apiKey)) throw new OpenSubtitlesError('That does not look like an API key', 400);
    try {
      await this.request('GET', '/infos/formats', { key: apiKey, auth: false });
    } catch (e) {
      if (e.status === 401 || e.status === 403) throw new OpenSubtitlesError('OpenSubtitles did not accept this API key', 400);
      throw e;
    }
    this.store.data.apiKey = apiKey;
    this.store.save();
  }

  async login(username, password) {
    username = String(username || '').trim();
    if (!username || !password) throw new OpenSubtitlesError('Enter your OpenSubtitles username and password', 400);
    let data;
    try {
      data = await this.request('POST', '/login', { body: { username, password: String(password) }, auth: false });
    } catch (e) {
      if (e.status === 401) throw new OpenSubtitlesError('Wrong username or password', 400);
      throw e;
    }
    const d = this.store.data;
    d.token = data.token;
    d.tokenExp = jwtExpiry(data.token);
    d.username = username;
    d.baseUrl = data.base_url || '';
    d.user = { level: data.user?.level || '', allowedDownloads: data.user?.allowed_downloads ?? null, vip: !!data.user?.vip };
    d.quota = null;
    this.store.save();
    return this.status();
  }

  async logout() {
    if (this.store.data.token) await this.request('DELETE', '/logout').catch(() => {});
    for (const k of ['token', 'tokenExp', 'baseUrl', 'user', 'quota']) delete this.store.data[k];
    this.store.save();
  }

  // Remaining downloads for the signed-in user.
  async refreshUser() {
    if (!this.signedIn) return this.status();
    try {
      const { data } = await this.request('GET', '/infos/user');
      const d = this.store.data;
      d.user = { ...d.user, level: data.level || d.user?.level || '', allowedDownloads: data.allowed_downloads ?? d.user?.allowedDownloads ?? null, vip: !!data.vip };
      if (data.remaining_downloads != null) d.quota = { remaining: data.remaining_downloads, resetAt: d.quota?.resetAt || null };
      this.store.save();
    } catch (e) {
      if (e.status === 401) this.dropToken();
    }
    return this.status();
  }

  dropToken() {
    for (const k of ['token', 'tokenExp', 'baseUrl']) delete this.store.data[k];
    this.store.save();
  }

  // The show as OpenSubtitles knows it (cached), so episodes can be searched by id.
  async findShow(name, year) {
    const cacheKey = `${norm(name)}|${year || ''}`;
    const shows = (this.store.data.shows ||= {});
    const hit = shows[cacheKey];
    if (hit && Date.now() - hit.at < (hit.show ? SHOW_CACHE_MS : 86400e3)) return hit.show;
    const { data = [] } = await this.request('GET', '/features', { query: { query: name, type: 'tvshow' } });
    const shown = data.map((f) => ({
      id: Number(f.attributes?.feature_id || f.id),
      title: f.attributes?.title || '',
      year: Number(f.attributes?.year) || null,
      count: Object.values(f.attributes?.subtitles_counts || {}).reduce((a, b) => a + b, 0) || f.attributes?.subtitles_count || 0,
      type: f.attributes?.feature_type || '',
    })).filter((f) => f.id && /tv/i.test(f.type || 'tvshow'));
    const want = norm(name);
    const exact = shown.filter((f) => norm(f.title) === want);
    const pool = exact.length ? exact : shown.filter((f) => norm(f.title).startsWith(want) || want.startsWith(norm(f.title)));
    const byYear = year ? pool.filter((f) => f.year === Number(year)) : [];
    const show = (byYear.length ? byYear : pool).sort((a, b) => b.count - a.count)[0] || null;
    shows[cacheKey] = { at: Date.now(), show };
    this.store.save();
    return show;
  }

  async search(params) {
    const res = await this.request('GET', '/subtitles', { query: params });
    return (res.data || []).map(normaliseResult).filter(Boolean);
  }

  // Returns { text, fileName } and records the quota the API reports.
  async download(fileId) {
    let info;
    try {
      info = await this.request('POST', '/download', { body: { file_id: Number(fileId) } });
    } catch (e) {
      if (e.status === 401 && this.store.data.token) {
        // Signed-in token no longer valid: fall back to the anonymous allowance.
        this.dropToken();
        info = await this.request('POST', '/download', { body: { file_id: Number(fileId) } }).catch((e2) => this.quotaError(e2));
      } else this.quotaError(e);
    }
    this.store.data.quota = { remaining: Number.isFinite(info.remaining) ? info.remaining : null, resetAt: info.reset_time_utc || null };
    this.store.save();
    if (!info.link) throw new OpenSubtitlesError(info.message || 'OpenSubtitles did not return a download link', 502);
    const r = await fetchRetrying(info.link, { headers: { 'User-Agent': USER_AGENT } }, 30000);
    if (!r.ok) throw new OpenSubtitlesError(`The subtitle download failed (${r.status})`, 502);
    const buf = Buffer.from(await r.arrayBuffer().catch(() => {
      throw new OpenSubtitlesError('The subtitle download was cut off. Try again.', 0);
    }));
    if (buf.length > MAX_SUBTITLE_BYTES) throw new OpenSubtitlesError('That subtitle file is too large', 502);
    return { text: decodeText(buf), fileName: info.file_name || '', remaining: info.remaining ?? null, resetAt: info.reset_time_utc || null };
  }

  quotaError(e) {
    if (e.status === 406 || e.status === 429 || /allowed|quota|limit/i.test(e.message)) {
      const d = this.store.data;
      d.quota = { remaining: 0, resetAt: e.data?.reset_time_utc || d.quota?.resetAt || null };
      this.store.save();
      const hint = this.signedIn ? '' : ' Sign in to OpenSubtitles in Settings for more.';
      throw new OpenSubtitlesError(`${e.message}${hint}`, 429, e.data);
    }
    throw e;
  }
}

function normaliseResult(item) {
  const a = item?.attributes;
  const files = a?.files || [];
  if (!a || files.length !== 1) return null; // multi-CD subtitles don't fit a single file
  const f = files[0];
  const fd = a.feature_details || {};
  return {
    id: Number(f.file_id),
    subtitleId: String(a.subtitle_id || item.id || ''),
    language: a.language || '',
    release: (a.release || f.file_name || '').trim(),
    fileName: f.file_name || '',
    downloads: a.download_count || 0,
    hearingImpaired: !!a.hearing_impaired,
    foreignOnly: !!a.foreign_parts_only,
    aiTranslated: !!a.ai_translated,
    machineTranslated: !!a.machine_translated,
    trusted: !!a.from_trusted,
    hashMatch: !!(a.moviehash_match ?? f.moviehash_match),
    fps: Number(a.fps) || null,
    uploaded: a.upload_date || null,
    uploader: a.uploader?.name || '',
    feature: fd.title || fd.movie_name || '',
    season: fd.season_number ?? null,
    episode: fd.episode_number ?? null,
  };
}

// Best first: made for this file, complete, human-made, popular.
export function rankResults(results, { fps } = {}) {
  const score = (r) =>
    (r.hashMatch ? 1000 : 0) -
    (r.foreignOnly ? 600 : 0) -
    (r.machineTranslated ? 400 : 0) -
    (r.aiTranslated ? 150 : 0) +
    (r.trusted ? 40 : 0) -
    (r.hearingImpaired ? 15 : 0) +
    (fps && r.fps && Math.abs(r.fps - fps) < 0.05 ? 30 : 0) +
    Math.log10(1 + r.downloads) * 12;
  return results.map((r) => ({ r, s: score(r) })).sort((x, y) => y.s - x.s).map((x) => x.r);
}
