// Subtitles found online for library videos: search, download, and keep them
// with the app's data (never written into the media folders).
//
// On disk (DATA_DIR):
//   opensubtitles.json            API key, sign-in token, quota, show ids (owner-only file)
//   subs-downloaded.json          which subtitles were downloaded for which video
//   subs-downloaded/<fileId>/<n>.vtt

import fsp from 'node:fs/promises';
import path from 'node:path';
import { DATA_DIR, FFPROBE, JsonStore, ensureDir, run, sigHash } from './util.js';
import { OpenSubtitles, OpenSubtitlesError, movieHash, rankResults } from './opensubtitles.js';
import { textToVtt } from './media.js';

const DIR = ensureDir(path.join(DATA_DIR, 'subs-downloaded'));
const SEARCH_CACHE_MS = 60 * 60e3;
const NONE_FOUND_MS = 12 * 60 * 60e3;
export const LANG_RE = /^[a-z]{2,3}(?:-[a-z]{2})?$/i;

const langNames = new Intl.DisplayNames(['en'], { type: 'language' });
export function languageName(code) {
  try {
    return langNames.of(code) || code;
  } catch {
    return code;
  }
}

const stemOf = (p) => path.basename(p, path.extname(p));
const pad = (n) => String(n).padStart(2, '0');

export class OnlineSubs {
  constructor({ getTitle }) {
    this.getTitle = getTitle;
    this.os = new OpenSubtitles(new JsonStore(path.join(DATA_DIR, 'opensubtitles.json'), { shows: {} }, { mode: 0o600 }));
    this.index = new JsonStore(path.join(DATA_DIR, 'subs-downloaded.json'), { files: {} });
    this.hashes = new Map(); // sigHash -> moviehash
    this.fps = new Map();
    this.searches = new Map(); // cache key -> { at, value }
    this.noneFound = new Map(); // fileId|lang -> time
    this.inflight = new Map();
  }

  flush() {
    this.os.store.flush();
    this.index.flush();
  }

  status() {
    return this.os.status();
  }

  // ---- downloaded tracks --------------------------------------------------------

  entries(fileId) {
    return this.index.data.files[fileId] || [];
  }

  list(fileId) {
    const seen = {};
    return this.entries(fileId).map((e) => {
      const lang = languageName(e.lang);
      seen[lang] = (seen[lang] || 0) + 1;
      return {
        id: `d${e.n}`,
        label: `${lang} · OpenSubtitles${seen[lang] > 1 ? ` ${seen[lang]}` : ''}`,
        source: 'online',
        lang: e.lang,
        release: e.release,
        hashMatch: !!e.hashMatch,
      };
    });
  }

  async vtt(fileId, n) {
    if (!this.entries(fileId).some((e) => e.n === n)) return null;
    try {
      return await fsp.readFile(path.join(DIR, fileId, `${n}.vtt`), 'utf8');
    } catch {
      return null;
    }
  }

  async remove(fileId, n) {
    const list = this.entries(fileId);
    const i = list.findIndex((e) => e.n === n);
    if (i < 0) return false;
    list.splice(i, 1);
    if (!list.length) delete this.index.data.files[fileId];
    this.index.save();
    await fsp.rm(path.join(DIR, fileId, `${n}.vtt`), { force: true });
    return true;
  }

  // ---- search -------------------------------------------------------------------

  async hashOf(file) {
    const key = sigHash(file);
    if (!this.hashes.has(key)) this.hashes.set(key, await movieHash(file.path, file.size).catch(() => null));
    return this.hashes.get(key);
  }

