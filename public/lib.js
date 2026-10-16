// Shared state, API helpers, DOM helpers and the "what plays next" logic.

export const state = {
  lib: null, // payload of /api/library
  loadedAt: 0,
  titles: new Map(),
  where: new Map(), // fileId -> { title, season, index }
  dirty: false, // progress changed since the current page was drawn
};

async function request(method, url, body) {
  const opts = { method, headers: {} };
  if (body !== undefined) {
    opts.headers['content-type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(url, opts);
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || r.statusText);
  return data;
}
export const api = {
  get: (u) => request('GET', u),
  post: (u, b = {}) => request('POST', u, b),
  patch: (u, b = {}) => request('PATCH', u, b),
  del: (u) => request('DELETE', u),
};

export function setLibrary(lib) {
  state.lib = lib;
  state.loadedAt = Date.now();
  state.titles = new Map(lib.titles.map((t) => [t.id, t]));
  state.where = new Map();
  for (const t of lib.titles) {
    t.seasons.forEach((s, si) => s.episodes.forEach((fid, index) => state.where.set(fid, { title: t, season: s, seasonIndex: si, index })));
  }
  state.dirty = true;
  return lib;
}

export async function loadLibrary(force = false) {
  if (!force && state.lib && Date.now() - state.loadedAt < 5000) return state.lib;
  return setLibrary(await api.get('/api/library'));
}

// ---- DOM ------------------------------------------------------------------

const PROPS = new Set(['value', 'checked', 'selected', 'disabled', 'hidden', 'tabIndex']);
// Subtitle languages, as OpenSubtitles codes them.
const SUB_LANG_CODES = ['en', 'es', 'fr', 'de', 'it', 'pt-PT', 'pt-BR', 'nl', 'sv', 'no', 'da', 'fi', 'is', 'pl', 'cs', 'sk', 'hu', 'ro', 'bg', 'el', 'tr', 'ru', 'uk', 'sr', 'hr', 'sl', 'bs', 'mk', 'sq', 'et', 'lv', 'lt', 'ar', 'he', 'fa', 'hi', 'bn', 'ta', 'te', 'ml', 'ur', 'zh-CN', 'zh-TW', 'ja', 'ko', 'th', 'vi', 'id', 'ms', 'tl'];
const displayNames = typeof Intl.DisplayNames === 'function' ? new Intl.DisplayNames(['en'], { type: 'language' }) : null;
export function langLabel(code) {
  try {
    return displayNames?.of(code) || code;
  } catch {
    return code;
  }
}
export function subLanguages(current) {
  const codes = current && !SUB_LANG_CODES.some((c) => c.toLowerCase() === current.toLowerCase()) ? [...SUB_LANG_CODES, current] : SUB_LANG_CODES;
  return codes.map((code) => ({ code, name: langLabel(code) })).sort((a, b) => a.name.localeCompare(b.name));
}

export function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'style') for (const [sk, sv] of Object.entries(v)) el.style.setProperty(sk, sv);
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (PROPS.has(k)) el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

