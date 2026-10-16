import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { ROOT, DATA_DIR, FFMPEG, FFPROBE, JsonStore, ensureDir, hashId, naturalCompare } from './util.js';
import { scanLibrary } from './scanner.js';
import { probe, cachedProbe, serveFile, streamTranscoded, frameThumb, listSubtitles, subtitleVtt, flushProbes } from './media.js';
import { Analyzer } from './analysis.js';
import { OnlineSubs, LANG_RE } from './online-subs.js';
import { OpenSubtitlesError } from './opensubtitles.js';
import { stripAds, retime } from './subtext.js';
import { SubSync } from './subsync.js';
import { Trickplay } from './trickplay.js';
import { openWindow } from './window.js';

const PORT = Number(process.env.PORT) || 8484;
const HOST = process.env.HOST || '127.0.0.1';
const LOOPBACK = ['127.0.0.1', 'localhost', '::1'].includes(HOST);
const PUBLIC = path.join(ROOT, 'public');
ensureDir(DATA_DIR);

// Subtitle language to search for first: the Mac's language (OpenSubtitles codes).
function systemLanguage() {
  try {
    const loc = new Intl.Locale(Intl.DateTimeFormat().resolvedOptions().locale);
    if (loc.language === 'pt') return loc.region === 'BR' ? 'pt-BR' : 'pt-PT';
    if (loc.language === 'zh') return ['TW', 'HK', 'MO'].includes(loc.region) ? 'zh-TW' : 'zh-CN';
    return LANG_RE.test(loc.language) ? loc.language : 'en';
  } catch {
    return 'en';
  }
}

const DEFAULT_SETTINGS = { autoSkipIntro: false, autoplayNext: true, analysis: true, nextCountdown: 10, subtitleLanguage: systemLanguage(), autoFetchSubtitles: true, previews: true };
const config = new JsonStore(path.join(DATA_DIR, 'config.json'), { folders: [], settings: DEFAULT_SETTINGS });
config.data.settings = { ...DEFAULT_SETTINGS, ...config.data.settings };
const progress = new JsonStore(path.join(DATA_DIR, 'progress.json'), { files: {}, hidden: {} });
const libraryStore = new JsonStore(path.join(DATA_DIR, 'library.json'), { titles: [], files: {}, folderStatus: {}, scannedAt: 0 });

let library = libraryStore.data;
let titles = new Map(library.titles.map((t) => [t.id, t]));

const analyzer = new Analyzer({
  getLibrary: () => library,
  probe,
  isEnabled: () => config.data.settings.analysis,
});

const onlineSubs = new OnlineSubs({ getTitle: (id) => titles.get(id) });
const subsync = new SubSync();
const trickplay = new Trickplay({ getLibrary: () => library, probe, isEnabled: () => config.data.settings.previews });

// ---- Library --------------------------------------------------------------

let scanning = null;
function rescan() {
  scanning ||= (async () => {
    const t0 = Date.now();
    const lib = await scanLibrary(config.data.folders);
    library = lib;
    titles = new Map(lib.titles.map((t) => [t.id, t]));
    libraryStore.data = lib;
    libraryStore.save();
    console.log(`[scan] ${lib.titles.length} titles, ${Object.keys(lib.files).length} videos (${Date.now() - t0} ms)`);
    analyzer.sync();
    trickplay.sync();
    warmProbes();
  })()
    .catch((e) => console.error('[scan] failed:', e))
    .finally(() => (scanning = null));
  return scanning;
}

// Read durations in the background so episode lists can show runtimes.
let warming = false;
async function warmProbes() {
  if (warming || !FFPROBE) return;
  warming = true;
  try {
    for (const f of Object.values(library.files)) if (!cachedProbe(f)) await probe(f);
  } finally {
    warming = false;
  }
}

function isWatched(fileId, position, duration) {
  if (!duration) return false;
  const credits = analyzer.markers(fileId).credits;
  if (credits && position >= credits.start - 2) return true;
  return position >= duration * 0.95 || duration - position <= 15;
}

