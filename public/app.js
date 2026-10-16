import {
  state, api, h, ic, artBox, fmtDur, fmtTime, toast, loadLibrary, setLibrary, loc, fileOf, progressOf, markersOf,
  epCode, playOrder, nextUp, nextUpLabel, continueWatching, watchUrl,
} from './lib.js';
import { Player } from './player.js';

const view = document.getElementById('view');
const modalRoot = document.getElementById('modal-root');
const nav = document.getElementById('nav');
const searchInput = document.getElementById('search-input');
const activity = document.getElementById('activity');
const player = new Player(document.getElementById('player-root'));

const page = { base: null, query: '', scroll: {} };

// ---- Cards & rows -------------------------------------------------------------

function titleMeta(t) {
  const parts = [];
  if (t.year) parts.push(t.year);
  if (t.kind === 'show') {
    const seasons = t.seasons.filter((s) => !s.extras);
    parts.push(seasons.length === 1 ? `${seasons[0].episodes.length} episodes` : `${seasons.length} seasons`);
  } else {
    const d = t.seasons[0].episodes.reduce((s, id) => s + (fileOf(id)?.duration || 0), 0);
    if (d) parts.push(fmtDur(d));
  }
  return parts.join(' · ');
}

function titleCard(t, { nu = null, removable = false } = {}) {
  const art = artBox(`/api/art/title/${t.id}?type=card&w=480`, t.name);
  const sub = nu ? `${t.kind === 'show' ? `${epCode(nu.fileId)} · ${fileOf(nu.fileId).name}` : nu.resume ? `${fmtTime(fileOf(nu.fileId).duration - nu.start)} left` : ''}` : titleMeta(t);
  if (nu) {
    art.append(h('div', { class: 'play-hint' }, ic('play')));
    const p = progressOf(nu.fileId);
    if (nu.resume && p?.duration) art.append(h('div', { class: 'bar' }, h('i', { style: { width: `${(p.position / p.duration) * 100}%` } })));
  }
  const isNew = !nu && Date.now() - t.addedAt < 7 * 864e5;
  const el = h('a', { class: 'card', href: nu ? watchUrl(nu.fileId, nu.start) : `#/title/${t.id}`, title: t.name },
    art,
    isNew ? h('span', { class: 'badge-new' }, 'NEW') : null,
    h('div', { class: 'label' }, t.name, sub ? h('small', {}, sub) : null),
    removable ? h('button', { class: 'card-x', title: 'Remove from Continue Watching', onclick: async (e) => {
      e.preventDefault();
      e.stopPropagation();
      const r = await api.post('/api/hide', { titleId: t.id });
      state.lib.hidden = r.hidden;
      el.remove();
    } }, ic('close')) : null);
  return el;
}

function row(title, cards) {
  if (!cards.length) return null;
  const track = h('div', { class: 'track' }, cards);
  const left = h('button', { class: 'arrow left', 'aria-label': 'Scroll left', disabled: true }, ic('chevL'));
  const right = h('button', { class: 'arrow right', 'aria-label': 'Scroll right' }, ic('chevR'));
  const sync = () => {
    left.disabled = track.scrollLeft < 8;
    right.disabled = track.scrollLeft + track.clientWidth >= track.scrollWidth - 8;
  };
  left.onclick = () => track.scrollBy({ left: -track.clientWidth * 0.9, behavior: 'smooth' });
  right.onclick = () => track.scrollBy({ left: track.clientWidth * 0.9, behavior: 'smooth' });
  track.addEventListener('scroll', sync, { passive: true });
  requestAnimationFrame(sync);
  return h('section', { class: 'row' }, h('h2', {}, title), h('div', { class: 'slider' }, left, track, right));
}

// ---- Pages --------------------------------------------------------------------

function renderWelcome() {
  view.replaceChildren(h('div', { class: 'welcome' }, h('div', {},
    h('h1', {}, 'Your movies and shows, on your Mac'),
    h('p', {}, 'Add the folders where your movies and TV series live. Season folders become seasons, playback resumes where you left off, and intros and end credits are detected on your machine so you can skip them.'),
    h('button', { class: 'btn btn-accent', onclick: () => openPicker() }, ic('plus'), 'Add a folder'))));
}

