// Walks library folders and turns them into shows (with seasons and
// episodes) and movies.
//
// Library folder kinds:
//   auto   - decide per folder: season-like subfolders or episode-numbered
//            files make a show, a folder with one video is a movie
//   shows  - every top-level subfolder is a show, its subfolders are seasons
//   movies - every video file is a movie
// A library folder that is itself a show (it contains "Season 1", "Season 2"
// …) is detected as one show in any mode except movies.

import fsp from 'node:fs/promises';
import path from 'node:path';
import { hashId, naturalCompare } from './util.js';

export const VIDEO_EXT = new Set(['.mp4', '.m4v', '.mkv', '.webm', '.mov', '.avi', '.wmv', '.flv', '.mpg', '.mpeg', '.ts', '.m2ts', '.mts', '.3gp', '.ogv', '.vob', '.divx']);
const SUB_EXT = new Set(['.srt', '.vtt', '.ass', '.ssa']);
const IMG_EXT = new Set(['.jpg', '.jpeg', '.png', '.webp']);
const SKIP_DIRS = /^(\$recycle\.bin|system volume information|lost\+found|@eadir|#recycle|\.?trash.*)$/i;
const EXTRA_DIRS = /^(extras?|featurettes?|behind[ ._-]the[ ._-]scenes|deleted[ ._-]scenes|interviews?|trailers?|samples?|shorts|bonus( features)?)$/i;
const SUB_DIRS = /^(subs?|subtitles?)$/i;
const PART_RE = /(?:^|[\s._-])(?:cd|disc|disk|part|pt)[\s._-]*(\d{1,2})(?:$|[\s._-])/i;
const MAX_DEPTH = 8;

const TAG_RE = /(?:^|[\s.\-_([])(?:2160p|1080[pi]|720p|576p|480p|4k|uhd|hdr10\+?|hdr|dv|dovi|blu-?ray|bdrip|brrip|bdremux|remux|web-?dl|web-?rip|webrip|web|hdtv|dvdrip|dvd|hdrip|xvid|divx|x264|x265|h\.?26[45]|hevc|avc|aac(?:2\.0)?|ac3|e-?ac-?3|dts(?:-hd)?|truehd|atmos|dd\+?5\.1|ddp?5\.1|10bit|8bit|proper|repack|extended|unrated|imax|multi|dual[\s.-]?audio|amzn|nf|hulu|dsnp|hmax|atvp)(?=$|[\s.\-_)\]])/i;

export const stemOf = (name) => name.slice(0, name.length - path.extname(name).length);

// dots: treat dots as word separators (release-style names like "Mr.Robot.S01E01").
export function cleanTitle(raw, dots = !/\s/.test(raw.trim())) {
  let s = raw.replace(/\[[^\]]*\]|\{[^}]*\}/g, ' ');
  if (dots) s = s.replace(/[._]+/g, ' ');
  else s = s.replace(/_+/g, ' ');
  const tag = s.search(TAG_RE);
  if (tag > 0) s = s.slice(0, tag);
  s = s.replace(/\(\s*\)/g, ' ').replace(/\s+/g, ' ');
  return s.replace(/^[\s\-–—:.,(]+|[\s\-–—:.,(]+$/g, '').trim();
}

// "Inception (2010)" -> { name: "Inception", year: 2010 }
export function parseTitle(raw) {
  let s = cleanTitle(raw);
  let year = null;
  const paren = s.match(/^(.+?)\s*\(((?:19|20)\d{2})\)/);
  if (paren) {
    s = paren[1];
    year = Number(paren[2]);
  } else {
    const m = s.match(/^(.+?)\s+((?:19|20)\d{2})$/);
    if (m) {
      s = m[1];
      year = Number(m[2]);
    }
  }
  return { name: s.trim() || cleanTitle(raw) || raw, year };
}

// Episode numbering from a file name. `strong` means the name itself says it
// is an episode (S01E02, 1x02, Episode 2, " - 02 ") rather than just starting
// with a number.
export function parseEpisode(stem) {
  const patterns = [
    [/(?:^|[^a-z0-9])season[\s._-]*(\d{1,2})[\s._,-]*episode[\s._-]*(\d{1,3})(?:\s*(?:&|\+|and)\s*(\d{1,3}))?(?![0-9])/i, (m) => [m[1], m[2]]],
    [/(?:^|[^a-z0-9])s(\d{1,2})[\s._-]*e(\d{1,3})(?:-?e(\d{1,3}))?/i, (m) => [m[1], m[2]]],
    [/(?:^|[^a-z0-9])(\d{1,2})x(\d{2,3})(?![0-9p])/i, (m) => [m[1], m[2]]],
    [/(?:^|[^a-z0-9])(?:episode|ep|e)[\s._-]*(\d{1,3})(?:\s*(?:&|\+|and|-)\s*(?:e|ep)?(\d{1,3}))?(?![0-9])/i, (m) => [null, m[1]]],
    [/\s-\s(\d{1,3})(?:v\d)?(?=$|\s|\[|\()/i, (m) => [null, m[1]]],
  ];
  for (const [re, pick] of patterns) {
    const m = stem.match(re);
    if (!m) continue;
    const [season, episode] = pick(m);
    const rest = stem.slice(m.index + m[0].length);
    return {
      season: season == null ? null : Number(season),
      episode: Number(episode),
      title: cleanTitle(rest.replace(/^[\s._-]+/, ''), !/\s/.test(stem)),
      strong: true,
    };
  }
  const lead = stem.match(/^(\d{1,3})(?![0-9])(?:[\s._-]+(.*))?$/);
  if (lead) return { season: null, episode: Number(lead[1]), title: cleanTitle(lead[2] || '', !/\s/.test(stem)), strong: false };
  return { season: null, episode: null, title: cleanTitle(stem), strong: false };
}

const SEASON_WORD = '(?:season|series|saison|staffel|temporada|stagione)';
// "Season 1, 2 & 3", "Seasons 1-9", "S01-S05", "Complete": a whole-show pack, not one season.
const MULTI_SEASON = new RegExp(`${SEASON_WORD}s?[\\s._-]*\\d{1,3}\\s*(?:[,&+]|-|and|to)\\s*\\d|(?:^|[\\s._-])s\\d{1,2}\\s*-\\s*s?\\d{1,2}(?![0-9])|(?:^|[\\s._-])complete(?:$|[\\s._-])`, 'i');

export function seasonNumber(name) {
  if (/^specials?$/i.test(name.trim())) return 0;
  if (MULTI_SEASON.test(name)) return null;
  let m = name.match(new RegExp(`(?:^|[\\s._-])${SEASON_WORD}[\\s._-]*(\\d{1,3})(?![0-9])`, 'i'));
  if (m) return Number(m[1]);
  m = name.match(/(?:^|[\s._-])s(\d{1,2})(?=$|[\s._-])/i);
  if (m) return Number(m[1]);
  m = name.trim().match(/^(\d{1,2})$/);
  if (m) return Number(m[1]);
  return null;
}

// The show a season folder names, if any: "Breaking.Bad.S01.720p" -> "breaking bad",
// "Season 01" -> "" (a bare season label).
function seasonOwner(name) {
  const m = name.match(new RegExp(`^(.*?)(?:^|[\\s._-])(?:${SEASON_WORD}[\\s._-]*\\d|s\\d{1,2}(?=$|[\\s._-]))`, 'i'));
  return normName(m ? parseTitle(m[1] || ' ').name : '');
}
const normName = (s) => s.toLowerCase().replace(/\(\d{4}\)/g, '').replace(/[^a-z0-9]+/g, ' ').trim();

// Is `dir` a season of the show folder `parent`? Bare labels always are;
// "Show.S01" release folders only when the show name matches the parent.
function isSeasonOf(dir, parent) {
  if (seasonNumber(dir.name) === null) return false;
  if (dir.dirs.some((d) => seasonNumber(d.name) !== null)) return false;
  const owner = seasonOwner(dir.name);
  if (!owner || owner === 'the') return true;
  const parentName = normName(parseTitle(parent.name).name.replace(SHOW_SUFFIX, ''));
  return parentName.includes(owner) || owner.includes(parentName);
}

async function walk(dir, depth, seen) {
  const node = { name: path.basename(dir), path: dir, videos: [], subs: [], images: [], dirs: [], total: 0 };
  let entries;
  try {
    entries = await fsp.readdir(dir, { withFileTypes: true });
  } catch {
    return node;
  }
  await Promise.all(
    entries.map(async (e) => {
      if (e.name.startsWith('.')) return;
      const full = path.join(dir, e.name);
      let isDir = e.isDirectory();
      let isFile = e.isFile();
      if (e.isSymbolicLink()) {
        try {
          const st = await fsp.stat(full);
          isDir = st.isDirectory();
          isFile = st.isFile();
        } catch {
          return;
        }
      }
      if (isDir) {
        if (depth >= MAX_DEPTH || SKIP_DIRS.test(e.name)) return;
        let real;
        try {
          real = await fsp.realpath(full);
        } catch {
          return;
        }
        if (seen.has(real)) return;
        seen.add(real);
        const child = await walk(full, depth + 1, seen);
        if (child.total > 0) node.dirs.push(child);
        else if (SUB_DIRS.test(e.name) || child.subs.length) {
          // Subtitle folders next to the video ("Subs/English.srt", "Subs/<episode>/2_English.srt").
          node.subs.push(...child.subs.map((s) => path.join(e.name, s)));
        }
        return;
      }
      if (!isFile) return;
      const ext = path.extname(e.name).toLowerCase();
      if (VIDEO_EXT.has(ext)) {
        if (/(?:^|[\s._-])sample$/i.test(stemOf(e.name))) return;
        try {
          const st = await fsp.stat(full);
          node.videos.push({ name: e.name, path: full, size: st.size, mtime: Math.round(st.mtimeMs), dir: node });
        } catch {}
      } else if (SUB_EXT.has(ext)) node.subs.push(e.name);
      else if (IMG_EXT.has(ext)) node.images.push(e.name);
    }),
  );
  node.videos.sort((a, b) => naturalCompare(a.name, b.name));
  node.dirs.sort((a, b) => naturalCompare(a.name, b.name));
  node.total = node.videos.length + node.dirs.reduce((s, d) => s + d.total, 0);
  return node;
}

const contentDirs = (node) => node.dirs.filter((d) => !EXTRA_DIRS.test(d.name));

function collectVideos(node, out = []) {
  out.push(...node.videos);
  for (const d of contentDirs(node)) collectVideos(d, out);
  return out;
}

// "Severance.S02E01.1080p" -> "Severance"; "" when the name has no show part.
function fileShowName(stem) {
  const p = parseEpisode(stem);
  if (!p.strong || p.season == null) return '';
  const m = stem.match(/^(.*?)[\s._-]+(?:s\d{1,2}[\s._-]*e\d|\d{1,2}x\d{2}|season[\s._-]*\d)/i);
  return m ? cleanTitle(m[1]) : '';
}
const sameShow = (a, b) => !!a && !!b && (a.includes(b) || b.includes(a));

function looksLikeShow(node) {
  const dirs = contentDirs(node);
  const seasonDirs = dirs.filter((d) => isSeasonOf(d, node));
  if (seasonDirs.length && seasonDirs.length >= Math.ceil(dirs.length / 2)) return true;
  const eps = node.videos.filter((v) => parseEpisode(stemOf(v.name)).strong);
  if (node.videos.length < 2 || eps.length < Math.max(2, node.videos.length * 0.6)) return false;
  // Episodes of this folder's show, not a Downloads folder holding some episodes.
  const owners = new Set(eps.map((v) => normName(fileShowName(stemOf(v.name)))).filter(Boolean));
  if (!owners.size) return true;
  return owners.size === 1 && sameShow([...owners][0], normName(showName(node).name));
}

// Loose files named like episodes ("Severance.S02E01.mkv") become shows,
// grouped by the show name in the file name; everything else is a movie.
function looseSpecs(node, videos = node.videos, named = false) {
  const shows = new Map();
  const out = [];
  for (const v of videos) {
    const stem = stemOf(v.name);
    const show = fileShowName(stem);
    if (show) {
      const key = normName(show);
      if (!shows.has(key)) shows.set(key, { kind: 'show', node, name: show, videos: [], seasonDirs: [] });
      shows.get(key).videos.push(v);
    } else out.push({ kind: 'movie', node, videos: [v], named });
  }
  return [...shows.values(), ...out];
}

// A show folder may also hold its films ("Films/Fight the Future/") and
// bonus material ("Extras/"). Films become their own titles; extras become an
// "Extras" section at the end of the show.
function classifyShow(node, strict) {
  const out = [];
  const seasonDirs = [];
  const extraDirs = [];
  for (const d of node.dirs) {
    if (EXTRA_DIRS.test(d.name)) extraDirs.push(d);
    else if (strict || isSeasonOf(d, node)) seasonDirs.push(d);
    else {
      const inner = classifyAuto(d);
      if (inner.length && inner.every((x) => x.kind === 'movie')) out.push(...inner);
      else seasonDirs.push(d);
    }
  }
  return [{ kind: 'show', node, seasonDirs, extraDirs }, ...out];
}

function classifyAuto(node) {
  if (looksLikeShow(node)) return classifyShow(node, false);
  const dirs = contentDirs(node);
  if (!dirs.length) {
    const vids = node.videos;
    if (vids.length === 1) return looseSpecs(node, vids, true);
    if (vids.length > 1 && vids.every((v) => PART_RE.test(stemOf(v.name)))) {
      return [{ kind: 'movie', node, videos: vids, named: true }];
    }
    const numbered = vids.filter((v) => parseEpisode(stemOf(v.name)).episode != null).length;
    if (vids.length > 1 && numbered >= vids.length * 0.6) return [{ kind: 'show', node }];
    return looseSpecs(node);
  }
  const out = looseSpecs(node, node.videos, node.videos.length === 1);
  for (const d of dirs) out.push(...classifyAuto(d));
  return out;
}

function classifyRoot(root, kind) {
  if (kind === 'movies') {
    return collectVideos(root).map((v) => ({ kind: 'movie', node: v.dir, videos: [v], named: v.dir.videos.length === 1 && v.dir !== root }));
  }
  if (looksLikeShow(root)) return classifyShow(root, kind === 'shows');
  const out = looseSpecs(root);
  for (const d of contentDirs(root)) {
    if (kind === 'shows') out.push(...classifyShow(d, true));
    else out.push(...classifyAuto(d));
  }
  return out;
}

const pickImage = (node, names, stem) => {
  const imgs = node.images;
  const want = stem
    ? [stem, ...names.map((n) => `${stem}-${n}`)]
    : names;
  for (const w of want) {
    const hit = imgs.find((i) => stemOf(i).toLowerCase() === w.toLowerCase());
    if (hit) return path.join(node.path, hit);
  }
  return null;
};
const POSTER = ['poster', 'folder', 'cover', 'show', 'default', 'movie'];
const BACKDROP = ['fanart', 'backdrop', 'background', 'landscape', 'art'];

function subtitleLabel(rel, stem) {
  const base = stemOf(path.basename(rel));
  let rest = base.toLowerCase().startsWith(stem.toLowerCase()) ? base.slice(stem.length) : base;
  rest = rest.replace(/^[\s._-]+/, '').replace(/^\d+_/, '');
  const LANGS = { en: 'English', eng: 'English', es: 'Spanish', spa: 'Spanish', fr: 'French', fre: 'French', fra: 'French', de: 'German', ger: 'German', deu: 'German', it: 'Italian', ita: 'Italian', pt: 'Portuguese', por: 'Portuguese', ja: 'Japanese', jpn: 'Japanese', hi: 'Hindi', hin: 'Hindi', ko: 'Korean', kor: 'Korean', zh: 'Chinese', chi: 'Chinese', zho: 'Chinese', ru: 'Russian', rus: 'Russian', ar: 'Arabic', ara: 'Arabic', nl: 'Dutch', dut: 'Dutch' };
  const words = rest.split(/[\s._-]+/).filter(Boolean).map((w) => LANGS[w.toLowerCase()] || w);
  return words.join(' ') || 'External';
}

function subtitlesFor(video) {
  const node = video.dir;
  const stem = stemOf(video.name);
  const only = node.videos.length === 1;
  return node.subs
    .filter((rel) => {
      if (only) return true;
      const segs = rel.split(path.sep);
      return stemOf(segs.at(-1)).toLowerCase().startsWith(stem.toLowerCase()) || segs.slice(0, -1).includes(stem);
    })
    .map((rel) => ({ path: path.join(node.path, rel), label: subtitleLabel(rel, stem) }));
}

const SHOW_SUFFIX = /\s+(?:-\s+)?(?:(?:the\s+)?complete(?:\s+(?:series|seasons?|collection))?|(?:seasons?|series)\s*\d.*|s\d{1,2}(?:e\d{1,3})?(?:\s*-\s*s?\d{1,2})?(?:\s.*)?)$/i;

function showName(node) {
  // "The X-Files Season 1, 2 … + Extras DVDRip" -> "The X-Files". A season
  // folder added on its own ("Season 1") is named after its parent.
  for (const raw of [node.name, path.basename(path.dirname(node.path))]) {
    const { name, year } = parseTitle(raw);
    const stripped = ` ${name}`.replace(SHOW_SUFFIX, '').trim();
    if (stripped && seasonNumber(stripped) === null) return { name: stripped, year };
  }
  return parseTitle(node.name);
}

function collectAll(node, out = []) {
  out.push(...node.videos);
  for (const d of node.dirs) collectAll(d, out);
  return out;
}

function buildShow(spec) {
  const node = spec.node;
  const { name, year } = spec.name ? parseTitle(spec.name) : showName(node);
  const seasons = new Map(); // key -> { number, name, poster, videos }
  const addTo = (key, number, label, poster, v) => {
    if (!seasons.has(key)) seasons.set(key, { number, name: label, poster, videos: [] });
    seasons.get(key).videos.push(v);
  };
  const seasonDirs = spec.seasonDirs ?? contentDirs(node);
  for (const d of seasonDirs) {
    const vids = collectVideos(d);
    let num = seasonNumber(d.name);
    if (num === null) {
      const parsed = vids.map((v) => parseEpisode(stemOf(v.name)).season).filter((n) => n != null);
      if (parsed.length >= vids.length * 0.6 && parsed.every((n) => n === parsed[0])) num = parsed[0];
    }
    const key = num === null ? `dir:${d.name}` : `n:${num}`;
    const label = num === null ? cleanTitle(d.name) || d.name : num === 0 ? 'Specials' : `Season ${num}`;
    for (const v of vids) addTo(key, num, label, pickImage(d, POSTER), v);
  }
  // Loose episode files in the show folder: use the season in their name.
  for (const v of spec.videos ?? node.videos) {
    const p = parseEpisode(stemOf(v.name));
    const num = p.season ?? (seasonDirs.length ? null : 1);
    const key = num === null ? 'other' : `n:${num}`;
    const label = num === null ? 'Other episodes' : num === 0 ? 'Specials' : `Season ${num}`;
    addTo(key, num, label, null, v);
  }
  const extras = (spec.extraDirs ?? []).flatMap((d) => collectAll(d).map((v) => ({ v, root: node.path })));
  if (extras.length) {
    seasons.set('extras', { number: null, name: 'Extras', poster: null, extras: true, videos: extras.map((x) => x.v) });
  }
  return { kind: 'show', name, year, node, seasons: [...seasons.values()] };
}

function buildMovie(spec) {
  const v = spec.videos[0];
  const src = spec.named ? spec.node.name : stemOf(v.name);
  const { name, year } = parseTitle(src);
  return { kind: 'movie', name, year, node: spec.node, videos: spec.videos, named: spec.named };
}

const normKey = (name, year) => `${name.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()}|${year || ''}`;

function sortEpisodes(videos) {
  const parsed = videos.map((v) => ({ v, p: parseEpisode(stemOf(v.name)) }));
  if (parsed.every((x) => x.p.episode != null)) {
    parsed.sort((a, b) => a.p.episode - b.p.episode || naturalCompare(a.v.name, b.v.name));
  } else {
    parsed.sort((a, b) => naturalCompare(a.v.name, b.v.name));
  }
  return parsed;
}

function seasonOrder(a, b) {
  const rank = (s) => (s.extras ? 1e7 : s.number === null ? 1e6 : s.number === 0 ? 1e5 : s.number);
  return rank(a) - rank(b) || naturalCompare(a.name, b.name);
}

export async function scanLibrary(folders) {
  const titles = new Map();
  const files = {};
  const folderStatus = {};
  for (const folder of folders) {
    let real;
    try {
      const st = await fsp.stat(folder.path);
      if (!st.isDirectory()) throw new Error('not a folder');
      real = await fsp.realpath(folder.path);
    } catch (e) {
      folderStatus[folder.id] = { online: false, error: e.code === 'ENOENT' ? 'Folder not found (drive unplugged?)' : e.message };
      continue;
    }
    const tree = await walk(folder.path, 0, new Set([real]));
    const specs = classifyRoot(tree, folder.kind || 'auto');
    let count = 0;
    for (const spec of specs) {
      if (spec.kind === 'show') {
        const show = buildShow(spec);
        if (!show.seasons.length) continue;
        const key = `show:${normKey(show.name, show.year)}`;
        const existing = titles.get(key);
        if (existing) {
          // Same show split across folders or drives: merge the seasons.
          for (const s of show.seasons) {
            const twin = existing.seasons.find((x) => (x.number !== null && x.number === s.number) || (x.number === null && x.name === s.name));
            if (twin) twin.videos.push(...s.videos);
            else existing.seasons.push(s);
          }
          existing.folderIds.add(folder.id);
        } else {
          titles.set(key, { ...show, key, folderIds: new Set([folder.id]) });
        }
      } else {
        const movie = buildMovie(spec);
        const key = `movie:${spec.videos[0].path}`;
        if (!titles.has(key)) titles.set(key, { ...movie, key, folderIds: new Set([folder.id]) });
      }
      count++;
    }
    folderStatus[folder.id] = { online: true, titles: count, videos: tree.total, scannedAt: Date.now() };
  }

  const out = [];
  for (const t of titles.values()) {
    const id = hashId(t.key);
    const node = t.node;
    const stem = t.kind === 'movie' && !t.named ? stemOf(t.videos[0].name) : null;
    const title = {
      id,
      kind: t.kind,
      name: t.name,
      year: t.year,
      folderIds: [...t.folderIds],
      poster: pickImage(node, POSTER, stem),
      backdrop: pickImage(node, BACKDROP, stem),
      seasons: [],
      addedAt: 0,
    };
    const groups = t.kind === 'show' ? t.seasons.sort(seasonOrder) : [{ number: null, name: '', poster: null, videos: t.videos }];
    groups.forEach((g) => {
      const season = { id: hashId(`${id}|${g.name}`), number: g.number, name: g.name, poster: g.poster, episodes: [] };
      if (g.extras) season.extras = true;
      const seen = new Set();
      const ordered = g.extras
        ? g.videos.map((v) => ({ v, p: {} })).sort((a, b) => naturalCompare(a.v.path, b.v.path))
        : sortEpisodes(g.videos);
      for (const { v, p } of ordered) {
        const fid = hashId(v.path);
        if (files[fid] || seen.has(fid)) continue;
        seen.add(fid);
        const vstem = stemOf(v.name);
        const part = PART_RE.exec(vstem);
        let name;
        if (t.kind === 'movie') name = t.videos.length > 1 ? `Part ${part ? Number(part[1]) : season.episodes.length + 1}` : t.name;
        else if (g.extras) name = path.relative(node.path, v.path).split(path.sep).map((x, i, a) => (i === a.length - 1 ? cleanTitle(stemOf(x)) : x)).filter((x) => !EXTRA_DIRS.test(x)).join(' › ');
        else name = p.title && p.title.toLowerCase() !== t.name.toLowerCase() ? p.title : p.episode != null ? `Episode ${p.episode}` : cleanTitle(vstem);
        files[fid] = {
          id: fid,
          titleId: id,
          season: title.seasons.length, // index once this season is added below
          number: t.kind === 'show' && !g.extras ? p.episode ?? season.episodes.length + 1 : null,
          name,
          path: v.path,
          size: v.size,
          mtime: v.mtime,
          thumb: pickImage(v.dir, ['thumb'], vstem),
          subs: subtitlesFor(v),
        };
        season.episodes.push(fid);
        title.addedAt = Math.max(title.addedAt, v.mtime);
      }
      if (season.episodes.length) title.seasons.push(season);
    });
    if (title.seasons.length) out.push(title);
  }
  out.sort((a, b) => naturalCompare(a.name, b.name));
  return { titles: out, files, folderStatus, scannedAt: Date.now() };
}