const ICONS = {
  play: '<path d="M8 5.14v13.72L19 12 8 5.14Z"/>',
  pause: '<path d="M6 5h4v14H6zM14 5h4v14h-4z"/>',
  info: '<path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm1 15h-2v-6h2v6Zm0-8h-2V7h2v2Z"/>',
  close: '<path d="M19 6.41 17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/>',
  check: '<path d="M9 16.17 4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/>',
  checkCircle: '<path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm-2 15-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/>',
  plus: '<path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/>',
  chevL: '<path d="M15.41 7.41 14 6l-6 6 6 6 1.41-1.41L10.83 12z"/>',
  chevR: '<path d="M8.59 16.59 10 18l6-6-6-6-1.41 1.41L13.17 12z"/>',
  folder: '<path d="M10 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-8l-2-2z"/>',
  drive: '<path d="M20 13H4a2 2 0 0 0-2 2v4a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-4a2 2 0 0 0-2-2ZM7 19a2 2 0 1 1 0-4 2 2 0 0 1 0 4ZM20 3H4a2 2 0 0 0-2 2v4a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2ZM7 9a2 2 0 1 1 0-4 2 2 0 0 1 0 4Z"/>',
  back: '<path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/>',
  up: '<path d="M7.41 15.41 12 10.83l4.59 4.58L18 14l-6-6-6 6z"/>',
  replay10: '<path d="M12 5V2L7 6l5 4V7a6 6 0 1 1-6 6H4a8 8 0 1 0 8-8Z"/><text x="12" y="16.6" font-size="6.6" font-weight="700" text-anchor="middle" font-family="-apple-system,Helvetica,Arial,sans-serif">10</text>',
  forward10: '<path d="M12 5V2l5 4-5 4V7a6 6 0 1 0 6 6h2a8 8 0 1 1-8-8Z"/><text x="12" y="16.6" font-size="6.6" font-weight="700" text-anchor="middle" font-family="-apple-system,Helvetica,Arial,sans-serif">10</text>',
  volume: '<path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3A4.5 4.5 0 0 0 14 7.97v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/>',
  volumeOff: '<path d="M16.5 12A4.5 4.5 0 0 0 14 7.97v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51A8.8 8.8 0 0 0 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3 3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06a8.99 8.99 0 0 0 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4 9.91 6.09 12 8.18V4z"/>',
  fullscreen: '<path d="M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z"/>',
  fullscreenExit: '<path d="M5 16h3v3h2v-5H5v2zm3-8H5v2h5V5H8v3zm6 11h2v-3h3v-2h-5v5zm2-11V5h-2v5h5V8h-3z"/>',
  next: '<path d="M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z"/>',
  episodes: '<path d="M4 6H2v14a2 2 0 0 0 2 2h14v-2H4V6zm16-4H8a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V4a2 2 0 0 0-2-2zm-8 12.5v-9l6 4.5-6 4.5z"/>',
  subtitles: '<path d="M20 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2zM4 12h4v2H4v-2zm10 6H4v-2h10v2zm6 0h-4v-2h4v2zm0-4H10v-2h10v2z"/>',
  refresh: '<path d="M17.65 6.35A7.96 7.96 0 0 0 12 4a8 8 0 1 0 7.73 10h-2.08A6 6 0 1 1 12 6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/>',
  speed: '<path d="M20.38 8.57l-1.23 1.85a8 8 0 0 1-.22 7.58H5.07A8 8 0 0 1 15.58 6.85l1.85-1.23A10 10 0 0 0 3.35 19a2 2 0 0 0 1.72 1h13.85a2 2 0 0 0 1.74-1 10 10 0 0 0-.27-10.44zm-9.79 6.84a2 2 0 0 0 2.83 0l5.66-8.49-8.49 5.66a2 2 0 0 0 0 2.83z"/>',
  skip: '<path d="M4 18l8.5-6L4 6v12zm9-12v12l8.5-6L13 6z"/>',
  trash: '<path d="M6 19a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/>',
};
export function ic(name) {
  const t = document.createElement('template');
  t.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
  return t.content.firstChild;
}

export function hashHue(s) {
  let x = 0;
  for (const c of s) x = (x * 31 + c.charCodeAt(0)) >>> 0;
  return x % 360;
}

// 16:9 artwork box with a tinted placeholder; portrait posters are shown
// whole over a blurred copy of themselves.
export function artBox(src, seed = '') {
  const hue = hashHue(seed);
  const box = h('div', { class: 'art', style: { '--ph': `linear-gradient(135deg, hsl(${hue} 42% 26%), hsl(${(hue + 50) % 360} 45% 11%))` } });
  if (!src) return box;
  const img = h('img', { alt: '', loading: 'lazy', decoding: 'async' });
  img.onload = () => {
    if (img.naturalHeight > img.naturalWidth * 0.9) {
      box.insertBefore(h('img', { class: 'blur loaded', src, alt: '' }), img);
      img.classList.add('fit');
    }
    img.classList.add('loaded');
  };
  img.src = src;
  box.append(img);
  return box;
}