function hero(t) {
  const nu = nextUp(t);
  const art = h('div', { class: 'hero-art' });
  const img = new Image();
  img.onload = () => (art.style.backgroundImage = `url("${img.src}")`);
  img.src = `/api/art/title/${t.id}?type=backdrop&w=1280`;
  const f = fileOf(nu.fileId);
  return h('section', { class: 'hero' }, art, h('div', { class: 'hero-body' },
    h('h1', {}, t.name),
    h('div', { class: 'meta' }, titleMeta(t)),
    t.kind === 'show' && !nu.fresh ? h('div', { class: 'up-next' }, h('b', {}, nu.resume ? 'Continue' : 'Up next'), `${epCode(nu.fileId)} · ${f.name}`) : null,
    h('div', { class: 'btns' },
      h('a', { class: 'btn btn-play', href: watchUrl(nu.fileId, nu.start) }, ic('play'), nu.resume ? 'Resume' : 'Play'),
      h('a', { class: 'btn btn-ghost', href: `#/title/${t.id}` }, ic('info'), 'More Info'))));
}

function renderHome() {
  const lib = state.lib;
  if (!lib.folders.length) return renderWelcome();
  if (!lib.titles.length) {
    view.replaceChildren(h('div', { class: 'welcome' }, h('div', {},
      h('h1', {}, lib.scanning ? 'Scanning your folders…' : 'No videos found yet'),
      h('p', {}, lib.scanning ? 'This only takes a moment.' : 'None of your folders contain video files Marquee recognises, or a drive is unplugged.'),
      h('a', { class: 'btn btn-ghost', href: '#/settings' }, 'Manage folders'))));
    return;
  }
  const cw = continueWatching();
  const shows = lib.titles.filter((t) => t.kind === 'show');
  const movies = lib.titles.filter((t) => t.kind === 'movie');
  const recent = [...lib.titles].sort((a, b) => b.addedAt - a.addedAt).slice(0, 20);
  const featured = cw[0]?.t || recent[0];
  view.replaceChildren(
    hero(featured),
    h('div', { class: 'rows' },
      row('Continue Watching', cw.map(({ t, nu }) => titleCard(t, { nu, removable: true }))),
      lib.titles.length > 6 ? row('Recently Added', recent.map((t) => titleCard(t))) : null,
      row('TV Shows', shows.map((t) => titleCard(t))),
      row('Movies', movies.map((t) => titleCard(t)))));
}

function renderGrid(kind) {
  const list = state.lib.titles.filter((t) => t.kind === kind);
  view.replaceChildren(h('div', { class: 'page' },
    h('h1', { class: 'page-title' }, kind === 'show' ? 'TV Shows' : 'Movies'),
    list.length ? h('div', { class: 'grid' }, list.map((t) => titleCard(t))) : h('p', { class: 'empty' }, `No ${kind === 'show' ? 'shows' : 'movies'} yet.`)));
}

const norm = (s) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');

function renderSearch(q) {
  const n = norm(q.trim());
  const titles = state.lib.titles.filter((t) => norm(t.name).includes(n));
  const eps = [];
  for (const f of Object.values(state.lib.files)) {
    if (eps.length >= 60) break;
    const w = loc(f.id);
    if (w?.title.kind === 'show' && !w.season.extras && norm(f.name).includes(n)) eps.push(f);
  }
  view.replaceChildren(h('div', { class: 'page' },
    h('h1', { class: 'page-title' }, `Results for “${q.trim()}”`),
    titles.length ? h('div', { class: 'grid' }, titles.map((t) => titleCard(t))) : null,
    eps.length ? h('h2', { class: 'page-title', style: { 'font-size': '20px', 'margin-top': '40px' } }, 'Episodes') : null,
    eps.length ? h('div', { class: 'grid' }, eps.map((f) => {
      const w = loc(f.id);
      return h('a', { class: 'card', href: watchUrl(f.id) },
        artBox(`/api/art/file/${f.id}?w=480`, f.name),
        h('div', { class: 'label' }, f.name, h('small', {}, `${w.title.name} · ${epCode(f.id)}`)));
    })) : null,
    !titles.length && !eps.length ? h('p', { class: 'empty' }, 'Nothing matches.') : null));
}