function libraryPayload() {
  const files = {};
  const markers = {};
  for (const f of Object.values(library.files)) {
    files[f.id] = {
      id: f.id,
      titleId: f.titleId,
      season: f.season,
      number: f.number,
      name: f.name,
      duration: cachedProbe(f)?.duration || progress.data.files[f.id]?.duration || 0,
    };
    const m = analyzer.markers(f.id);
    if (m.intro || m.credits) markers[f.id] = { intro: m.intro, credits: m.credits };
  }
  return {
    titles: library.titles.map((t) => ({ ...t, poster: !!t.poster, backdrop: !!t.backdrop, seasons: t.seasons.map(({ poster, ...s }) => s) })),
    files,
    markers,
    progress: progress.data.files,
    hidden: progress.data.hidden,
    folders: config.data.folders,
    folderStatus: library.folderStatus,
    settings: config.data.settings,
    scanning: !!scanning,
    ffmpeg: !!FFMPEG,
  };
}

// ---- Artwork ----------------------------------------------------------------

const IMG_TYPES = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp' };
const WIDTHS = [320, 480, 800, 1280];
const pickWidth = (w) => WIDTHS.find((x) => x >= Number(w || 480)) || 1280;

async function titleArt(t, type, width) {
  if (type === 'backdrop' && t.backdrop) return t.backdrop;
  if (type === 'poster' && (t.poster || t.backdrop)) return t.poster || t.backdrop;
  if (type === 'card' && (t.backdrop || t.poster)) return t.backdrop || t.poster;
  const season = t.seasons.find((s) => !s.extras && s.number !== 0) || t.seasons[0];
  const eps = season.episodes;
  const fid = type === 'backdrop' ? eps[Math.floor(eps.length / 2)] : eps[0];
  return frameThumb(library.files[fid], { at: type === 'backdrop' ? 0.42 : 0.3, width });
}

async function sendImage(res, file) {
  if (!file) {
    res.writeHead(404);
    return res.end();
  }
  try {
    const st = await fsp.stat(file);
    res.writeHead(200, { 'Content-Type': IMG_TYPES[path.extname(file).toLowerCase()] || 'image/jpeg', 'Content-Length': st.size, 'Cache-Control': 'max-age=86400' });
    fs.createReadStream(file).pipe(res);
  } catch {
    res.writeHead(404);
    res.end();
  }
}

// ---- HTTP plumbing -------------------------------------------------------------

const routes = [];
const route = (method, pattern, handler) =>
  routes.push({ method, re: new RegExp(`^${pattern.replace(/:(\w+)/g, '(?<$1>[^/]+)')}$`), handler });

const json = (res, data, status = 200) => {
  const body = JSON.stringify(data);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(body);
};
const fail = (res, status, error) => json(res, { error }, status);

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > 1e6) req.destroy();
      else chunks.push(c);
    });
    req.on('end', () => {
      try {
        resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : {});
      } catch (e) {
        reject(e);
      }
    });
    req.on('error', reject);
  });
}

// Only this machine's own pages may use the API (blocks other websites and
// DNS-rebinding tricks from reaching the server).
function allowed(req) {
  if (LOOPBACK) {
    const host = (req.headers.host || '').replace(/:\d+$/, '').replace(/^\[|\]$/g, '');
    if (!['localhost', '127.0.0.1', '::1'].includes(host)) return false;
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    const origin = req.headers.origin;
    if (origin) {
      try {
        if (new URL(origin).host !== req.headers.host) return false;
      } catch {
        return false;
      }
    }
    if (req.method === 'POST' && !/^application\/json/.test(req.headers['content-type'] || '')) return false;
  }
  return true;
}

const STATIC_TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.ico': 'image/x-icon' };