export function fmtTime(s) {
  s = Math.max(0, Math.floor(s || 0));
  const hh = Math.floor(s / 3600);
  const mm = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, '0');
  return hh ? `${hh}:${String(mm).padStart(2, '0')}:${ss}` : `${mm}:${ss}`;
}
export function fmtDur(s) {
  if (!s) return '';
  const m = Math.round(s / 60);
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
}

let toastTimer;
export function toast(msg, ms = 2600) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), ms);
}

// ---- What plays next ---------------------------------------------------------

export const loc = (fid) => state.where.get(fid);
export const fileOf = (fid) => state.lib.files[fid];
export const progressOf = (fid) => state.lib.progress[fid];
export const markersOf = (fid) => state.lib.markers[fid];
const isMain = (s) => !s.extras && s.number !== 0;

export function epCode(fid) {
  const w = loc(fid);
  if (!w) return '';
  const f = fileOf(fid);
  if (w.title.kind === 'movie') return w.season.episodes.length > 1 ? f.name : '';
  if (w.season.extras) return 'Extra';
  if (w.season.number == null) return `${w.season.name} · E${f.number}`;
  return `S${w.season.number}:E${f.number}`;
}

// Episodes in viewing order. Specials and extras are not part of the main run.
export function playOrder(title) {
  const main = title.seasons.filter(isMain).flatMap((s) => s.episodes);
  return main.length ? main : title.seasons.flatMap((s) => s.episodes);
}

export function nextAfter(fid) {
  const w = loc(fid);
  if (!w) return null;
  if (!isMain(w.season) || w.title.kind === 'movie') return w.season.episodes[w.index + 1] || null;
  const order = playOrder(w.title);
  const i = order.indexOf(fid);
  return i >= 0 ? order[i + 1] || null : null;
}

// Netflix-style: resume the last thing touched, or the episode after it.
export function nextUp(title) {
  const order = playOrder(title);
  let latest = null;
  for (const s of title.seasons) {
    for (const id of s.episodes) {
      const p = progressOf(id);
      if (p && (!latest || p.updatedAt > latest.p.updatedAt)) latest = { id, p };
    }
  }
  if (!latest) return { fileId: order[0], start: 0, fresh: true };
  if (!latest.p.watched) {
    return latest.p.position > 5 ? { fileId: latest.id, start: latest.p.position, resume: true, updatedAt: latest.p.updatedAt } : { fileId: latest.id, start: 0, updatedAt: latest.p.updatedAt };
  }
  const next = nextAfter(latest.id);
  if (next) {
    const np = progressOf(next);
    const start = np && !np.watched && np.position > 5 ? np.position : 0;
    return { fileId: next, start, resume: start > 0, upNext: true, updatedAt: latest.p.updatedAt };
  }
  return { fileId: order[0], start: 0, again: true, updatedAt: latest.p.updatedAt };
}

export function nextUpLabel(title, nu) {
  if (title.kind === 'movie') return nu.resume ? 'Resume' : nu.again ? 'Watch again' : 'Play';
  const code = epCode(nu.fileId);
  return `${nu.resume ? 'Resume' : 'Play'} ${code}`;
}

export function continueWatching() {
  const out = [];
  for (const t of state.lib.titles) {
    const nu = nextUp(t);
    if (nu.fresh || nu.again) continue;
    if ((state.lib.hidden[t.id] || 0) >= nu.updatedAt) continue;
    out.push({ t, nu });
  }
  return out.sort((a, b) => b.nu.updatedAt - a.nu.updatedAt);
}

export function watchUrl(fid, start) {
  return `#/watch/${fid}${start != null ? `?t=${Math.floor(start)}` : ''}`;
}