// ---- Title details (modal) -------------------------------------------------------

function closeModal() {
  modalRoot.replaceChildren();
  if (!player.isOpen) document.body.classList.remove('no-scroll');
}

function markerTags(fid) {
  const m = markersOf(fid);
  if (!m) return null;
  return h('div', { class: 'tags' },
    m.intro ? h('span', { class: 'tag', title: 'Skip Intro will appear here' }, `Intro ${fmtTime(m.intro.start)}–${fmtTime(m.intro.end)}`) : null,
    m.credits ? h('span', { class: 'tag', title: 'Next Episode appears when the credits start' }, `Credits ${fmtTime(m.credits.start)}`) : null);
}

async function setWatched(fileIds, watched) {
  const r = await api.post('/api/watched', { fileIds, watched });
  state.lib.progress = r.progress;
  state.dirty = true;
}

function openTitle(id, { season: seasonParam } = {}) {
  const t = state.titles.get(id);
  if (!t) return closeModal();
  api.post('/api/analysis/prioritize', { titleId: id }).catch(() => {});
  document.body.classList.add('no-scroll');
  const nu = nextUp(t);
  const isShow = t.kind === 'show';
  let seasonIdx = seasonParam != null ? Number(seasonParam) : Math.max(0, loc(nu.fileId)?.seasonIndex ?? 0);
  const all = t.seasons.flatMap((s) => s.episodes);
  const main = playOrder(t);

  const heroEl = h('div', { class: 'modal-hero' });
  const img = new Image();
  img.onload = () => (heroEl.style.backgroundImage = `url("${img.src}")`);
  img.src = `/api/art/title/${t.id}?type=backdrop&w=1280`;

  const listEl = h('div');
  const watchedAll = () => main.every((fid) => progressOf(fid)?.watched);
  const watchedBtn = h('button', { class: `round-btn${watchedAll() ? ' on' : ''}`, title: 'Mark everything watched / unwatched', onclick: async () => {
    await setWatched(main, !watchedAll());
    draw();
  } }, ic('check'));

  const playLabel = nextUpLabel(t, nu);
  heroEl.append(h('div', { class: 'hero-inner' },
    h('h1', {}, t.name),
    h('div', { class: 'btns' },
      h('a', { class: 'btn btn-play', href: watchUrl(nu.fileId, nu.start) }, ic('play'), playLabel),
      nu.resume ? h('a', { class: 'btn btn-ghost', href: watchUrl(nu.fileId, 0), title: 'Start this one from the beginning' }, ic('replay10'), 'Start over') : null,
      watchedBtn,
      h('button', { class: 'round-btn', title: 'Detect intros & credits again', onclick: async () => {
        await api.post(`/api/analyze/${t.id}`);
        toast('Re-detecting intros and credits for this title');
      } }, ic('refresh')))));

  const detected = all.filter((fid) => markersOf(fid)?.intro).length;
  const credits = all.filter((fid) => markersOf(fid)?.credits).length;
  const analysable = t.seasons.filter((s) => !s.extras).flatMap((s) => s.episodes).length;
  const watchedCount = main.filter((fid) => progressOf(fid)?.watched).length;

  const facts = h('div', { class: 'facts' },
    t.year ? h('span', {}, t.year) : null,
    h('span', {}, titleMeta(t)),
    watchedCount ? h('span', { class: 'hl' }, isShow ? `${watchedCount} of ${main.length} watched` : 'Watched') : null);
  const status = state.status?.analysis;
  const working = status?.current?.label?.startsWith(t.name) || false;
  const note = h('p', { class: 'detect-note' }, ic('checkCircle'),
    isShow
      ? `Skip Intro ready for ${detected} of ${analysable} episodes · Next Episode at the credits for ${credits}${working ? ' · detecting now…' : ''}`
      : credits ? 'End credits detected: the movie counts as watched once they start' : working ? 'Detecting end credits…' : 'No end credits detected yet');

  function draw() {
    watchedBtn.classList.toggle('on', watchedAll());
    if (!isShow && t.seasons[0].episodes.length === 1) {
      listEl.replaceChildren();
      return;
    }
    const season = t.seasons[seasonIdx] || t.seasons[0];
    const sel = isShow && t.seasons.length > 1
      ? h('div', { class: 'select' }, h('select', { onchange: (e) => { seasonIdx = Number(e.target.value); draw(); } },
          t.seasons.map((s, i) => h('option', { value: i, selected: i === seasonIdx }, `${s.name} (${s.episodes.length})`))))
      : null;
    const seasonWatched = season.episodes.every((fid) => progressOf(fid)?.watched);
    listEl.replaceChildren(
      h('div', { class: 'ep-head' }, h('h2', {}, isShow ? 'Episodes' : 'Parts'), h('div', { class: 'btns' },
        h('button', { class: 'link-btn', onclick: async () => { await setWatched(season.episodes, !seasonWatched); draw(); } }, seasonWatched ? 'Mark season unwatched' : 'Mark season watched'),
        sel)),
      h('div', { class: 'episodes' }, season.episodes.map((fid) => {
        const f = fileOf(fid);
        const p = progressOf(fid);
        const art = artBox(`/api/art/file/${fid}?w=320`, f.name);
        art.append(h('div', { class: 'play-hint' }, ic('play')));
        if (p?.duration && (p.watched || p.position > 5)) art.append(h('div', { class: 'bar' }, h('i', { style: { width: `${p.watched ? 100 : (p.position / p.duration) * 100}%` } })));
        const toggle = h('button', { class: `watch-toggle${p?.watched ? ' on' : ''}`, title: p?.watched ? 'Mark unwatched' : 'Mark watched', onclick: async (e) => {
          e.stopPropagation();
          await setWatched([fid], !p?.watched);
          draw();
        } }, ic('check'));
        return h('div', { class: `ep${fid === nu.fileId ? ' current' : ''}`, onclick: () => (location.hash = watchUrl(fid)) },
          h('div', { class: 'num' }, f.number ?? ''),
          art,
          h('div', {}, h('h3', {}, h('span', {}, f.name), h('span', { class: 'dur' }, fmtDur(f.duration))), markerTags(fid)),
          toggle);
      })));
  }
  draw();

  const overlay = h('div', { class: 'overlay', onclick: (e) => e.target === overlay && (location.hash = baseHash()) },
    h('div', { class: 'modal', role: 'dialog', 'aria-label': t.name },
      h('button', { class: 'modal-close', 'aria-label': 'Close', onclick: () => (location.hash = baseHash()) }, ic('close')),
      heroEl,
      h('div', { class: 'modal-body' }, facts, note, listEl)));
  modalRoot.replaceChildren(overlay);
  // Bring the current episode into view only when it is further down the list.
  const cur = overlay.querySelector('.ep.current');
  if (cur && seasonParam == null) {
    setTimeout(() => {
      if (cur.getBoundingClientRect().bottom > window.innerHeight - 40) cur.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }, 250);
  }
}

