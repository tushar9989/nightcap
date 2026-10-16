import {
  state, api, h, ic, artBox, fmtDur, fmtTime, toast, loadLibrary, setLibrary, loc, fileOf, progressOf, markersOf,
  epCode, playOrder, nextUp, nextUpLabel, continueWatching, watchUrl, subLanguages, previewOnHover,
} from './lib.js';
import { Player } from './player.js';

const view = document.getElementById('view');
const sideNav = document.getElementById('side-nav');
const searchInput = document.getElementById('search-input');
const activity = document.getElementById('activity');
const player = new Player(document.getElementById('player-root'));

// key: which page is showing ('home', 'shows', 'title:<id>', …), for redraws and the sidebar.
const page = { key: null, base: null, query: '' };

const byName = (a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' });

// ---- Pieces --------------------------------------------------------------------------

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

const progressBar = (p) => h('div', { class: 'bar' }, h('i', { style: { width: `${p.watched ? 100 : (p.position / p.duration) * 100}%` } }));

// A title in a grid: its picture, with the name and details underneath.
function titleTile(t) {
  return h('a', { class: 'tile', href: `#/title/${t.id}`, title: t.name },
    artBox(`/api/art/title/${t.id}?type=card&w=480`, t.name),
    h('div', { class: 'tile-text' }, h('b', {}, t.name), h('span', {}, titleMeta(t))));
}

// Something you are watching: plays from where you stopped; resting on it previews it.
function watchingTile({ t, nu }) {
  const f = fileOf(nu.fileId);
  const p = progressOf(nu.fileId);
  const art = artBox(`/api/art/file/${nu.fileId}?w=640`, f.name);
  art.append(h('div', { class: 'play-hint' }, ic('play')));
  if (nu.resume && p?.duration) art.append(progressBar(p));
  const left = nu.resume && f.duration ? `${fmtDur(f.duration - nu.start)} left` : 'Up next';
  const el = h('a', { class: 'tile watching', href: watchUrl(nu.fileId, nu.start), title: `${nu.resume ? 'Resume' : 'Play'} ${f.name}` },
    art,
    h('div', { class: 'tile-text' },
      h('b', {}, t.name),
      h('span', {}, t.kind === 'show' ? `${epCode(nu.fileId)} · ${f.name}` : left),
      t.kind === 'show' ? h('span', { class: 'dim' }, left) : null),
    h('button', { class: 'tile-x', title: 'Remove from Watching', onclick: async (e) => {
      e.preventDefault();
      e.stopPropagation();
      const r = await api.post('/api/hide', { titleId: t.id });
      state.lib.hidden = r.hidden;
      route(true);
    } }, ic('close')));
  previewOnHover(art, nu.fileId, el);
  return el;
}

const block = (title, body, extra = null) => h('section', { class: 'block' }, h('header', {}, h('h2', {}, title), extra), body);

async function setWatched(fileIds, watched) {
  const r = await api.post('/api/watched', { fileIds, watched });
  state.lib.progress = r.progress;
  state.dirty = true;
}

// One episode (or part, or extra) in a list. `show` adds the show's name (search results).
function episodeRow(fid, { current = false, show = null, onChange = null } = {}) {
  const f = fileOf(fid);
  const p = progressOf(fid);
  const art = artBox(`/api/art/file/${fid}?w=320`, f.name);
  art.append(h('div', { class: 'play-hint' }, ic('play')));
  if (p?.duration && (p.watched || p.position > 5)) art.append(progressBar(p));
  const m = markersOf(fid);
  const marks = [m?.intro && `Intro ${fmtTime(m.intro.start)}–${fmtTime(m.intro.end)}`, m?.credits && `Credits ${fmtTime(m.credits.start)}`].filter(Boolean).join(' · ');
  const toggle = onChange && h('button', { class: `watch-toggle${p?.watched ? ' on' : ''}`, title: p?.watched ? 'Mark unwatched' : 'Mark watched', onclick: async (e) => {
    e.stopPropagation();
    await setWatched([fid], !p?.watched);
    onChange();
  } }, ic('check'));
  const row = h('div', { class: `ep${current ? ' current' : ''}${show ? ' no-num' : ''}`, onclick: () => (location.hash = watchUrl(fid)) },
    show ? null : h('div', { class: 'num' }, f.number ?? ''),
    art,
    h('div', { class: 'ep-text' },
      h('div', { class: 'ep-name' }, h('b', {}, f.name), h('span', { class: 'dur' }, fmtDur(f.duration))),
      show ? h('div', { class: 'ep-sub' }, `${show.name} · ${epCode(fid)}`) : null,
      marks ? h('div', { class: 'ep-sub' }, marks) : null),
    toggle);
  previewOnHover(art, fid, row);
  return row;
}

// ---- Sidebar --------------------------------------------------------------------------

function sideItem(href, label, { key, icon = null, thumb = null, note = null } = {}) {
  return h('a', { class: 'side-item', href, 'data-key': key },
    icon ? ic(icon) : thumb ? h('img', { class: 'side-thumb', src: thumb, alt: '', loading: 'lazy' }) : null,
    h('span', { class: 'side-label' }, label),
    note ? h('span', { class: 'side-note' }, note) : null);
}

function renderSidebar() {
  const titles = state.lib?.titles || [];
  const keepScroll = sideNav.scrollTop;
  const titleItem = (t, note) => sideItem(`#/title/${t.id}`, t.name, { key: `title:${t.id}`, thumb: `/api/art/title/${t.id}?type=card&w=120`, note });
  const group = (label, key, items) => (items.length
    ? h('div', { class: 'side-group' }, key ? h('a', { class: 'side-head', href: `#/${key}`, 'data-key': key }, label) : h('div', { class: 'side-head' }, label), items)
    : null);
  const watching = state.lib?.folders.length ? continueWatching() : [];
  sideNav.replaceChildren(
    sideItem('#/', 'Home', { key: 'home', icon: 'home' }),
    group('Watching', null, watching.map(({ t, nu }) => titleItem(t, t.kind === 'show' ? epCode(nu.fileId) : null))),
    group('Shows', 'shows', titles.filter((t) => t.kind === 'show').sort(byName).map((t) => titleItem(t))),
    group('Movies', 'movies', titles.filter((t) => t.kind === 'movie').sort(byName).map((t) => titleItem(t))));
  sideNav.scrollTop = keepScroll;
  markActive();
}

function markActive() {
  for (const a of document.querySelectorAll('[data-key]')) a.classList.toggle('active', a.dataset.key === page.key);
}

// ---- Pages ----------------------------------------------------------------------------

function renderWelcome() {
  view.replaceChildren(h('div', { class: 'welcome' }, h('div', {},
    h('h1', {}, 'Your films and shows, on your Mac'),
    h('p', {}, 'Add the folders where your films and series live. Season folders become seasons, playback picks up where you stopped, and intros and end credits are found on this Mac so you can skip them.'),
    h('button', { class: 'btn btn-play', onclick: () => openPicker() }, ic('plus'), 'Add a folder'))));
}

function renderHome() {
  const lib = state.lib;
  if (!lib.folders.length) return renderWelcome();
  if (!lib.titles.length) {
    view.replaceChildren(h('div', { class: 'welcome' }, h('div', {},
      h('h1', {}, lib.scanning ? 'Looking through your folders…' : 'No videos found yet'),
      h('p', {}, lib.scanning ? 'This only takes a moment.' : 'None of your folders contain videos Marquee recognises, or a drive is unplugged.'),
      h('a', { class: 'btn btn-ghost', href: '#/settings' }, 'Manage folders'))));
    return;
  }
  const watching = continueWatching();
  const recent = [...lib.titles].sort((a, b) => b.addedAt - a.addedAt).slice(0, 12);
  view.replaceChildren(h('div', { class: 'page' },
    watching.length ? block('Watching', h('div', { class: 'grid wide' }, watching.map(watchingTile))) : null,
    block(watching.length ? 'Recently added' : 'Your library', h('div', { class: 'grid' }, recent.map(titleTile)))));
}

function renderGrid(kind) {
  const list = state.lib.titles.filter((t) => t.kind === kind).sort(byName);
  view.replaceChildren(h('div', { class: 'page' },
    h('h1', { class: 'page-title' }, kind === 'show' ? 'Shows' : 'Movies'),
    list.length ? h('div', { class: 'grid' }, list.map(titleTile)) : h('p', { class: 'empty' }, `No ${kind === 'show' ? 'shows' : 'movies'} yet.`)));
}

const norm = (s) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');

function renderSearch(q) {
  const n = norm(q.trim());
  const titles = state.lib.titles.filter((t) => norm(t.name).includes(n)).sort(byName);
  const eps = [];
  for (const f of Object.values(state.lib.files)) {
    if (eps.length >= 60) break;
    const w = loc(f.id);
    if (w?.title.kind === 'show' && !w.season.extras && norm(f.name).includes(n)) eps.push(f);
  }
  view.replaceChildren(h('div', { class: 'page' },
    h('h1', { class: 'page-title' }, `“${q.trim()}”`),
    titles.length ? block('Titles', h('div', { class: 'grid' }, titles.map(titleTile))) : null,
    eps.length ? block('Episodes', h('div', { class: 'episodes' }, eps.map((f) => episodeRow(f.id, { show: loc(f.id).title })))) : null,
    !titles.length && !eps.length ? h('p', { class: 'empty' }, 'Nothing matches.') : null));
}

// A show or film: what to play next, then its seasons and episodes.
function renderTitle(id, seasonParam) {
  const t = state.titles.get(id);
  if (!t) {
    view.replaceChildren(h('div', { class: 'page' }, h('p', { class: 'empty' }, 'This title is no longer in your library.')));
    return;
  }
  api.post('/api/analysis/prioritize', { titleId: id }).catch(() => {});
  const isShow = t.kind === 'show';
  const all = t.seasons.flatMap((s) => s.episodes);
  const main = playOrder(t);
  const nu = nextUp(t);
  let seasonIdx = seasonParam != null && t.seasons[Number(seasonParam)] ? Number(seasonParam) : Math.max(0, loc(nu.fileId)?.seasonIndex ?? 0);
  const headEl = h('header', { class: 'title-head' });
  const listEl = h('div', { class: 'title-list' });

  function drawHead() {
    const art = artBox(`/api/art/file/${nu.fileId}?w=640`, t.name);
    const p = progressOf(nu.fileId);
    if (nu.resume && p?.duration) art.append(progressBar(p));
    previewOnHover(art, nu.fileId);
    const watchedCount = main.filter((fid) => progressOf(fid)?.watched).length;
    const allWatched = watchedCount === main.length;
    const detected = all.filter((fid) => markersOf(fid)?.intro).length;
    const credits = all.filter((fid) => markersOf(fid)?.credits).length;
    const analysable = t.seasons.filter((s) => !s.extras).flatMap((s) => s.episodes).length;
    const working = state.status?.analysis?.current?.label?.startsWith(t.name) || false;
    const facts = [titleMeta(t), isShow && t.seasons.filter((s) => !s.extras).length > 1 ? `${main.length} episodes` : null,
      watchedCount ? (isShow ? `${watchedCount} watched` : 'Watched') : null].filter(Boolean).join(' · ');
    const next = isShow && !nu.fresh ? h('div', { class: 'next-line' }, h('span', {}, nu.resume ? 'Watching' : 'Up next'), `${epCode(nu.fileId)} · ${fileOf(nu.fileId).name}`) : null;
    headEl.replaceChildren(
      h('a', { class: 'title-art', href: watchUrl(nu.fileId, nu.start), title: nextUpLabel(t, nu) }, art),
      h('div', { class: 'title-info' },
        h('h1', {}, t.name),
        h('div', { class: 'facts' }, facts),
        next,
        h('div', { class: 'btns' },
          h('a', { class: 'btn btn-play', href: watchUrl(nu.fileId, nu.start) }, ic('play'), nextUpLabel(t, nu)),
          nu.resume ? h('a', { class: 'btn btn-ghost', href: watchUrl(nu.fileId, 0), title: 'Start this one from the beginning' }, 'Start over') : null,
          h('button', { class: 'btn btn-ghost', title: allWatched ? 'Mark everything unwatched' : 'Mark everything watched', onclick: async () => {
            await setWatched(main, !allWatched);
            draw();
          } }, ic('check'), `Mark ${isShow ? 'all ' : ''}${allWatched ? 'unwatched' : 'watched'}`),
          h('button', { class: 'btn btn-ghost btn-icon', title: 'Detect intros and credits again', onclick: async () => {
            await api.post(`/api/analyze/${t.id}`);
            toast('Detecting intros and credits again for this title');
          } }, ic('refresh'))),
        h('p', { class: 'detect-note' }, ic('checkCircle'),
          isShow
            ? `Skip Intro ready for ${detected} of ${analysable} episodes · Next Episode at the credits for ${credits}${working ? ' · detecting now…' : ''}`
            : credits ? 'End credits found: it counts as watched once they start' : working ? 'Looking for the end credits…' : 'No end credits found yet')));
  }

  function drawList() {
    const season = t.seasons[seasonIdx] || t.seasons[0];
    if (!isShow && season.episodes.length === 1 && t.seasons.length === 1) return listEl.replaceChildren();
    const tabs = t.seasons.length > 1
      ? h('div', { class: 'tabs', role: 'tablist' }, t.seasons.map((s, i) => h('button', {
          class: `tab${i === seasonIdx ? ' on' : ''}`, role: 'tab', 'aria-selected': String(i === seasonIdx),
          onclick: () => {
            seasonIdx = i;
            history.replaceState(null, '', `#/title/${t.id}?season=${i}`);
            drawList();
          },
        }, s.name)))
      : h('h2', {}, isShow ? 'Episodes' : 'Parts');
    const seasonWatched = season.episodes.every((fid) => progressOf(fid)?.watched);
    api.post('/api/previews/prioritize', { fileIds: season.episodes }).catch(() => {});
    listEl.replaceChildren(
      h('div', { class: 'list-head' }, tabs,
        h('button', { class: 'link-btn', onclick: async () => { await setWatched(season.episodes, !seasonWatched); draw(); } },
          seasonWatched ? `Mark ${season.extras ? 'all' : 'season'} unwatched` : `Mark ${season.extras ? 'all' : 'season'} watched`)),
      h('div', { class: 'episodes' }, season.episodes.map((fid) => episodeRow(fid, { current: fid === nu.fileId, onChange: draw }))));
    listEl.querySelector('.tab.on')?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }

  function draw() {
    drawHead();
    drawList();
  }
  draw();
  view.replaceChildren(h('div', { class: 'page title-page' }, headEl, listEl));
  // Bring the episode up next into view when it is further down the list.
  const cur = listEl.querySelector('.ep.current');
  if (cur && seasonParam == null) {
    setTimeout(() => {
      if (cur.getBoundingClientRect().bottom > window.innerHeight - 40) cur.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }, 200);
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

// Two clicks to confirm in place: the first arms the button, the second acts.
function armed(btn, label) {
  if (btn.dataset.armed) return true;
  const text = btn.textContent;
  btn.dataset.armed = '1';
  btn.textContent = label;
  setTimeout(() => {
    delete btn.dataset.armed;
    btn.textContent = text;
  }, 4000);
  return false;
}

const OS_LINK = (text, href) => h('a', { href, target: '_blank', rel: 'noopener' }, text);

// Subtitle language, automatic downloads and the OpenSubtitles.com connection.
function subtitlesSection() {
  const lib = state.lib;
  const box = h('div', { class: 'os-box' });
  const lang = h('select', { onchange: async (e) => {
    state.lib.settings = await api.post('/api/settings', { subtitleLanguage: e.target.value });
  } }, subLanguages(lib.settings.subtitleLanguage).map((l) => h('option', { value: l.code, selected: l.code === lib.settings.subtitleLanguage }, l.name)));

  const draw = (st, msg = '') => {
    const note = h('div', { class: `muted os-msg${msg ? ' err' : ''}` }, msg);
    const busy = async (btn, fn) => {
      btn.disabled = true;
      note.classList.remove('err');
      note.textContent = 'Checking with OpenSubtitles…';
      try {
        draw(await fn());
      } catch (e) {
        draw(st, e.message);
      }
    };
    const head = h('div', { class: 'os-head' }, h('b', {}, 'OpenSubtitles.com'),
      h('span', { class: `pill${st.configured ? ' on' : ''}` }, st.configured ? (st.signedIn ? `Signed in as ${st.username}` : 'Connected') : 'Not set up'));
    if (!st.configured) {
      const key = h('input', { type: 'password', placeholder: 'API key', autocomplete: 'off', spellcheck: false, 'aria-label': 'OpenSubtitles API key' });
      const save = h('button', { class: 'btn btn-accent btn-small', onclick: () => busy(save, () => api.post('/api/opensubtitles/key', { apiKey: key.value })) }, 'Save key');
      key.addEventListener('keydown', (e) => e.key === 'Enter' && save.click());
      box.replaceChildren(head,
        h('p', {}, 'To search online, Marquee needs your own API key. It is free:'),
        h('ol', {},
          h('li', {}, 'Create an account on ', OS_LINK('opensubtitles.com', 'https://www.opensubtitles.com/en/users/sign_up'), '.'),
          h('li', {}, 'Open ', OS_LINK('API consumers', 'https://www.opensubtitles.com/en/consumers'), ', add a new consumer (call it Marquee) and copy its API key.'),
          h('li', {}, 'Paste the key here. It stays on this Mac, in Marquee’s data folder.')),
        h('div', { class: 'os-row-form' }, key, save), note);
      return;
    }
    const left = st.remaining != null ? ` · ${st.remaining} left today` : '';
    const keyLine = h('div', { class: 'setting' },
      h('div', {}, h('div', {}, 'API key'), h('div', { class: 'desc' }, st.keyFromEnv ? `${st.keyHint} (from OPENSUBTITLES_API_KEY)` : st.keyHint)),
      st.keyFromEnv ? null : h('button', { class: 'link-btn', onclick: (e) => armed(e.currentTarget, 'Click again to remove') && busy(e.currentTarget, () => api.post('/api/opensubtitles/key', { apiKey: '' })) }, 'Remove key'));
    let account;
    if (st.signedIn) {
      account = h('div', { class: 'setting' },
        h('div', {}, h('div', {}, `Signed in as ${st.username}`), h('div', { class: 'desc' }, `${[st.level, st.allowedDownloads != null ? `${st.allowedDownloads} downloads a day` : ''].filter(Boolean).join(' · ')}${left}`)),
        h('button', { class: 'link-btn', onclick: (e) => busy(e.currentTarget, () => api.post('/api/opensubtitles/logout')) }, 'Sign out'));
    } else {
      const user = h('input', { type: 'text', placeholder: 'Username', autocomplete: 'username', spellcheck: false, 'aria-label': 'OpenSubtitles username', value: st.username || '' });
      const pass = h('input', { type: 'password', placeholder: 'Password', autocomplete: 'current-password', 'aria-label': 'OpenSubtitles password' });
      const go = h('button', { class: 'btn btn-ghost btn-small', onclick: () => busy(go, () => api.post('/api/opensubtitles/login', { username: user.value, password: pass.value })) }, 'Sign in');
      pass.addEventListener('keydown', (e) => e.key === 'Enter' && go.click());
      account = h('div', { class: 'os-signin' },
        h('div', {}, st.signInExpired ? 'Your sign-in has expired. ' : '', `Without signing in you can download 5 subtitles a day${left}. Signing in uses your account’s own daily allowance. Your password is only sent to OpenSubtitles, never stored.`),
        h('div', { class: 'os-row-form' }, user, pass, go));
    }
    box.replaceChildren(head, keyLine, account, note,
      h('div', { class: 'muted os-foot' }, 'Subtitles provided by ', OS_LINK('OpenSubtitles.com', 'https://www.opensubtitles.com'), '. Downloaded subtitles are kept in Marquee’s data folder; your media folders are not touched.'));
  };
  box.replaceChildren(h('div', { class: 'muted' }, 'Loading…'));
  api.get('/api/opensubtitles?refresh=1').then((st) => draw(st), (e) => box.replaceChildren(h('div', { class: 'muted' }, e.message)));

  return h('section', { class: 'section' },
    h('h2', {}, 'Subtitles'),
    h('p', {}, 'Subtitle files next to a video and subtitle tracks inside it are found automatically. Marquee can also search OpenSubtitles.com, preferring subtitles timed for your exact file (Subtitles button → Search online…). Adverts that uploaders put into subtitles are hidden.'),
    h('div', { class: 'setting' }, h('div', {}, h('div', {}, 'Subtitle language'), h('div', { class: 'desc' }, 'Searched first, and used for automatic downloads.')), h('div', { class: 'select' }, lang)),
    toggle('Download missing subtitles automatically', 'When you watch with subtitles on and an episode has none in your language, fetch the best match from OpenSubtitles (one download from the daily allowance per episode).', 'autoFetchSubtitles'),
    box);
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
        if (!armed(e.currentTarget, 'Click again to remove')) return;
        setLibrary(await api.del(`/api/folders/${f.id}`));
        renderSettings();
        toast('Folder removed (files untouched)');
      } }, 'Remove'));
  });

  const analysisBox = h('div');
  const previewsBox = h('div');
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
      h('h2', {}, 'Preview thumbnails'),
      h('p', {}, 'A frame every few seconds of each episode and film, made on this Mac from keyframes (about a second per episode). They show above the seek bar while you scrub, play as previews when you rest the pointer on an episode, and preview the next episode at the end credits.'),
      toggle('Make preview thumbnails', 'Runs in the background; what you open or play is done first. About 2 MB per episode.', 'previews'),
      previewsBox),
    h('section', { class: 'section' },
      h('h2', {}, 'Playback'),
      toggle('Skip intros automatically', 'Otherwise a Skip Intro button appears during the intro.', 'autoSkipIntro'),
      toggle('Autoplay next episode', 'When the end credits start, count down and play the next episode.', 'autoplayNext'),
      h('div', { class: 'setting' }, h('div', {}, h('div', {}, 'Next episode countdown')), h('div', { class: 'select' }, countdown)),
      h('div', { class: 'setting' }, h('div', {}, h('div', {}, 'Keyboard'), h('div', { class: 'desc' }, 'Space play/pause · ←/→ 10 s · ↑/↓ volume up to 200% · [ ] speed ({ } fine, = normal) · S skip intro · N next episode · C subtitles · G / H subtitles earlier / later · F full screen · M mute')))),
    subtitlesSection(),
    h('section', { class: 'section' },
      h('h2', {}, 'Engine'),
      h('p', {}, lib.ffmpeg
        ? 'ffmpeg found: any format plays (unsupported ones are converted while you watch, using the Mac’s hardware encoder).'
        : 'ffmpeg not found. Only MP4/WebM files play and detection is off. Install it with: brew install ffmpeg'),
      h('button', { class: 'btn btn-ghost btn-small', onclick: async () => {
        await api.post('/api/quit').catch(() => {});
        showStopped();
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
  const drawPreviews = () => {
    const p = state.status?.previews;
    if (!p) return;
    const pct = p.total ? (p.done / p.total) * 100 : 0;
    const size = p.bytes >= 1e9 ? `${(p.bytes / 1e9).toFixed(1)} GB` : `${Math.round(p.bytes / 1e6)} MB`;
    previewsBox.replaceChildren(
      h('div', { class: 'progress-line' }, h('i', { style: { width: `${pct}%` } })),
      h('div', { class: 'muted' },
        !p.available ? 'Needs ffmpeg.' :
        p.current && p.enabled ? `Making previews for ${p.current}… ${p.done} of ${p.total} done · ${size}` :
        `${p.done} of ${p.total} videos have previews · ${size}${!p.enabled ? ' · paused' : ''}`));
  };
  page.drawStatus = () => {
    drawStatus();
    drawPreviews();
  };
  page.drawStatus();
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

let prevHash = '';

async function route(forceDraw = false) {
  const hash = location.hash || '#/';
  const [pathPart, qs] = hash.slice(1).split('?');
  const parts = pathPart.split('/').filter(Boolean);
  const params = new URLSearchParams(qs || '');
  try {
    await loadLibrary();
  } catch (e) {
    return; // the engine is gone: the "stopped" notice covers the window
  }

  if (parts[0] === 'watch') {
    player.open(parts[1], { start: params.has('t') ? Number(params.get('t')) : null, returnTo: prevHash || null });
    return;
  }
  if (player.isOpen) player.hide();

  let base = ['title', 'shows', 'movies', 'settings', 'search'].includes(parts[0]) ? parts[0] : 'home';
  const query = base === 'search' ? params.get('q') || '' : '';
  if (base === 'search' && !query.trim()) base = 'home';
  if (base === 'title' && !parts[1]) base = 'home';
  const key = base === 'title' ? `title:${parts[1]}` : base;
  if (forceDraw || state.dirty || key !== page.key || query !== page.query) {
    const same = key === page.key && query === page.query;
    const y = window.scrollY;
    page.key = key;
    page.base = base;
    page.query = query;
    page.drawStatus = null;
    if (base === 'home') renderHome();
    else if (base === 'shows') renderGrid('show');
    else if (base === 'movies') renderGrid('movie');
    else if (base === 'settings') renderSettings();
    else if (base === 'search') renderSearch(query);
    else if (base === 'title') renderTitle(parts[1], params.get('season'));
    renderSidebar();
    state.dirty = false;
    window.scrollTo(0, same ? y : 0);
  }
  markActive();
  if (base !== 'search' && document.activeElement !== searchInput) {
    searchInput.value = '';
    searchInput.parentElement.classList.remove('filled');
  }
}

window.addEventListener('hashchange', (e) => {
  prevHash = new URL(e.oldURL).hash || '#/';
  route();
});

searchInput.addEventListener('input', () => {
  const q = searchInput.value;
  searchInput.parentElement.classList.toggle('filled', !!q);
  const target = q.trim() ? `#/search?q=${encodeURIComponent(q)}` : '#/';
  history.replaceState(null, '', target);
  route();
});

document.addEventListener('keydown', (e) => {
  if (player.isOpen) return;
  if (e.key === '/' && document.activeElement !== searchInput && !e.target.matches('input, select, textarea')) {
    e.preventDefault();
    searchInput.focus();
  } else if (e.key === 'Escape' && document.activeElement === searchInput) {
    searchInput.value = '';
    searchInput.blur();
    location.hash = '#/';
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
    } else if (state.status.previews?.current && state.status.previews.enabled) {
      activity.hidden = false;
      activity.textContent = `Making previews · ${state.status.previews.done}/${state.status.previews.total}`;
    } else activity.hidden = true;
    page.drawStatus?.();
    // Pick up new markers/library changes when the user is not mid-interaction.
    if (!player.isOpen && Date.now() - state.loadedAt > 20000) {
      await loadLibrary(true);
      if (page.base === 'home' || page.base === 'shows' || page.base === 'movies') route();
      else if (state.dirty) renderSidebar();
    }
  } catch {}
  setTimeout(pollStatus, page.base === 'settings' ? 2000 : 6000);
}

// ---- Connection to the engine ------------------------------------------------------------
// While this page is open the engine keeps running; it quits a few seconds
// after the last page closes (see "Lifetime" in server/index.js). If the
// engine goes away under this page (stopped elsewhere, or killed), say so and
// pause; when it is back (Marquee opened again), reload into the current code.
let bootId = null;
let downTimer = null;
let stoppedEl = null;

function showStopped() {
  if (stoppedEl) return;
  for (const v of document.querySelectorAll('video')) v.pause();
  stoppedEl = h('div', { class: 'stopped' }, h('div', {},
    h('h1', {}, 'Marquee has stopped'),
    h('p', {}, 'Open Marquee again to keep watching. This window reconnects by itself.')));
  document.body.append(stoppedEl);
}

function connect() {
  const session = new EventSource('/api/session');
  session.addEventListener('hello', (e) => {
    const { boot } = JSON.parse(e.data);
    clearTimeout(downTimer);
    downTimer = null;
    if (bootId && boot !== bootId) {
      // A new engine: reload, keeping the place in the video being watched.
      if (player.isOpen && player.fid) history.replaceState(null, '', watchUrl(player.fid, player.time));
      return location.reload();
    }
    bootId = boot;
    stoppedEl?.remove();
    stoppedEl = null;
  });
  session.onerror = () => {
    downTimer ??= setTimeout(showStopped, 2500);
    // Refused outright (an engine without sessions): the browser won't retry, so do.
    if (session.readyState === EventSource.CLOSED) setTimeout(connect, 1000);
  };
}
connect();

route();
pollStatus();
