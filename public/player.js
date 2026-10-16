// Full-screen player: custom controls, resume, Skip Intro, Next Episode,
// subtitles, audio tracks, volume boost up to 200%, and on-the-fly
// remux/transcode (through the server's ffmpeg) for files the browser
// cannot play directly.

import { state, api, h, ic, artBox, fmtTime, toast, loc, fileOf, progressOf, epCode, nextAfter, watchUrl } from './lib.js';

const MAX_VOLUME = 2; // 200%, like VLC
const SAVE_EVERY_MS = 5000;
const HIDE_AFTER_MS = 3000;
const SPEED_STOPS = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3];
const MIN_SPEED = 0.25;
const MAX_SPEED = 3; // browsers mute audio above 4x
const fmtSpeed = (s) => `${+s.toFixed(2)}×`;

const store = {
  get(k, d) {
    try {
      const v = localStorage.getItem(k);
      return v == null ? d : JSON.parse(v);
    } catch {
      return d;
    }
  },
  set(k, v) {
    try {
      localStorage.setItem(k, JSON.stringify(v));
    } catch {}
  },
};

// ---- Format support -----------------------------------------------------------

const probeEl = document.createElement('video');
const can = (type) => probeEl.canPlayType(type) !== '';
const CAN = {
  hevc: can('video/mp4; codecs="hvc1.1.6.L93.B0"'),
  av1: can('video/mp4; codecs="av01.0.05M.08"'),
  vp9: can('video/mp4; codecs="vp09.00.10.08"') || can('video/webm; codecs="vp9"'),
};
const AUDIO_OK = new Set(['aac', 'mp3', 'opus', 'vorbis', 'flac']);
const DIRECT_CONTAINERS = new Set(['mp4', 'm4v', 'mov', 'webm', 'mkv']);

function videoPlayable(v) {
  if (!v) return true;
  switch (v.codec) {
    case 'h264':
      return !/10|4:2:2|4:4:4/.test(v.profile) && !/(10|12)le|422|444/.test(v.pixFmt);
    case 'hevc':
      return CAN.hevc;
    case 'av1':
      return CAN.av1;
    case 'vp9':
      return CAN.vp9;
    case 'vp8':
      return true;
    default:
      return false;
  }
}

// direct: the browser reads the file itself (best).
// remux: ffmpeg repackages the video untouched, audio to AAC (cheap).
// transcode: ffmpeg re-encodes video to H.264 (hardware encoder on Macs).
function chooseMode(info, ext, audio, ffmpeg) {
  if (!info || !ffmpeg) return 'direct';
  const vOk = videoPlayable(info.video);
  const a = info.audio[audio];
  const defaultAudio = Math.max(0, info.audio.findIndex((x) => x.default));
  const aOk = !a || AUDIO_OK.has(a.codec);
  if (vOk && aOk && DIRECT_CONTAINERS.has(ext) && (info.audio.length <= 1 || audio === defaultAudio)) return 'direct';
  if (vOk && info.video?.codec !== 'vp8') return 'remux';
  return 'transcode';
}

const MODE_LABEL = { direct: 'Direct play', remux: 'Repackaged on the fly (video untouched)', transcode: 'Converted on the fly' };

// ISO 639 code ("jpn", "en") -> "Japanese".
const LANG3 = { eng: 'en', jpn: 'ja', spa: 'es', fre: 'fr', fra: 'fr', ger: 'de', deu: 'de', ita: 'it', por: 'pt', kor: 'ko', chi: 'zh', zho: 'zh', hin: 'hi', rus: 'ru', ara: 'ar', dut: 'nl', nld: 'nl', swe: 'sv', nor: 'no', dan: 'da', fin: 'fi', pol: 'pl', tur: 'tr', tam: 'ta', tel: 'te' };
const langNames = typeof Intl.DisplayNames === 'function' ? new Intl.DisplayNames(['en'], { type: 'language' }) : null;
function langName(code) {
  if (!code || code === 'und') return '';
  try {
    return langNames?.of(LANG3[code] || code) || code;
  } catch {
    return code;
  }
}

// ---- Subtitles ---------------------------------------------------------------------

function parseTs(s) {
  const m = s.trim().replace(',', '.').match(/^(?:(\d+):)?(\d{1,2}):(\d{1,2}(?:\.\d+)?)$/);
  return m ? Number(m[1] || 0) * 3600 + Number(m[2]) * 60 + Number(m[3]) : NaN;
}
function cueHtml(text) {
  const esc = text.replace(/\{\\[^}]*\}/g, '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return esc.replace(/&lt;(\/?)([ibu])&gt;/gi, '<$1$2>').replace(/&lt;\/?[a-z][^&]*?&gt;/gi, '');
}
function parseVtt(text) {
  const cues = [];
  for (const block of text.replace(/\r/g, '').split(/\n{2,}/)) {
    const lines = block.split('\n');
    const i = lines.findIndex((l) => l.includes('-->'));
    if (i < 0) continue;
    const [a, b] = lines[i].split('-->');
    const start = parseTs(a);
    const end = parseTs(b.trim().split(/\s+/)[0]);
    const body = lines.slice(i + 1).join('\n').trim();
    if (!Number.isNaN(start) && !Number.isNaN(end) && body) cues.push({ start, end, html: cueHtml(body) });
  }
  return cues.sort((x, y) => x.start - y.start);
}

// ---- Player ------------------------------------------------------------------------------