// ---- Settings ---------------------------------------------------------------------

const KINDS = { auto: 'Auto-detect', shows: 'TV shows', movies: 'Movies' };

function toggle(label, desc, key) {
  const input = h('input', { type: 'checkbox', checked: !!state.lib.settings[key], onchange: async (e) => {
    state.lib.settings = await api.post('/api/settings', { [key]: e.target.checked });
  } });
  return h('div', { class: 'setting' }, h('div', {}, h('div', {}, label), h('div', { class: 'desc' }, desc)), h('label', { class: 'switch' }, input, h('span')));
}

function renderSettings() {
  const lib = state.lib;
  const folders = lib.folders.map((f) => {
    const st = lib.folderStatus?.[f.id];
    const stat = !st ? 'Not scanned yet' : st.online ? `${st.titles} titles · ${st.videos} videos` : st.error;
    return h('div', { class: 'folder' },
      h('div', {}, h('div', { class: 'path' }, f.path), h('div', { class: `stat${st && !st.online ? ' off' : ''}` }, stat)),
      h('select', { title: 'What this folder contains', onchange: async (e) => {
        toast('Rescanning…');
        setLibrary(await api.patch(`/api/folders/${f.id}`, { kind: e.target.value }));
        renderSettings();
      } }, Object.entries(KINDS).map(([k, v]) => h('option', { value: k, selected: f.kind === k }, v))),
      h('button', { class: 'link-btn', title: 'Remove from library (files are not touched)', onclick: async (e) => {
        const btn = e.currentTarget;
        // Two-step confirm in place: first click arms, second click removes.
        if (!btn.dataset.armed) {
          btn.dataset.armed = '1';
          btn.textContent = 'Click again to remove';
          setTimeout(() => {
            delete btn.dataset.armed;
            btn.textContent = 'Remove';
          }, 4000);
          return;
        }
        setLibrary(await api.del(`/api/folders/${f.id}`));
        renderSettings();
        toast('Folder removed (files untouched)');
      } }, 'Remove'));
  });

  const analysisBox = h('div');
  const countdown = h('select', { onchange: async (e) => {
    state.lib.settings = await api.post('/api/settings', { nextCountdown: Number(e.target.value) });
  } }, [5, 10, 15, 20, 30].map((n) => h('option', { value: n, selected: lib.settings.nextCountdown === n }, `${n} seconds`)));

  view.replaceChildren(h('div', { class: 'settings' },
    h('h1', {}, 'Settings'),
    h('section', { class: 'section' },
      h('h2', {}, 'Library folders'),
      h('p', {}, 'Each subfolder of a show becomes a season. Folders are rescanned every 15 minutes; your watch progress is kept even if a drive is unplugged.'),
      folders.length ? folders : h('p', { class: 'muted' }, 'No folders yet.'),
      h('div', { class: 'btns', style: { 'margin-top': '14px' } },
        h('button', { class: 'btn btn-accent btn-small', onclick: () => openPicker() }, ic('plus'), 'Add folder'),
        h('button', { class: 'btn btn-ghost btn-small', onclick: async (e) => {
          e.target.disabled = true;
          toast('Scanning…');
          setLibrary(await api.post('/api/scan'));
          renderSettings();
          toast('Library updated');
        } }, ic('refresh'), 'Scan now'))),
    h('section', { class: 'section' },
      h('h2', {}, 'Intro & credits detection'),
      h('p', {}, 'Runs on this Mac. Each episode’s opening and closing minutes are turned into an audio fingerprint and compared with the other episodes of its season: music they share is the intro or the end credits. Movies (and shows without a shared end theme) are checked for text-on-black credits. Fingerprints and results are saved, so only new episodes are ever analysed.'),
      toggle('Detect intros and credits', 'Uses some CPU in the background while new episodes are analysed.', 'analysis'),
      analysisBox),
    h('section', { class: 'section' },
      h('h2', {}, 'Playback'),
      toggle('Skip intros automatically', 'Otherwise a Skip Intro button appears during the intro.', 'autoSkipIntro'),
      toggle('Autoplay next episode', 'When the end credits start, count down and play the next episode.', 'autoplayNext'),
      h('div', { class: 'setting' }, h('div', {}, h('div', {}, 'Next episode countdown')), h('div', { class: 'select' }, countdown)),
      h('div', { class: 'setting' }, h('div', {}, h('div', {}, 'Keyboard'), h('div', { class: 'desc' }, 'Space play/pause · ←/→ 10 s · ↑/↓ volume up to 200% · [ ] speed ({ } fine, = normal) · S skip intro · N next episode · C subtitles · F full screen · M mute')))),
    h('section', { class: 'section' },
      h('h2', {}, 'Engine'),
      h('p', {}, lib.ffmpeg
        ? 'ffmpeg found: any format plays (unsupported ones are converted while you watch, using the Mac’s hardware encoder).'
        : 'ffmpeg not found. Only MP4/WebM files play and detection is off. Install it with: brew install ffmpeg'),
      h('button', { class: 'btn btn-ghost btn-small', onclick: async () => {
        await api.post('/api/quit').catch(() => {});
        view.replaceChildren(h('div', { class: 'welcome' }, h('div', {}, h('h1', {}, 'Marquee has stopped'), h('p', {}, 'Open the app again to restart it.'))));
      } }, 'Stop Marquee'))));

  const drawStatus = () => {
    const a = state.status?.analysis;
    if (!a) return;
    const pct = a.totalFiles ? (a.analyzedFiles / a.totalFiles) * 100 : 0;
    analysisBox.replaceChildren(
      h('div', { class: 'progress-line' }, h('i', { style: { width: `${pct}%` } })),
      h('div', { class: 'muted' },
        !a.available ? 'Needs ffmpeg.' : !a.enabled ? 'Paused.' :
        a.current ? `Analysing ${a.current.label} (${a.current.done}/${a.current.total})… ${a.analyzedFiles} of ${a.totalFiles} done` :
        a.analyzedFiles >= a.totalFiles ? `All ${a.totalFiles} videos analysed.` : `${a.analyzedFiles} of ${a.totalFiles} analysed.`));
  };
  page.drawStatus = drawStatus;
  drawStatus();
}