  async fpsOf(file) {
    if (this.fps.has(file.id) || !FFPROBE) return this.fps.get(file.id) ?? null;
    const r = await run(FFPROBE, ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=avg_frame_rate,r_frame_rate', '-of', 'json', file.path], { timeout: 20000 }).catch(() => null);
    let fps = null;
    try {
      const s = JSON.parse(r.stdout.toString()).streams[0];
      const [a, b] = String(s.avg_frame_rate !== '0/0' ? s.avg_frame_rate : s.r_frame_rate).split('/').map(Number);
      fps = b ? Math.round((a / b) * 1000) / 1000 : null;
    } catch {}
    this.fps.set(file.id, fps);
    return fps;
  }

  describe(file) {
    const title = this.getTitle(file.titleId);
    const season = title?.seasons[file.season];
    const episode = title?.kind === 'show' && !season?.extras && season?.number != null && file.number != null
      ? { season: season.number, episode: file.number }
      : null;
    return { title, episode };
  }

  // What the search box starts with.
  defaultQuery(file) {
    const { title, episode } = this.describe(file);
    if (!title) return stemOf(file.path);
    if (episode) return `${title.name} S${pad(episode.season)}E${pad(episode.episode)}`;
    if (title.kind === 'movie') return `${title.name}${title.year ? ` ${title.year}` : ''}`;
    return stemOf(file.path);
  }

  async search(file, { language, query } = {}) {
    if (!LANG_RE.test(language || '')) throw new OpenSubtitlesError('Pick a subtitle language', 400);
    const lang = language.toLowerCase();
    const q = (query || '').trim().slice(0, 200);
    const custom = q && q !== this.defaultQuery(file);
    const cacheKey = `${file.id}|${lang}|${custom ? q : ''}`;
    const hit = this.searches.get(cacheKey);
    if (hit && Date.now() - hit.at < SEARCH_CACHE_MS) return hit.value;

    const [hash, fps] = await Promise.all([this.hashOf(file), this.fpsOf(file)]);
    const { title, episode } = this.describe(file);
    const base = { languages: lang, moviehash: hash };
    const attempts = [];
    if (custom) {
      attempts.push({ ...base, query: q });
    } else if (episode) {
      const show = await this.os.findShow(title.name, title.year).catch(() => null);
      if (show) attempts.push({ ...base, parent_feature_id: show.id, season_number: episode.season, episode_number: episode.episode });
      else attempts.push({ ...base, query: title.name, season_number: episode.season, episode_number: episode.episode, type: 'episode' });
    } else if (title?.kind === 'movie') {
      attempts.push({ ...base, query: title.name, year: title.year, type: 'movie' });
    }
    // Fall back to the exact file alone, then to what the file name says.
    if (hash) attempts.push({ moviehash: hash, languages: lang });
    attempts.push({ ...base, query: stemOf(file.path) });

    let results = [];
    for (const params of attempts) {
      results = await this.os.search(params);
      if (results.length) break;
    }
    const value = { query: custom ? q : this.defaultQuery(file), results: rankResults(results.filter((r) => r.language.toLowerCase() === lang || !r.language), { fps }) };
    this.searches.set(cacheKey, { at: Date.now(), value });
    return value;
  }

  // ---- download -----------------------------------------------------------------

  async fetch(file, pick) {
    const id = Number(pick?.id);
    if (!Number.isInteger(id) || id <= 0) throw new OpenSubtitlesError('Unknown subtitle', 400);
    const existing = this.entries(file.id).find((e) => e.osFileId === id);
    if (existing) return this.list(file.id).find((t) => t.id === `d${existing.n}`);

    const got = await this.os.download(id);
    const vtt = await textToVtt(got.text, path.extname(got.fileName || '').toLowerCase());
    if (!vtt || !vtt.includes('-->')) throw new OpenSubtitlesError('The downloaded subtitle could not be read', 502);
    const list = (this.index.data.files[file.id] ||= []);
    // Never reused, so timing fixes and remembered delays can't attach to another file.
    const n = (this.index.data.seq = Math.max(this.index.data.seq || 0, ...list.map((e) => e.n)) + 1);
    await fsp.mkdir(path.join(DIR, file.id), { recursive: true });
    await fsp.writeFile(path.join(DIR, file.id, `${n}.vtt`), vtt);
    const lang = LANG_RE.test(pick.language || '') ? pick.language : 'und';
    list.push({
      n,
      provider: 'opensubtitles',
      osFileId: id,
      subtitleId: String(pick.subtitleId || '').slice(0, 40),
      lang,
      release: String(pick.release || got.fileName || '').slice(0, 300),
      hashMatch: !!pick.hashMatch,
      hearingImpaired: !!pick.hearingImpaired,
      at: Date.now(),
    });
    this.index.save();
    this.noneFound.delete(`${file.id}|${lang.toLowerCase()}`);
    return this.list(file.id).find((t) => t.id === `d${n}`);
  }

  // Fetches the best subtitle in `language` unless the video already has one.
  // Used when someone watches with subtitles on and the episode has none.
  auto(file, language) {
    const key = `${file.id}|${String(language).toLowerCase()}`;
    if (this.inflight.has(key)) return this.inflight.get(key);
    const p = (async () => {
      const have = this.list(file.id).find((t) => t.lang.toLowerCase() === String(language).toLowerCase());
      if (have) return { track: have };
      const missed = this.noneFound.get(key);
      if (missed && Date.now() - missed < NONE_FOUND_MS) return { track: null };
      // Out of downloads until the allowance resets: don't search for nothing.
      if (this.os.status().remaining === 0) throw new OpenSubtitlesError('No subtitle downloads left today. Sign in to OpenSubtitles in Settings for more.', 429);
      const { results } = await this.search(file, { language });
      const pick = results.find((r) => !r.foreignOnly && !r.machineTranslated);
      if (!pick) {
        this.noneFound.set(key, Date.now());
        return { track: null };
      }
      return { track: await this.fetch(file, pick), fresh: true };
    })().finally(() => this.inflight.delete(key));
    this.inflight.set(key, p);
    return p;
  }
}