export class Player {
  constructor(root) {
    this.root = root;
    this.el = null;
    this.fid = null;
    this.volume = Math.min(MAX_VOLUME, store.get('volume', 1));
    this.muted = store.get('muted', false);
    this.speed = Math.min(MAX_SPEED, Math.max(MIN_SPEED, Number(store.get('speed', 1)) || 1));
  }

  get isOpen() {
    return !!this.fid;
  }

  get duration() {
    return this.info?.probe?.duration || (Number.isFinite(this.video?.duration) ? this.video.duration : 0);
  }

  get time() {
    if (this.pendingSeek != null) return this.pendingSeek;
    return this.offset + (this.video.currentTime || 0);
  }

  // ---- open / close -------------------------------------------------------------

  async open(fid, { start = null, returnTo = null } = {}) {
    if (this.fid === fid && start == null) return;
    if (returnTo && !returnTo.startsWith('#/watch')) this.returnTo = returnTo;
    if (!this.el) this.build();
    if (this.fid) {
      this.saveProgress();
      this.stopMedia();
    }
    this.fid = fid;
    this.info = null;
    this.mode = null;
    this.resetEpisodeState();
    this.root.hidden = false;
    document.body.classList.add('no-scroll');
    this.showControls();
    this.setLoading(true);

    let info;
    try {
      info = await api.get(`/api/play/${fid}`);
    } catch (e) {
      return this.showError('Cannot open this video', e.message);
    }
    if (this.fid !== fid) return; // switched again meanwhile
    this.info = info;
    this.markers = info.markers || {};
    const w = loc(fid);
    this.title = w?.title;
    this.nextId = nextAfter(fid);
    this.renderTitle();
    this.renderMarkerSegments();

    const audio = this.pickAudio(info.probe);
    this.audio = audio;
    this.mode = chooseMode(info.probe, info.ext, audio, info.ffmpeg);

    if (start == null) {
      const p = progressOf(fid) || info.progress;
      start = p && !p.watched && p.position > 5 && (!this.duration || p.position < this.duration - 10) ? p.position - 2 : 0;
    }
    this.startMedia(Math.max(0, start));
    this.autoSubtitles();
    this.updateMediaSession();
  }

  // Called by the router when navigating away from the player.
  hide() {
    if (!this.fid) return;
    this.saveProgress(true);
    this.stopMedia();
    this.fid = null;
    this.info = null;
    this.closePanel();
    this.root.hidden = true;
    document.body.classList.remove('no-scroll');
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    if ('mediaSession' in navigator) navigator.mediaSession.metadata = null;
    state.dirty = true;
  }

  exit() {
    const back = this.returnTo || (this.title ? `#/title/${this.title.id}` : '#/');
    this.returnTo = null;
    location.hash = back;
  }

  resetEpisodeState() {
    this.offset = 0;
    this.pendingSeek = null;
    this.cues = [];
    this.cueIndex = 0;
    this.subId = null;
    this.lastTick = null;
    this.introSkipped = false;
    this.nextDismissed = false;
    this.nextShownFor = null;
    this.lastSaved = 0;
    this.endedHandled = false;
    this.failures = 0;
    this.hideNext();
    this.skipBtn.hidden = true;
    this.errorEl.hidden = true;
    this.subsEl.replaceChildren();
    this.closePanel();
  }

  pickAudio(info) {
    const tracks = info?.audio || [];
    if (tracks.length <= 1) return 0;
    const pref = store.get('audioLang', '');
    const byPref = pref ? tracks.findIndex((t) => t.lang === pref) : -1;
    if (byPref >= 0) return byPref;
    return Math.max(0, tracks.findIndex((t) => t.default));
  }

  // ---- media -----------------------------------------------------------------------

  streamUrl(at) {
    return `/api/stream/${this.fid}?mode=${this.mode}&audio=${this.audio}&start=${at.toFixed(2)}`;
  }

  startMedia(at) {
    const v = this.video;
    this.stopping = false;
    this.pendingSeek = null;
    this.setLoading(true);
    if (this.mode === 'direct') {
      this.offset = 0;
      this.directStart = at;
      v.src = `/media/${this.fid}`;
    } else {
      this.offset = at;
      v.src = this.streamUrl(at);
    }
    this.applySpeed();
    this.applyVolume();
    v.play().catch(() => {});
  }

  stopMedia() {
    this.stopping = true;
    clearTimeout(this.seekTimer);
    const v = this.video;
    v.pause();
    v.removeAttribute('src');
    v.load();
  }

  onMediaError() {
    if (this.stopping || !this.fid) return;
    const at = this.time;
    // Fall back step by step: direct -> remux -> transcode.
    if (this.info?.ffmpeg && this.mode !== 'transcode') {
      const vOk = videoPlayable(this.info.probe?.video);
      this.mode = this.mode === 'direct' && vOk ? 'remux' : 'transcode';
      console.info('[player] falling back to', this.mode);
      return this.startMedia(at);
    }
    if (this.failures++ < 1 && this.mode !== 'direct') return this.startMedia(at);
    const hint = this.info?.ffmpeg ? 'The file may be damaged or use a format ffmpeg cannot read.' : 'Install ffmpeg (brew install ffmpeg) so unsupported formats can be converted while playing.';
    this.showError('This video could not be played', hint);
  }