// ---- Folder picker ---------------------------------------------------------------------

function openPicker() {
  let current = null;
  const pathInput = h('input', { type: 'text', spellcheck: false, 'aria-label': 'Folder path', onkeydown: (e) => e.key === 'Enter' && load(pathInput.value) });
  const shortcuts = h('div', { class: 'shortcuts' });
  const dirs = h('div', { class: 'dirs' });
  const kind = h('select', {}, Object.entries(KINDS).map(([k, v]) => h('option', { value: k }, v)));
  const addBtn = h('button', { class: 'btn btn-accent btn-small', onclick: add }, 'Add this folder');
  const msg = h('span', { class: 'muted grow' });

  async function load(p) {
    const r = await api.get(`/api/browse?path=${encodeURIComponent(p || '')}`);
    current = r.path;
    pathInput.value = r.path;
    shortcuts.replaceChildren(...r.shortcuts.map((s) => h('button', { onclick: () => load(s.path) }, ic(s.drive ? 'drive' : 'folder'), s.name)));
    dirs.replaceChildren(
      r.parent ? h('button', { onclick: () => load(r.parent) }, ic('up'), '..') : '',
      ...(r.error ? [h('p', { class: 'muted', style: { padding: '8px 10px' } }, r.error)] : []),
      ...r.dirs.map((d) => h('button', { ondblclick: () => load(d.path), onclick: () => load(d.path) }, ic('folder'), d.name)));
    if (!r.dirs.length && !r.error) dirs.append(h('p', { class: 'muted', style: { padding: '8px 10px' } }, 'No subfolders.'));
    msg.textContent = '';
  }

  async function add() {
    addBtn.disabled = true;
    msg.textContent = 'Adding and scanning…';
    try {
      setLibrary(await api.post('/api/folders', { path: current, kind: kind.value }));
      overlay.remove();
      toast('Folder added');
      if (page.base === 'settings') renderSettings();
      else location.hash = '#/';
      route(true);
    } catch (e) {
      msg.textContent = e.message;
      addBtn.disabled = false;
    }
  }

  const overlay = h('div', { class: 'overlay', onclick: (e) => e.target === overlay && overlay.remove() },
    h('div', { class: 'picker', role: 'dialog', 'aria-label': 'Choose a folder' },
      h('header', {}, h('h2', {}, 'Add a folder'), h('div', { class: 'pathbar' }, pathInput, h('button', { class: 'btn btn-ghost btn-small', onclick: () => load(pathInput.value) }, 'Go'))),
      h('div', { class: 'body' }, shortcuts, dirs),
      h('footer', {}, msg, h('label', { class: 'muted' }, 'Contains ', kind), h('button', { class: 'btn btn-ghost btn-small', onclick: () => overlay.remove() }, 'Cancel'), addBtn)));
  document.body.append(overlay);
  load('');
}