async function serveStatic(req, res, pathname) {
  const rel = pathname === '/' ? 'index.html' : decodeURIComponent(pathname.slice(1));
  const file = path.join(PUBLIC, rel);
  if (!file.startsWith(PUBLIC + path.sep)) return fail(res, 403, 'forbidden');
  try {
    const data = await fsp.readFile(file);
    res.writeHead(200, { 'Content-Type': STATIC_TYPES[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
    res.end(data);
  } catch {
    // Unknown paths fall back to the app shell.
    const data = await fsp.readFile(path.join(PUBLIC, 'index.html'));
    res.writeHead(200, { 'Content-Type': STATIC_TYPES['.html'], 'Cache-Control': 'no-cache' });
    res.end(data);
  }
}

const server = http.createServer(async (req, res) => {
  if (!allowed(req)) return fail(res, 403, 'forbidden');
  const url = new URL(req.url, 'http://local');
  const query = Object.fromEntries(url.searchParams);
  for (const r of routes) {
    if (r.method !== req.method && !(r.method === 'GET' && req.method === 'HEAD')) continue;
    const m = url.pathname.match(r.re);
    if (!m) continue;
    try {
      const params = Object.fromEntries(Object.entries(m.groups || {}).map(([k, v]) => [k, decodeURIComponent(v)]));
      return await r.handler({ req, res, params, query, body: req.method === 'POST' || req.method === 'PATCH' ? await readBody(req) : {} });
    } catch (e) {
      console.error(`[http] ${req.method} ${url.pathname}:`, e);
      if (!res.headersSent) return fail(res, 500, e.message);
      return res.destroy();
    }
  }
  if (url.pathname.startsWith('/api/')) return fail(res, 404, 'not found');
  return serveStatic(req, res, url.pathname);
});

const fileOr404 = (res, id) => {
  const f = library.files[id];
  if (!f) fail(res, 404, 'unknown file');
  return f;
};

// ---- Routes ------------------------------------------------------------------------

// `code` tells the launcher which version of the server code is running, so a
// server left over from older code gets replaced (scripts/make-mac-app.sh).
const CODE_STAMP = Math.max(...[...fs.readdirSync(path.join(ROOT, 'server')).filter((n) => n.endsWith('.js')).map((n) => path.join(ROOT, 'server', n)), path.join(ROOT, 'package.json')]
  .map((f) => Math.floor(fs.statSync(f).mtimeMs / 1000)));
route('GET', '/api/ping', ({ res }) => json(res, { ok: true, app: 'nightcap', code: CODE_STAMP }));
route('GET', '/api/library', ({ res }) => json(res, libraryPayload()));
route('GET', '/api/status', ({ res }) => json(res, { scanning: !!scanning, analysis: analyzer.status(), previews: trickplay.status(), folderStatus: library.folderStatus, ffmpeg: !!FFMPEG }));

route('POST', '/api/scan', async ({ res }) => {
  await rescan();
  json(res, libraryPayload());
});

route('POST', '/api/folders', async ({ res, body }) => {
  let p = String(body.path || '').trim().replace(/^~(?=$|\/)/, os.homedir());
  if (!p) return fail(res, 400, 'Choose a folder');
  p = path.resolve(p);
  try {
    if (!(await fsp.stat(p)).isDirectory()) return fail(res, 400, 'That is not a folder');
  } catch {
    return fail(res, 400, 'Folder not found');
  }
  const kind = ['auto', 'shows', 'movies'].includes(body.kind) ? body.kind : 'auto';
  const id = hashId(p, 8);
  if (!config.data.folders.some((f) => f.id === id)) config.data.folders.push({ id, path: p, kind, addedAt: Date.now() });
  config.save();
  await rescan();
  json(res, libraryPayload());
});

route('PATCH', '/api/folders/:id', async ({ res, params, body }) => {
  const f = config.data.folders.find((x) => x.id === params.id);
  if (!f) return fail(res, 404, 'unknown folder');
  if (['auto', 'shows', 'movies'].includes(body.kind)) f.kind = body.kind;
  config.save();
  await rescan();
  json(res, libraryPayload());
});

route('DELETE', '/api/folders/:id', async ({ res, params }) => {
  config.data.folders = config.data.folders.filter((x) => x.id !== params.id);
  config.save();
  await rescan();
  json(res, libraryPayload());
});

route('GET', '/api/browse', async ({ res, query }) => {
  const target = path.resolve((query.path || os.homedir()).replace(/^~(?=$|\/)/, os.homedir()));
  let dirs = [];
  let error = null;
  try {
    const entries = await fsp.readdir(target, { withFileTypes: true });
    for (const e of entries) {
      if (e.name.startsWith('.')) continue;
      let isDir = e.isDirectory();
      if (e.isSymbolicLink()) isDir = await fsp.stat(path.join(target, e.name)).then((s) => s.isDirectory(), () => false);
      if (isDir) dirs.push({ name: e.name, path: path.join(target, e.name) });
    }
    dirs.sort((a, b) => naturalCompare(a.name, b.name));
  } catch (e) {
    error = e.code === 'EPERM' || e.code === 'EACCES' ? 'No permission to read this folder' : 'Cannot open this folder';
  }
  const home = os.homedir();
  const shortcuts = [
    { name: 'Home', path: home },
    ...['Movies', 'Downloads', 'Desktop', 'Documents'].map((n) => ({ name: n, path: path.join(home, n) })).filter((s) => fs.existsSync(s.path)),
  ];
  try {
    for (const v of await fsp.readdir('/Volumes')) if (!v.startsWith('.')) shortcuts.push({ name: v, path: path.join('/Volumes', v), drive: true });
  } catch {}
  const parent = path.dirname(target);
  json(res, { path: target, parent: parent !== target ? parent : null, dirs, shortcuts, error });
});

route('POST', '/api/settings', ({ res, body }) => {
  const s = config.data.settings;
  for (const k of Object.keys(DEFAULT_SETTINGS)) {
    if (k in body && typeof body[k] === typeof DEFAULT_SETTINGS[k]) s[k] = body[k];
  }
  s.nextCountdown = Math.max(0, Math.min(60, Math.round(s.nextCountdown)));
  if (!LANG_RE.test(s.subtitleLanguage)) s.subtitleLanguage = DEFAULT_SETTINGS.subtitleLanguage;
  config.save();
  if (s.analysis) analyzer.kick();
  trickplay.sync();
  json(res, s);
});

route('POST', '/api/progress', ({ res, body }) => {
  const f = library.files[body.fileId];
  const position = Number(body.position);
  const duration = Number(body.duration);
  if (!f || !Number.isFinite(position) || !Number.isFinite(duration)) return fail(res, 400, 'bad progress');
  const entry = { position: Math.max(0, position), duration, updatedAt: Date.now(), watched: isWatched(f.id, position, duration) };
  progress.data.files[f.id] = entry;
  progress.save();
  json(res, entry);
});

route('POST', '/api/watched', async ({ res, body }) => {
  const ids = (body.fileIds || []).filter((id) => library.files[id]);
  const now = Date.now();
  for (const [i, id] of ids.entries()) {
    if (body.watched) {
      const duration = progress.data.files[id]?.duration || (await probe(library.files[id]))?.duration || 0;
      progress.data.files[id] = { position: duration, duration, updatedAt: now + i, watched: true };
    } else delete progress.data.files[id];
  }
  progress.save();
  json(res, { progress: progress.data.files });
});

route('POST', '/api/hide', ({ res, body }) => {
  if (titles.has(body.titleId)) progress.data.hidden[body.titleId] = Date.now();
  progress.save();
  json(res, { hidden: progress.data.hidden });
});

route('GET', '/api/play/:id', async ({ res, params }) => {
  const f = fileOr404(res, params.id);
  if (!f) return;
  const t = titles.get(f.titleId);
  analyzer.prioritize(t.id, t.seasons[f.season]?.id);
  // Previews for this video first, then the episodes after it (Next Episode card).
  const eps = t.seasons[f.season]?.episodes || [];
  const i = eps.indexOf(f.id);
  const nextSeason = t.seasons[f.season + 1];
  const nextSeasonStart = nextSeason && !nextSeason.extras ? nextSeason.episodes.slice(0, 1) : [];
  trickplay.prioritize([f.id, ...eps.slice(i + 1), ...nextSeasonStart, ...eps.slice(0, i)]);
  const [info, subtitles] = await Promise.all([probe(f), subtitleTracks(f)]);
  const online = onlineSubs.status();
  json(res, {
    id: f.id,
    titleId: f.titleId,
    name: f.name,
    ext: path.extname(f.path).slice(1).toLowerCase(),
    probe: info,
    subtitles,
    online: { configured: online.configured, signedIn: online.signedIn },
    markers: analyzer.markers(f.id),
    progress: progress.data.files[f.id] || null,
    ffmpeg: !!FFMPEG,
  });
});

route('GET', '/media/:id', ({ req, res, params }) => {
  const f = fileOr404(res, params.id);
  if (f) serveFile(req, res, f.path, f.size);
});

route('GET', '/api/stream/:id', ({ req, res, params, query }) => {
  const f = fileOr404(res, params.id);
  if (!f) return;
  streamTranscoded(req, res, f, {
    start: Math.max(0, Number(query.start) || 0),
    mode: query.mode === 'transcode' ? 'transcode' : 'remux',
    audio: Math.max(0, Number(query.audio) | 0),
    abs: query.abs === '1',
  });
});

// Subtitle ids: x<N> file next to the video, e<N> embedded track, d<N> downloaded.
const SUB_ID = /^[xed]\d+$/;

async function subtitleTracks(f) {
  const tracks = [...(await listSubtitles(f)), ...onlineSubs.list(f.id)];
  return tracks.map((t) => ({ ...t, sync: subsync.get(f, t.id) }));
}

// The track without adverts, before any timing correction.
async function plainVtt(f, subId) {
  const vtt = subId[0] === 'd' ? await onlineSubs.vtt(f.id, Number(subId.slice(1))) : await subtitleVtt(f, subId);
  return vtt == null ? null : stripAds(vtt).vtt;
}

route('GET', '/api/subtitle/:id/:sub', async ({ res, params }) => {
  const f = fileOr404(res, params.id);
  if (!f) return;
  if (!SUB_ID.test(params.sub)) return fail(res, 400, 'bad subtitle id');
  const vtt = await plainVtt(f, params.sub);
  if (vtt == null) return fail(res, 404, 'subtitle unavailable');
  res.writeHead(200, { 'Content-Type': 'text/vtt; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(retime(vtt, subsync.get(f, params.sub) || {}));
});

route('DELETE', '/api/subtitle/:id/:sub', async ({ res, params }) => {
  const f = fileOr404(res, params.id);
  if (!f) return;
  if (!/^d\d+$/.test(params.sub)) return fail(res, 400, 'Only downloaded subtitles can be removed');
  await onlineSubs.remove(f.id, Number(params.sub.slice(1)));
  subsync.clear(f, params.sub);
  json(res, { subtitles: await subtitleTracks(f) });
});

// Fits a track to the dialogue (see subsync.js) and keeps the correction.
async function syncTrack(f, subId, audio = 0) {
  const vtt = await plainVtt(f, subId);
  if (vtt == null) return { confident: false, applied: false, reason: 'Subtitle unavailable' };
  const r = await subsync.align(f, subId, vtt, { audio });
  console.log(`[subsync] ${f.name} ${subId}: offset ${r.offset ?? '-'} s, scale ${r.scale?.toFixed?.(4) ?? '-'}, z ${r.z ?? '-'}, ratio ${r.ratio ?? '-'} -> ${r.applied ? 'applied' : r.inSync ? 'in sync' : 'not applied'}`);
  return { ...r, sync: subsync.get(f, subId) };
}

route('POST', '/api/subsync/:id/:sub', async ({ res, params, body }) => {
  const f = fileOr404(res, params.id);
  if (!f) return;
  if (!SUB_ID.test(params.sub)) return fail(res, 400, 'bad subtitle id');
  try {
    json(res, await syncTrack(f, params.sub, Math.max(0, Number(body.audio) | 0)));
  } catch (e) {
    fail(res, 500, `Could not sync: ${e.message}`);
  }
});

route('DELETE', '/api/subsync/:id/:sub', ({ res, params }) => {
  const f = fileOr404(res, params.id);
  if (!f) return;
  subsync.clear(f, params.sub);
  json(res, { sync: null });
});

// Downloads not made for this exact file are synced to the audio right away.
async function afterDownload(f, track, audio) {
  if (!track || track.hashMatch) return track;
  try {
    await syncTrack(f, track.id, audio);
  } catch (e) {
    console.warn('[subsync] failed:', e.message);
  }
  return { ...track, sync: subsync.get(f, track.id) };
}

// ---- Online subtitles (OpenSubtitles.com) ------------------------------------------

const osRoute = (method, pattern, handler) =>
  route(method, pattern, async (ctx) => {
    try {
      await handler(ctx);
    } catch (e) {
      if (!(e instanceof OpenSubtitlesError)) throw e;
      const status = e.status === 400 || e.status === 429 ? e.status : 502;
      fail(ctx.res, status, e.message);
    }
  });

osRoute('GET', '/api/opensubtitles', async ({ res, query }) => {
  json(res, query.refresh ? await onlineSubs.os.refreshUser() : onlineSubs.status());
});

osRoute('POST', '/api/opensubtitles/key', async ({ res, body }) => {
  await onlineSubs.os.setKey(body.apiKey);
  json(res, onlineSubs.status());
});

osRoute('POST', '/api/opensubtitles/login', async ({ res, body }) => {
  json(res, await onlineSubs.os.login(body.username, body.password));
});

osRoute('POST', '/api/opensubtitles/logout', async ({ res }) => {
  await onlineSubs.os.logout();
  json(res, onlineSubs.status());
});

osRoute('GET', '/api/opensubtitles/search/:id', async ({ res, params, query }) => {
  const f = fileOr404(res, params.id);
  if (!f) return;
  const language = query.language || config.data.settings.subtitleLanguage;
  json(res, { ...(await onlineSubs.search(f, { language, query: query.query })), language, status: onlineSubs.status() });
});

osRoute('POST', '/api/opensubtitles/download/:id', async ({ res, params, body }) => {
  const f = fileOr404(res, params.id);
  if (!f) return;
  const track = await afterDownload(f, await onlineSubs.fetch(f, body), Math.max(0, Number(body.audio) | 0));
  json(res, { track, status: onlineSubs.status() });
});

osRoute('POST', '/api/opensubtitles/auto/:id', async ({ res, params, body }) => {
  const f = fileOr404(res, params.id);
  if (!f) return;
  const language = LANG_RE.test(body.language || '') ? body.language : config.data.settings.subtitleLanguage;
  const r = await onlineSubs.auto(f, language);
  const track = r.fresh ? await afterDownload(f, r.track, Math.max(0, Number(body.audio) | 0)) : r.track && { ...r.track, sync: subsync.get(f, r.track.id) };
  json(res, { ...r, track, status: onlineSubs.status() });
});

route('GET', '/api/art/title/:id', async ({ res, params, query }) => {
  const t = titles.get(params.id);
  if (!t) return fail(res, 404, 'unknown title');
  const type = ['poster', 'backdrop', 'card'].includes(query.type) ? query.type : 'card';
  sendImage(res, await titleArt(t, type, pickWidth(query.w)));
});

route('GET', '/api/art/file/:id', async ({ res, params, query }) => {
  const f = fileOr404(res, params.id);
  if (f) sendImage(res, f.thumb || (await frameThumb(f, { at: 0.3, width: pickWidth(query.w) })));
});

route('POST', '/api/markers/:id', ({ res, params, body }) => {
  const f = fileOr404(res, params.id);
  if (!f) return;
  const clean = (m, keys) => (m === null ? null : Object.fromEntries(keys.map((k) => [k, Math.max(0, Math.round(Number(m[k]) * 10) / 10)])));
  const patch = {};
  if (body.reset) patch.reset = true;
  if ('intro' in body) patch.intro = clean(body.intro, ['start', 'end']);
  if ('credits' in body) patch.credits = clean(body.credits, ['start']);
  if (patch.intro && !(patch.intro.end > patch.intro.start)) return fail(res, 400, 'Intro must end after it starts');
  analyzer.setManual(f.id, patch);
  json(res, analyzer.markers(f.id));
});

route('POST', '/api/analyze/:titleId', ({ res, params }) => {
  analyzer.reanalyze(params.titleId);
  json(res, analyzer.status());
});

route('POST', '/api/analysis/prioritize', ({ res, body }) => {
  analyzer.prioritize(body.titleId, body.seasonId);
  json(res, { ok: true });
});

// ---- Preview thumbnails --------------------------------------------------------------

route('GET', '/api/trickplay/:id', ({ res, params }) => {
  const f = fileOr404(res, params.id);
  if (!f) return;
  const m = trickplay.manifest(f);
  if (m) return json(res, { ready: true, ...m });
  trickplay.prioritize([f.id]);
  json(res, { ready: false, state: trickplay.state(f) });
});

route('GET', '/api/trickplay/:id/:n', ({ res, params }) => {
  const f = fileOr404(res, params.id);
  if (!f) return;
  const file = trickplay.sheetPath(f, Number(params.n));
  if (!file) return fail(res, 404, 'no such preview sheet');
  // Sheet URLs carry the file's signature (?k=), so they can be cached for good.
  res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'max-age=31536000, immutable' });
  fs.createReadStream(file).on('error', () => res.destroy()).pipe(res);
});

// The episodes someone is looking at get their previews first.
route('POST', '/api/previews/prioritize', ({ res, body }) => {
  trickplay.prioritize((Array.isArray(body.fileIds) ? body.fileIds : []).slice(0, 100).map(String));
  json(res, { ok: true });
});

route('POST', '/api/quit', ({ res }) => {
  json(res, { ok: true });
  setTimeout(shutdown, 100);
});

// ---- Lifetime: Nightcap runs as long as its window -------------------------------------
// When the server opened the window itself (the app, or `npm start`), it quits
// once no page has been open for a few seconds: the window was closed, or the
// browser quit or was killed. A reload reconnects well within that.
// --quit-when-closed does the same without opening a window (tests).
const FOLLOW_WINDOW = !process.argv.includes('--no-open') || process.argv.includes('--quit-when-closed');
const CLOSED_GRACE_MS = 4000;
const FIRST_PAGE_MS = 90e3; // the window may take a while to open the first time
const BOOT_ID = Math.random().toString(36).slice(2);
const pages = new Set();
let windowProcess = null;
let idleTimer = null;

function quitWhenIdle(ms) {
  clearTimeout(idleTimer);
  if (FOLLOW_WINDOW && !pages.size) idleTimer = setTimeout(() => !pages.size && shutdown(), ms);
}

// Every open page keeps this event stream open. `boot` tells a page that lost
// its engine whether it came back as a new one (then the page reloads).
route('GET', '/api/session', ({ req, res }) => {
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store' });
  res.write(`retry: 1000\nevent: hello\ndata: ${JSON.stringify({ boot: BOOT_ID })}\n\n`);
  pages.add(res);
  clearTimeout(idleTimer);
  const keepAlive = setInterval(() => res.write(': ping\n\n'), 30e3);
  req.on('close', () => {
    clearInterval(keepAlive);
    pages.delete(res);
    quitWhenIdle(CLOSED_GRACE_MS);
  });
});

// Opens the app window as a child of this server. If that browser instance
// is still running, the new process hands the window to it and exits.
function showWindow() {
  const running = windowProcess && windowProcess.exitCode == null && windowProcess.signalCode == null;
  const child = openWindow(`http://localhost:${PORT}`, { own: true });
  if (!running) windowProcess = child;
  quitWhenIdle(FIRST_PAGE_MS);
}

// Opening the app while it runs (scripts/make-mac-app.sh).
route('POST', '/api/window', ({ res }) => {
  showWindow();
  json(res, { ok: true });
});

// ---- Start ----------------------------------------------------------------------

// Ends everything this process started: the window it opened, ffmpeg
// conversions and the detection/preview workers' ffmpeg runs.
function endChildren() {
  if (process.platform === 'win32') return;
  let pids = [];
  try {
    pids = execFileSync('pgrep', ['-P', String(process.pid)], { encoding: 'utf8' }).split('\n').filter(Boolean).map(Number);
  } catch {} // none
  for (const pid of pids) {
    try {
      // The browser gets to close cleanly (it saves the page's settings).
      process.kill(pid, pid === windowProcess?.pid ? 'SIGTERM' : 'SIGKILL');
    } catch {}
  }
}

let shuttingDown = false;
function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  for (const s of [config, progress, libraryStore, analyzer, onlineSubs, subsync]) {
    try {
      s.flush();
    } catch {}
  }
  flushProbes();
  process.exit(0);
}
process.on('exit', endChildren);
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

server.listen(PORT, HOST, () => {
  const url = `http://localhost:${PORT}`;
  console.log(`Nightcap running at ${url}`);
  if (!FFMPEG) console.warn('ffmpeg not found: only browser-native formats will play and intro/credits detection is off. Install with: brew install ffmpeg');
  rescan();
  setInterval(rescan, 15 * 60 * 1000).unref();
  if (!process.argv.includes('--no-open')) {
    // A window left open by an engine that was killed reconnects within about
    // a second: adopt it instead of opening a second one.
    setTimeout(() => !pages.size && showWindow(), 1200);
  } else quitWhenIdle(FIRST_PAGE_MS);
});