  seek(t) {
    if (!this.info || this.mode == null) return; // still opening
    const dur = this.duration;
    t = Math.max(0, dur ? Math.min(t, dur - 0.25) : t);
    this.nextDismissed = this.nextDismissed && t >= (this.markers.credits?.start ?? Infinity);
    this.endedHandled = false;
    if (this.mode === 'direct') {
      this.video.currentTime = t;
    } else {
      // Streams restart at the new position; wait for key repeats to settle.
      this.pendingSeek = t;
      this.wasPlaying = !this.video.paused || this.wasPlaying;
      this.video.pause();
      clearTimeout(this.seekTimer);
      this.seekTimer = setTimeout(() => {
        const resume = this.wasPlaying;
        this.wasPlaying = false;
        this.startMedia(t);
        if (!resume) this.video.pause();
      }, 300);
    }
    this.lastTick = t;
    this.update(true);
    this.saveSoon();
  }

  togglePlay() {
    const v = this.video;
    if (this.pendingSeek != null) {
      this.wasPlaying = !this.wasPlaying;
      return;
    }
    if (v.paused) v.play().catch(() => {});
    else v.pause();
    this.flash(v.paused ? 'pause' : 'play');
  }

  // ---- volume (0..200%) ------------------------------------------------------------

  // Above 100% the audio goes through Web Audio: gain, then a limiter so
  // boosted peaks are squashed instead of clipping harshly.
  ensureBoost() {
    if (this.ctx !== undefined) return !!this.ctx;
    try {
      const ctx = new (window.AudioContext || window.webkitAudioContext)();
      const src = ctx.createMediaElementSource(this.video);
      const gain = ctx.createGain();
      const limiter = ctx.createDynamicsCompressor();
      limiter.threshold.value = -1.5;
      limiter.knee.value = 0;
      limiter.ratio.value = 20;
      limiter.attack.value = 0.002;
      limiter.release.value = 0.2;
      src.connect(gain).connect(limiter).connect(ctx.destination);
      this.ctx = ctx;
      this.gain = gain;
    } catch (e) {
      console.warn('[player] volume boost unavailable', e);
      this.ctx = null;
    }
    return !!this.ctx;
  }

  applyVolume() {
    const level = this.muted ? 0 : this.volume;
    if (level > 1) this.ensureBoost();
    if (this.ctx) {
      this.video.volume = 1;
      this.gain.gain.setTargetAtTime(level, this.ctx.currentTime, 0.015);
      if (this.ctx.state === 'suspended') this.ctx.resume().catch(() => {});
    } else {
      this.video.volume = Math.min(1, level);
    }
    this.video.muted = false;
    if (this.volEl) {
      const pct = Math.round(level * 100);
      this.volRange.value = Math.round(this.volume * 100);
      this.volRange.style.setProperty('--fill', `${(this.volume / MAX_VOLUME) * 100}%`);
      this.volPct.textContent = `${pct}%`;
      this.volPct.classList.toggle('boost', level > 1);
      this.volBtn.replaceChildren(ic(level === 0 ? 'volumeOff' : 'volume'));
    }
  }

  setVolume(v, { osd = false } = {}) {
    this.volume = Math.max(0, Math.min(MAX_VOLUME, Math.round(v * 100) / 100));
    this.muted = this.volume === 0;
    store.set('volume', this.volume);
    store.set('muted', this.muted);
    this.applyVolume();
    if (osd) this.osd(`Volume ${Math.round(this.volume * 100)}%`);
  }

  toggleMute() {
    if (this.muted && this.volume === 0) this.volume = 1;
    this.muted = !this.muted;
    store.set('muted', this.muted);
    this.applyVolume();
    this.osd(this.muted ? 'Muted' : `Volume ${Math.round(this.volume * 100)}%`);
  }

  // ---- speed (0.25x..3x, remembered) ---------------------------------------------------

  applySpeed() {
    const v = this.video;
    // defaultPlaybackRate survives the reload that each stream restart does.
    v.defaultPlaybackRate = this.speed;
    v.playbackRate = this.speed;
    v.preservesPitch = true; // faster, but voices keep their pitch
    if (this.speedLabel) {
      this.speedLabel.textContent = this.speed === 1 ? '' : fmtSpeed(this.speed);
      this.speedBtn.classList.toggle('on', this.speed !== 1);
    }
  }

  setSpeed(speed, { osd = false } = {}) {
    this.speed = Math.round(Math.min(MAX_SPEED, Math.max(MIN_SPEED, speed)) * 100) / 100;
    store.set('speed', this.speed);
    this.applySpeed();
    if (osd) this.osd(this.speed === 1 ? 'Normal speed' : `Speed ${fmtSpeed(this.speed)}`);
    if (this.panelOpen === 'speed') this.renderPanel();
  }

  // Step to the next multiple of `step` in either direction.
  stepSpeed(dir, step) {
    const base = dir > 0 ? Math.floor(this.speed / step + 1e-6) : Math.ceil(this.speed / step - 1e-6);
    this.setSpeed((base + dir) * step, { osd: true });
  }

  // ---- progress ------------------------------------------------------------------------