// ---- Router --------------------------------------------------------------------------------

const baseHash = () => (page.base === 'home' ? '#/' : page.base === 'search' ? `#/search?q=${encodeURIComponent(page.query)}` : `#/${page.base}`);
let prevHash = '';

async function route(forceDraw = false) {
  const hash = location.hash || '#/';
  const [pathPart, qs] = hash.slice(1).split('?');
  const parts = pathPart.split('/').filter(Boolean);
  const params = new URLSearchParams(qs || '');
  try {
    await loadLibrary();
  } catch (e) {
    view.replaceChildren(h('div', { class: 'welcome' }, h('div', {}, h('h1', {}, 'Marquee is not running'), h('p', {}, 'Start it again and reload this window.'))));
    return;
  }

  if (parts[0] === 'watch') {
    modalRoot.replaceChildren();
    player.open(parts[1], { start: params.has('t') ? Number(params.get('t')) : null, returnTo: prevHash || null });
    return;
  }
  if (player.isOpen) player.hide();

  let base = parts[0] === 'title' ? page.base || 'home' : ['shows', 'movies', 'settings', 'search'].includes(parts[0]) ? parts[0] : 'home';
  const query = base === 'search' ? params.get('q') || '' : '';
  if (base === 'search' && !query.trim()) base = 'home';
  if (forceDraw || state.dirty || base !== page.base || query !== page.query) {
    const sameBase = base === page.base;
    const y = window.scrollY;
    page.base = base;
    page.query = query;
    page.drawStatus = null;
    if (base === 'home') renderHome();
    else if (base === 'shows') renderGrid('show');
    else if (base === 'movies') renderGrid('movie');
    else if (base === 'settings') renderSettings();
    else if (base === 'search') renderSearch(query);
    state.dirty = false;
    window.scrollTo(0, sameBase ? y : 0);
  }
  for (const a of document.querySelectorAll('[data-nav]')) a.classList.toggle('active', a.dataset.nav === base);
  if (base !== 'search' && document.activeElement !== searchInput) {
    searchInput.value = '';
    searchInput.parentElement.classList.remove('filled');
  }

  if (parts[0] === 'title') openTitle(parts[1], { season: params.get('season') });
  else closeModal();
}

window.addEventListener('hashchange', (e) => {
  prevHash = new URL(e.oldURL).hash || '#/';
  route();
});

window.addEventListener('scroll', () => nav.classList.toggle('solid', window.scrollY > 10), { passive: true });

searchInput.addEventListener('input', () => {
  const q = searchInput.value;
  searchInput.parentElement.classList.toggle('filled', !!q);
  const target = q.trim() ? `#/search?q=${encodeURIComponent(q)}` : '#/';
  history.replaceState(null, '', target);
  route();
});

document.addEventListener('keydown', (e) => {
  if (player.isOpen) return;
  if (e.key === 'Escape' && modalRoot.firstChild) location.hash = baseHash();
  else if (e.key === '/' && document.activeElement !== searchInput && !e.target.matches('input, select, textarea')) {
    e.preventDefault();
    searchInput.focus();
  }
});

// Background status: scan/analysis activity in the nav, live progress in settings.
async function pollStatus() {
  try {
    state.status = await api.get('/api/status');
    const a = state.status.analysis;
    if (state.status.scanning) {
      activity.hidden = false;
      activity.textContent = 'Scanning…';
    } else if (a.current && a.enabled) {
      activity.hidden = false;
      activity.textContent = `Detecting intros · ${a.analyzedFiles}/${a.totalFiles}`;
    } else activity.hidden = true;
    page.drawStatus?.();
    // Pick up new markers/library changes when the user is not mid-interaction.
    if (!player.isOpen && Date.now() - state.loadedAt > 20000 && !modalRoot.firstChild) {
      await loadLibrary(true);
      if (page.base === 'home' || page.base === 'shows' || page.base === 'movies') route();
    }
  } catch {}
  setTimeout(pollStatus, page.base === 'settings' ? 2000 : 6000);
}

route();
pollStatus();