  saveSoon() {
    clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => this.saveProgress(), 800);
  }

  saveProgress(final = false) {
    if (!this.fid || !this.duration || this.pendingSeek != null) return;
    const body = { fileId: this.fid, position: this.time, duration: this.duration };
    if (body.position < 1 && !progressOf(this.fid)) return;
    this.lastSaved = Date.now();
    const fid = this.fid;
    fetch('/api/progress', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body), keepalive: final })
      .then((r) => r.json())
      .then((entry) => {
        if (entry && state.lib) {
          state.lib.progress[fid] = entry;
          state.dirty = true;
        }
      })
      .catch(() => {});
  }

  // ---- per-frame update -----------------------------------------------------------------

  tick = () => {
    if (!this.fid) {
      this.raf = null;
      return;
    }
    this.update();
    this.raf = requestAnimationFrame(this.tick);
  };

  update(force = false) {
    const t = this.time;
    const dur = this.duration;
    if (!this.dragging) {
      const pct = dur ? Math.min(100, (t / dur) * 100) : 0;
      this.fill.style.width = `${pct}%`;
      this.knob.style.left = `${pct}%`;
    }
    const sec = Math.floor(t);
    if (force || sec !== this.lastSec) {
      this.lastSec = sec;
      this.timeEl.textContent = dur ? `-${fmtTime(dur - t)}` : fmtTime(t);
      this.timeEl.title = `${fmtTime(t)} / ${fmtTime(dur)}`;
      this.updateBuffered();
    }
    this.renderSubs(t);
    if (this.pendingSeek == null && this.video.readyState >= 2) this.checkMarkers(t);
    if (!this.video.paused && Date.now() - this.lastSaved > SAVE_EVERY_MS) this.saveProgress();
    this.lastTick = t;
  }

  updateBuffered() {
    const v = this.video;
    const dur = this.duration;
    if (!dur || !v.buffered.length) return;
    let end = 0;
    for (let i = 0; i < v.buffered.length; i++) {
      if (v.buffered.start(i) <= v.currentTime + 0.5) end = Math.max(end, v.buffered.end(i));
    }
    const from = (this.offset / dur) * 100;
    const to = Math.min(100, ((this.offset + end) / dur) * 100);
    this.buf.style.left = `${this.mode === 'direct' ? 0 : from}%`;
    this.buf.style.width = `${Math.max(0, to - (this.mode === 'direct' ? 0 : from))}%`;
  }

  checkMarkers(t) {
    const settings = state.lib?.settings || {};
    const intro = this.markers.intro;
    const inIntro = !!intro && t >= intro.start && t < intro.end - 1;
    // Auto-skip only when playback runs into the intro, not after seeking into it.
    if (inIntro && settings.autoSkipIntro && !this.introSkipped && this.lastTick != null && this.lastTick < intro.start + 0.75 && t - this.lastTick < 1.5) {
      this.introSkipped = true;
      this.seek(intro.end);
      this.osd('Intro skipped');
      return;
    }
    this.skipBtn.hidden = !inIntro;

    const credits = this.markers.credits?.start;
    if (this.nextId && credits != null && t >= credits && !this.nextDismissed && this.nextShownFor !== this.fid && t < this.duration - 0.5) {
      this.showNext(settings.autoplayNext ? settings.nextCountdown ?? 10 : 0);
    } else if (this.nextShownFor === this.fid && credits != null && t < credits - 1) {
      this.hideNext();
    }
  }

  // ---- subtitles ------------------------------------------------------------------------

  async selectSubtitle(id, { remember = true } = {}) {
    this.subId = id;
    this.cues = [];
    this.cueIndex = 0;
    this.subsEl.replaceChildren();
    const sub = this.info?.subtitles.find((s) => s.id === id);
    if (remember) store.set('subLabel', sub ? sub.label : null);
    if (sub) store.set('lastSubLabel', sub.label);
    this.renderPanel();
    if (!sub) return;
    try {
      const r = await fetch(`/api/subtitle/${this.fid}/${id}`);
      if (!r.ok) throw new Error();
      if (this.subId !== id) return;
      this.cues = parseVtt(await r.text());
      if (!this.cues.length) toast('That subtitle track is empty');
    } catch {
      toast('Could not load subtitles');
    }
  }

  autoSubtitles() {
    const label = store.get('subLabel', null);
    if (!label || !this.info?.subtitles.length) return;
    const lang = label.split(' ')[0].toLowerCase();
    const hit = this.info.subtitles.find((s) => s.label === label) || this.info.subtitles.find((s) => s.label.toLowerCase().startsWith(lang));
    if (hit) this.selectSubtitle(hit.id, { remember: false });
  }

  renderSubs(t) {
    if (!this.cues.length) {
      if (this.subsShown) {
        this.subsEl.replaceChildren();
        this.subsShown = '';
      }
      return;
    }
    const active = [];
    for (const c of this.cues) {
      if (c.start > t) break;
      if (c.end > t) active.push(c.html);
    }
    const html = active.join('\n');
    if (html !== this.subsShown) {
      this.subsShown = html;
      this.subsEl.innerHTML = html ? `<span>${html}</span>` : '';
    }
  }

  // ---- next episode ----------------------------------------------------------------------

  showNext(countdown) {
    const next = this.nextId;
    if (!next) return;
    this.nextShownFor = this.fid;
    const f = fileOf(next);
    const fillEl = h('i');
    const go = h('button', { class: 'btn btn-play count', onclick: () => this.playNext() }, fillEl, ic('play'), 'Next Episode');
    const card = h('div', { class: 'next-card' },
      artBox(`/api/art/file/${next}?w=480`, f.name),
      h('div', { class: 'info' },
        h('div', { class: 'eyebrow' }, `Up next · ${epCode(next)}`),
        h('h3', {}, f.name),
        h('div', { class: 'acts' }, go, h('button', { class: 'btn btn-ghost', onclick: () => this.dismissNext() }, 'Watch Credits'))));
    this.nextEl.replaceChildren(card);
    this.nextEl.hidden = false;
    clearInterval(this.countTimer);
    if (countdown > 0) {
      // The countdown only runs while the video plays (or has ended).
      let remaining = countdown * 1000;
      let last = Date.now();
      this.countTimer = setInterval(() => {
        const now = Date.now();
        const dt = now - last;
        last = now;
        if (this.video.paused && !this.video.ended) return;
        remaining -= dt;
        fillEl.style.width = `${Math.min(100, 100 - (remaining / (countdown * 1000)) * 100)}%`;
        if (remaining <= 0) this.playNext();
      }, 100);
    }
  }

  hideNext() {
    clearInterval(this.countTimer);
    this.nextShownFor = null;
    if (this.nextEl) {
      this.nextEl.hidden = true;
      this.nextEl.replaceChildren();
    }
  }

  dismissNext() {
    this.nextDismissed = true;
    clearInterval(this.countTimer);
    if (this.nextEl) this.nextEl.hidden = true;
  }

  playNext() {
    clearInterval(this.countTimer);
    if (!this.nextId) return;
    this.saveProgress();
    location.replace(watchUrl(this.nextId));
  }

  onEnded() {
    if (this.endedHandled) return;
    this.endedHandled = true;
    this.saveProgress();
    const autoplay = state.lib?.settings?.autoplayNext ?? true;
    if (this.nextId && autoplay && !this.nextDismissed) return this.playNext();
    if (this.nextId) return this.showNext(0);
    setTimeout(() => this.fid && this.exit(), 1200);
  }

  // ---- markers (manual corrections) ---------------------------------------------------------------

  async setMarkers(patch, msg) {
    try {
      this.markers = await api.post(`/api/markers/${this.fid}`, patch);
      if (state.lib) {
        if (this.markers.intro || this.markers.credits) state.lib.markers[this.fid] = { intro: this.markers.intro, credits: this.markers.credits };
        else delete state.lib.markers[this.fid];
      }
      this.renderMarkerSegments();
      this.renderPanel();
      if (msg) toast(msg);
    } catch (e) {
      toast(e.message);
    }
  }

  renderMarkerSegments() {
    this.segs.replaceChildren();
    const dur = this.duration;
    if (!dur) return;
    const { intro, credits } = this.markers || {};
    const seg = (a, b, cls, label) => h('div', { class: `seg ${cls}`, title: label, style: { left: `${(a / dur) * 100}%`, width: `${((b - a) / dur) * 100}%` } });
    if (intro) this.segs.append(seg(intro.start, intro.end, 'intro', 'Intro'));
    if (credits) this.segs.append(seg(credits.start, dur, 'credits', 'Credits'));
  }

  // ---- UI -----------------------------------------------------------------------------------------

  renderTitle() {
    const f = fileOf(this.fid);
    const t = this.title;
    const code = epCode(this.fid);
    this.titleEl.replaceChildren(h('b', {}, t?.name || f?.name || ''), t?.kind === 'show' ? h('span', {}, `${code}  ${f.name}`) : null);
    this.midTitle.textContent = t?.kind === 'show' ? `${code} · ${f.name}` : t?.name || '';
    this.nextBtn.hidden = !this.nextId;
    this.epsBtn.hidden = t?.kind !== 'show' && !(t && t.seasons[0].episodes.length > 1);
  }

  setLoading(on) {
    this.loading = on;
    this.centerEl.replaceChildren(on ? h('div', { class: 'spinner' }) : '');
  }

  flash(icon) {
    this.centerEl.replaceChildren(h('div', { class: 'flash' }, ic(icon)));
  }

  osd(text) {
    toast(text, 1200);
  }

  showError(title, msg) {
    this.setLoading(false);
    this.errorEl.replaceChildren(h('div', {},
      h('h2', {}, title),
      h('p', {}, msg),
      h('div', { class: 'btns', style: { 'justify-content': 'center' } },
        h('button', { class: 'btn btn-play', onclick: () => { this.errorEl.hidden = true; this.failures = 0; this.startMedia(this.time); } }, 'Try again'),
        h('button', { class: 'btn btn-ghost', onclick: () => this.exit() }, 'Back'))));
    this.errorEl.hidden = false;
    this.showControls();
  }

  showControls() {
    if (!this.el) return;
    this.el.classList.remove('idle');
    clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => {
      if (!this.video.paused && !this.panelOpen && !this.dragging && !this.hoveringControls) this.el.classList.add('idle');
    }, HIDE_AFTER_MS);
  }

  toggleFullscreen() {
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    else this.el.requestFullscreen?.().catch(() => {});
  }

  updateMediaSession() {
    if (!('mediaSession' in navigator)) return;
    const f = fileOf(this.fid);
    const t = this.title;
    navigator.mediaSession.metadata = new MediaMetadata({
      title: t?.kind === 'show' ? f.name : t?.name || f.name,
      artist: t?.kind === 'show' ? `${t.name} · ${epCode(this.fid)}` : '',
      artwork: [{ src: `/api/art/file/${this.fid}?w=480`, sizes: '480x270', type: 'image/jpeg' }],
    });
    const ms = navigator.mediaSession;
    ms.setActionHandler('play', () => this.video.play());
    ms.setActionHandler('pause', () => this.video.pause());
    ms.setActionHandler('seekbackward', () => this.seek(this.time - 10));
    ms.setActionHandler('seekforward', () => this.seek(this.time + 10));
    ms.setActionHandler('seekto', (d) => this.seek(d.seekTime));
    ms.setActionHandler('nexttrack', this.nextId ? () => this.playNext() : null);
  }

  // ---- panels ----------------------------------------------------------------------------------------

  togglePanel(kind) {
    if (this.panelOpen === kind) return this.closePanel();
    this.panelOpen = kind;
    this.panelSeason = null;
    this.renderPanel();
    this.showControls();
  }

  closePanel() {
    this.panelOpen = null;
    if (this.panelEl) {
      this.panelEl.hidden = true;
      this.panelEl.replaceChildren();
    }
  }

  renderPanel() {
    if (!this.panelOpen || !this.info) return;
    this.panelEl.hidden = false;
    this.panelEl.className = 'panel';
    if (this.panelOpen === 'episodes') return this.renderEpisodesPanel();
    if (this.panelOpen === 'speed') return this.renderSpeedPanel();

    const opt = (label, on, fn) => h('button', { class: `opt${on ? ' on' : ''}`, onclick: fn }, label);
    const cols = [];
    const tracks = this.info.probe?.audio || [];
    if (tracks.length > 1) {
      cols.push(h('div', { class: 'col' }, h('h4', {}, 'Audio'),
        tracks.map((a, i) => {
          const lang = langName(a.lang);
          const name = [lang, a.title && a.title !== lang ? a.title : ''].filter(Boolean).join(' · ') || `Track ${i + 1}`;
          return opt(`${name}${a.channels > 2 ? ` · ${a.channels === 6 ? '5.1' : a.channels === 8 ? '7.1' : `${a.channels}ch`}` : ''}`, i === this.audio, () => this.switchAudio(i));
        })));
    }
    cols.push(h('div', { class: 'col' }, h('h4', {}, 'Subtitles'),
      opt('Off', !this.subId, () => this.selectSubtitle(null)),
      this.info.subtitles.map((s) => opt(s.label, s.id === this.subId, () => this.selectSubtitle(s.id)))));

    const m = this.markers;
    const now = () => Math.round(this.time * 10) / 10;
    const dur = this.duration;
    const introTxt = m.intro ? `${fmtTime(m.intro.start)} – ${fmtTime(m.intro.end)}` : 'none';
    const credTxt = m.credits ? fmtTime(m.credits.start) : 'none';
    cols.push(h('div', { class: 'col wide' }, h('h4', {}, 'Intro & credits'),
      h('div', { class: 'mk' },
        h('div', {}, `Intro: ${introTxt}`),
        h('div', {}, `Credits: ${credTxt}`),
        h('div', { class: 'muted' }, m.manual ? 'Corrected by you' : m.state === 'done' ? `Detected · ${m.method?.intro || m.method?.credits || 'nothing found'}` : m.state === 'queued' ? 'Detection queued…' : 'Not analysed yet'),
        h('div', { class: 'muted' }, MODE_LABEL[this.mode])),
      h('div', { class: 'mk-btns' },
        h('button', { onclick: () => this.setMarkers({ intro: { start: now(), end: Math.max(now() + 5, m.intro?.end ?? now() + 60) } }, 'Intro start set') }, `Intro starts here (${fmtTime(this.time)})`),
        h('button', { onclick: () => this.setMarkers({ intro: { start: Math.min(m.intro?.start ?? 0, now() - 1), end: now() } }, 'Intro end set') }, `Intro ends here (${fmtTime(this.time)})`),
        h('button', { onclick: () => this.setMarkers({ credits: { start: Math.min(now(), dur) } }, 'Credits start set') }, `Credits start here (${fmtTime(this.time)})`),
        h('button', { onclick: () => this.setMarkers({ intro: null }, 'Intro cleared') }, 'No intro in this episode'),
        m.manual ? h('button', { onclick: () => this.setMarkers({ reset: true }, 'Back to detected markers') }, 'Use detected markers') : null)));
    this.panelEl.replaceChildren(h('div', { class: 'cols' }, cols));
  }

  renderSpeedPanel() {
    this.panelEl.className = 'panel speed-panel';
    const stops = SPEED_STOPS.includes(this.speed) ? SPEED_STOPS : [...SPEED_STOPS, this.speed].sort((a, b) => a - b);
    this.panelEl.replaceChildren(
      h('h4', {}, 'Playback speed'),
      h('div', { class: 'speed-stops', role: 'radiogroup', 'aria-label': 'Playback speed' },
        stops.map((sp) => h('button', { class: `stop${sp === this.speed ? ' on' : ''}`, role: 'radio', 'aria-checked': String(sp === this.speed), onclick: () => this.setSpeed(sp) },
          h('i'), h('span', {}, fmtSpeed(sp)), sp === 1 ? h('small', {}, 'Normal') : null))),
      h('p', { class: 'muted' }, '[ slower · ] faster · { } fine steps · = normal. Voices keep their pitch.'));
  }

  renderEpisodesPanel() {
    const w = loc(this.fid);
    if (!w) return;
    this.panelEl.className = 'panel ep-panel';
    const t = w.title;
    const season = this.panelSeason ?? w.seasonIndex;
    const sel = t.seasons.length > 1
      ? h('div', { class: 'select' }, h('select', { onchange: (e) => { this.panelSeason = Number(e.target.value); this.renderEpisodesPanel(); } },
          t.seasons.map((s, i) => h('option', { value: i, selected: i === season }, s.name))))
      : null;
    const rows = t.seasons[season].episodes.map((fid) => {
      const f = fileOf(fid);
      const p = progressOf(fid);
      const art = artBox(`/api/art/file/${fid}?w=320`, f.name);
      if (p && p.duration) art.append(h('div', { class: 'bar' }, h('i', { style: { width: `${p.watched ? 100 : (p.position / p.duration) * 100}%` } })));
      return h('div', { class: `row-ep${fid === this.fid ? ' current' : ''}`, onclick: () => { this.closePanel(); location.replace(watchUrl(fid)); } },
        art, h('div', {}, h('h5', {}, `${f.number != null ? `${f.number}. ` : ''}${f.name}`), h('p', {}, f.duration ? `${Math.round(f.duration / 60)} min` : '')));
    });
    this.panelEl.replaceChildren(h('header', {}, h('h4', {}, t.name), sel), ...rows);
    const cur = this.panelEl.querySelector('.current');
    if (cur) cur.scrollIntoView({ block: 'center' });
  }

  switchAudio(i) {
    if (i === this.audio) return;
    const at = this.time;
    this.audio = i;
    store.set('audioLang', this.info.probe.audio[i].lang || '');
    const next = chooseMode(this.info.probe, this.info.ext, i, this.info.ffmpeg);
    // Once converting, stay converting (switching back to direct is not needed).
    this.mode = this.mode === 'transcode' ? 'transcode' : next;
    this.startMedia(at);
    this.renderPanel();
  }

  // ---- build DOM once ----------------------------------------------------------------------------------

  build() {
    const v = h('video', { playsinline: true, preload: 'auto' });
    this.video = v;
    this.subsEl = h('div', { class: 'subs' });
    this.centerEl = h('div', { class: 'p-center' });
    this.errorEl = h('div', { class: 'p-error', hidden: true });
    this.titleEl = h('div', { class: 'p-title' });
    this.skipBtn = h('button', { class: 'skip-btn', hidden: true, onclick: (e) => { e.stopPropagation(); this.skipIntro(); } }, ic('skip'), 'Skip Intro');
    this.nextEl = h('div', { hidden: true, onclick: (e) => e.stopPropagation() });
    this.panelEl = h('div', { class: 'panel', hidden: true, onclick: (e) => e.stopPropagation() });

    // scrubber
    this.buf = h('div', { class: 'buf' });
    this.segs = h('div');
    this.fill = h('div', { class: 'fill' });
    this.knob = h('div', { class: 'knob' });
    this.tip = h('div', { class: 'tip' });
    const rail = h('div', { class: 'rail' }, this.buf, this.segs, this.fill, this.knob);
    const scrub = h('div', { class: 'scrub' }, rail, this.tip);
    const posAt = (e) => {
      const r = rail.getBoundingClientRect();
      return Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * this.duration;
    };
    scrub.addEventListener('pointermove', (e) => {
      const t = posAt(e);
      const r = rail.getBoundingClientRect();
      const m = this.markers || {};
      const where = m.intro && t >= m.intro.start && t < m.intro.end ? ' · Intro' : m.credits && t >= m.credits.start ? ' · Credits' : '';
      this.tip.textContent = fmtTime(t) + where;
      this.tip.style.left = `${Math.max(30, Math.min(r.width - 30, e.clientX - r.left))}px`;
      if (this.dragging) {
        this.dragT = t;
        const pct = (t / this.duration) * 100;
        this.fill.style.width = `${pct}%`;
        this.knob.style.left = `${pct}%`;
      }
    });
    scrub.addEventListener('pointerdown', (e) => {
      if (!this.duration) return;
      this.dragging = true;
      scrub.classList.add('drag');
      scrub.setPointerCapture(e.pointerId);
      this.dragT = posAt(e);
      scrub.dispatchEvent(new PointerEvent('pointermove', e));
    });
    const endDrag = () => {
      if (!this.dragging) return;
      this.dragging = false;
      scrub.classList.remove('drag');
      this.seek(this.dragT);
    };
    scrub.addEventListener('pointerup', endDrag);
    scrub.addEventListener('pointercancel', endDrag);

    // volume
    this.volBtn = h('button', { class: 'p-btn sm', title: 'Mute (M)', onclick: () => this.toggleMute() });
    this.volRange = h('input', { type: 'range', min: 0, max: MAX_VOLUME * 100, step: 5, 'aria-label': 'Volume', oninput: (e) => this.setVolume(Number(e.target.value) / 100) });
    this.volPct = h('span', { class: 'vol-pct' });
    this.volEl = h('div', { class: 'volume' }, this.volBtn, this.volRange, this.volPct);

    this.playBtn = h('button', { class: 'p-btn', title: 'Play / pause (Space)', onclick: () => this.togglePlay() }, ic('play'));
    this.timeEl = h('div', { class: 'p-time' });
    this.midTitle = h('div', { class: 'grow' });
    this.nextBtn = h('button', { class: 'p-btn sm', title: 'Next episode (N)', onclick: () => this.playNext() }, ic('next'));
    this.epsBtn = h('button', { class: 'p-btn sm', title: 'Episodes', onclick: () => this.togglePanel('episodes') }, ic('episodes'));
    this.fsBtn = h('button', { class: 'p-btn sm', title: 'Full screen (F)', onclick: () => this.toggleFullscreen() }, ic('fullscreen'));
    this.speedLabel = h('span', { class: 'speed-badge' });
    this.speedBtn = h('button', { class: 'p-btn sm speed-btn', title: 'Playback speed ([ and ])', onclick: () => this.togglePanel('speed') }, ic('speed'), this.speedLabel);

    const top = h('div', { class: 'p-top' },
      h('button', { class: 'p-btn', title: 'Back (Esc)', onclick: () => this.exit() }, ic('back')),
      this.titleEl);
    const bottom = h('div', { class: 'p-bottom' },
      scrub,
      h('div', { class: 'p-row' },
        this.playBtn,
        h('button', { class: 'p-btn', title: 'Back 10 s (←)', onclick: () => this.seek(this.time - 10) }, ic('replay10')),
        h('button', { class: 'p-btn', title: 'Forward 10 s (→)', onclick: () => this.seek(this.time + 10) }, ic('forward10')),
        this.volEl,
        this.midTitle,
        this.timeEl,
        this.nextBtn,
        this.epsBtn,
        this.speedBtn,
        h('button', { class: 'p-btn sm', title: 'Audio, subtitles, intro markers', onclick: () => this.togglePanel('settings') }, ic('subtitles')),
        this.fsBtn));
    for (const bar of [top, bottom]) {
      bar.addEventListener('mouseenter', () => (this.hoveringControls = true));
      bar.addEventListener('mouseleave', () => (this.hoveringControls = false));
      bar.addEventListener('click', (e) => e.stopPropagation());
    }

    this.el = h('div', { class: 'player' }, v, this.subsEl, this.centerEl, top, bottom, this.skipBtn, this.nextEl, this.panelEl, this.errorEl);
    this.root.replaceChildren(this.el);

    // Click toggles play, double-click toggles full screen.
    let clickTimer;
    this.el.addEventListener('click', (e) => {
      if (e.target !== v && e.target !== this.el && e.target !== this.subsEl) return;
      if (this.panelOpen) return this.closePanel();
      clearTimeout(clickTimer);
      clickTimer = setTimeout(() => this.togglePlay(), 220);
    });
    this.el.addEventListener('dblclick', (e) => {
      if (e.target !== v && e.target !== this.el) return;
      clearTimeout(clickTimer);
      this.toggleFullscreen();
    });
    this.el.addEventListener('mousemove', () => this.showControls());
    this.el.addEventListener('touchstart', () => this.showControls(), { passive: true });

    v.addEventListener('loadedmetadata', () => {
      if (this.mode === 'direct' && this.directStart) {
        v.currentTime = this.directStart;
        this.directStart = 0;
      }
      this.renderMarkerSegments();
    });
    v.addEventListener('playing', () => {
      this.setLoading(false);
      this.errorEl.hidden = true;
      this.failures = 0;
      this.showControls();
      if (!this.raf) this.raf = requestAnimationFrame(this.tick);
    });
    v.addEventListener('waiting', () => this.setLoading(true));
    v.addEventListener('canplay', () => this.loading && v.paused && this.pendingSeek == null && this.setLoading(false));
    v.addEventListener('play', () => {
      if (this.ctx?.state === 'suspended') this.ctx.resume().catch(() => {});
      this.playBtn.replaceChildren(ic('pause'));
      this.showControls();
    });
    v.addEventListener('pause', () => {
      this.playBtn.replaceChildren(ic('play'));
      this.showControls();
      if (this.pendingSeek == null && !this.stopping) this.saveProgress();
    });
    v.addEventListener('seeked', () => this.saveSoon());
    v.addEventListener('ended', () => this.onEnded());
    v.addEventListener('error', () => this.onMediaError());
    document.addEventListener('fullscreenchange', () => this.fsBtn.replaceChildren(ic(document.fullscreenElement ? 'fullscreenExit' : 'fullscreen')));
    document.addEventListener('keydown', (e) => this.onKey(e));
    document.addEventListener('visibilitychange', () => document.hidden && this.saveProgress(true));
    window.addEventListener('pagehide', () => this.saveProgress(true));
    this.applyVolume();
    this.applySpeed();
  }

  skipIntro() {
    const intro = this.markers.intro;
    if (!intro) return;
    this.introSkipped = true;
    this.seek(intro.end);
  }

  onKey(e) {
    if (!this.fid || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.target.matches?.('input[type=text], input[type=search], select')) return;
    const k = e.key;
    const handled = () => {
      e.preventDefault();
      this.showControls();
    };
    if (k === ' ' || k === 'k' || k === 'K') { handled(); this.togglePlay(); }
    else if (k === 'ArrowLeft' || k === 'j') { handled(); this.seek(this.time - (e.shiftKey ? 30 : 10)); }
    else if (k === 'ArrowRight' || k === 'l') { handled(); this.seek(this.time + (e.shiftKey ? 30 : 10)); }
    else if (k === 'ArrowUp') { handled(); this.setVolume(this.volume + 0.05, { osd: true }); }
    else if (k === 'ArrowDown') { handled(); this.setVolume(this.volume - 0.05, { osd: true }); }
    else if (k === ']' || k === '>') { handled(); this.stepSpeed(1, 0.25); }
    else if (k === '[' || k === '<') { handled(); this.stepSpeed(-1, 0.25); }
    else if (k === '}') { handled(); this.stepSpeed(1, 0.05); }
    else if (k === '{') { handled(); this.stepSpeed(-1, 0.05); }
    else if (k === '=') { handled(); this.setSpeed(1, { osd: true }); }
    else if (k === 'm' || k === 'M') { handled(); this.toggleMute(); }
    else if (k === 'f' || k === 'F') { handled(); this.toggleFullscreen(); }
    else if ((k === 's' || k === 'S') && !this.skipBtn.hidden) { handled(); this.skipIntro(); }
    else if ((k === 'n' || k === 'N') && this.nextId) { handled(); this.playNext(); }
    else if (k === 'c' || k === 'C') {
      handled();
      const subs = this.info?.subtitles || [];
      if (this.subId) this.selectSubtitle(null);
      else if (subs.length) this.selectSubtitle((subs.find((s) => s.label === store.get('lastSubLabel', '')) || subs[0]).id);
      this.osd(this.subId ? 'Subtitles on' : 'Subtitles off');
    } else if (k === 'Escape') {
      handled();
      if (this.panelOpen) this.closePanel();
      else if (document.fullscreenElement) document.exitFullscreen();
      else this.exit();
    } else if (/^[0-9]$/.test(k) && this.duration) { handled(); this.seek((Number(k) / 10) * this.duration); }
  }
}
