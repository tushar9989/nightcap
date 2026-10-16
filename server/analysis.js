// Keeps the intro/credits index: decides what needs analysing, feeds the
// worker one season (or movie) at a time, and stores the results.
//
// On disk (DATA_DIR):
//   analysis.json      markers per file, plus manual corrections
//   fingerprints/*.fp  audio fingerprints of each episode's first and last
//                      minutes, so adding an episode only fingerprints that
//                      episode and re-runs the (fast) matching for its season

import path from 'node:path';
import fsp from 'node:fs/promises';
import { Worker } from 'node:worker_threads';
import { DATA_DIR, FFMPEG, JsonStore, ensureDir, fileSig, hashId, sigHash } from './util.js';

const ANALYSIS_VERSION = 2; // bump to re-run matching (fingerprints are reused)
const FP_DIR = ensureDir(path.join(DATA_DIR, 'fingerprints'));

export class Analyzer {
  constructor({ getLibrary, probe, isEnabled }) {
    this.getLibrary = getLibrary;
    this.probe = probe;
    this.isEnabled = isEnabled;
    this.store = new JsonStore(path.join(DATA_DIR, 'analysis.json'), { version: ANALYSIS_VERSION, files: {}, manual: {} });
    this.queue = [];
    this.current = null;
    this.worker = null;
    this.jobSeq = 0;
    this.pending = new Map();
  }

  flush() {
    this.store.flush();
  }

  // Each season of a show (and each movie) is analysed as one group, because
  // episodes are compared with their neighbours in the same season.
  groups(title) {
    const lib = this.getLibrary();
    if (title.kind === 'movie') {
      return [{ key: title.id, titleId: title.id, kind: 'movie', label: title.name, fileIds: title.seasons.flatMap((s) => s.episodes), refs: [] }];
    }
    const regular = title.seasons.filter((s) => !s.extras);
    return regular.map((s, i) => {
      let refs = [];
      if (s.episodes.length < 3) {
        // Too few episodes to compare within the season: borrow neighbours.
        const others = [...(regular[i + 1]?.episodes || []), ...(regular[i - 1]?.episodes || [])];
        refs = others.slice(0, 4 - s.episodes.length).filter((id) => lib.files[id]);
      }
      return { key: `${title.id}:${s.id}`, titleId: title.id, seasonId: s.id, kind: 'show', label: `${title.name} · ${s.name}`, fileIds: s.episodes, refs };
    });
  }

  basis(group) {
    const files = this.getLibrary().files;
    return hashId([...group.fileIds, '|', ...group.refs].map((id) => (files[id] ? `${id}:${fileSig(files[id])}` : id)).join(','));
  }

  needsWork(group) {
    const basis = this.basis(group);
    return group.fileIds.some((id) => {
      const e = this.store.data.files[id];
      return !e || e.v !== ANALYSIS_VERSION || e.basis !== basis;
    });
  }

  // Queue everything that is new or changed. Recently added titles go first.
  sync() {
    const lib = this.getLibrary();
    const valid = new Set(Object.keys(lib.files));
    const wanted = [];
    for (const t of [...lib.titles].sort((a, b) => b.addedAt - a.addedAt)) {
      for (const g of this.groups(t)) if (this.needsWork(g)) wanted.push(g);
    }
    const queued = new Map(this.queue.map((g) => [g.key, g]));
    this.queue = wanted.filter((g) => g.key !== this.current?.group.key).map((g) => queued.get(g.key) ? { ...g, priority: queued.get(g.key).priority } : g);
    this.queue.sort((a, b) => (b.priority || 0) - (a.priority || 0));
    // An unplugged drive must not cost its index; only tidy up when every folder is reachable.
    if (Object.values(lib.folderStatus || {}).every((s) => s.online)) this.cleanup(valid);
    this.kick();
  }

  // Move a title (or one season of it) to the front of the queue.
  prioritize(titleId, seasonId) {
    const now = Date.now();
    for (const g of this.queue) {
      if (g.titleId === titleId) g.priority = now + (seasonId && g.seasonId === seasonId ? 1 : 0);
    }
    this.queue.sort((a, b) => (b.priority || 0) - (a.priority || 0));
    this.kick();
  }

  reanalyze(titleId) {
    const t = this.getLibrary().titles.find((x) => x.id === titleId);
    if (!t) return;
    for (const g of this.groups(t)) for (const id of g.fileIds) delete this.store.data.files[id];
    this.store.save();
    this.sync();
    this.prioritize(titleId);
  }

  markers(fileId) {
    const auto = this.store.data.files[fileId];
    const manual = this.store.data.manual[fileId] || {};
    return {
      intro: 'intro' in manual ? manual.intro : auto?.intro ?? null,
      credits: 'credits' in manual ? manual.credits : auto?.credits ?? null,
      manual: Object.keys(manual).length > 0,
      method: auto?.method || {},
      state: auto ? 'done' : this.isQueued(fileId) ? 'queued' : 'none',
    };
  }

  isQueued(fileId) {
    return this.current?.group.fileIds.includes(fileId) || this.queue.some((g) => g.fileIds.includes(fileId));
  }

  // Manual corrections win over detection and survive re-analysis.
  //   { intro: {start, end} | null, credits: {start} | null }, or { reset: true }
  setManual(fileId, patch) {
    if (patch.reset) delete this.store.data.manual[fileId];
    else {
      const m = (this.store.data.manual[fileId] ||= {});
      if ('intro' in patch) m.intro = patch.intro;
      if ('credits' in patch) m.credits = patch.credits;
    }
    this.store.save();
  }

  status() {
    const lib = this.getLibrary();
    let total = 0;
    let done = 0;
    for (const t of lib.titles) {
      for (const g of this.groups(t)) {
        total += g.fileIds.length;
        done += g.fileIds.filter((id) => this.store.data.files[id]?.v === ANALYSIS_VERSION).length;
      }
    }
    return {
      available: !!FFMPEG,
      enabled: this.isEnabled(),
      totalFiles: total,
      analyzedFiles: done,
      queuedGroups: this.queue.length,
      current: this.current ? { label: this.current.group.label, done: this.current.done, total: this.current.total } : null,
    };
  }

  ensureWorker() {
    if (this.worker) return this.worker;
    this.worker = new Worker(new URL('./analysis-worker.js', import.meta.url), { workerData: { fpDir: FP_DIR, ffmpeg: FFMPEG } });
    this.worker.unref();
    this.worker.on('message', (msg) => {
      const p = this.pending.get(msg.id);
      if (!p) return;
      if (msg.type === 'progress') {
        if (this.current) Object.assign(this.current, { done: msg.done, total: msg.total });
      } else {
        this.pending.delete(msg.id);
        msg.type === 'done' ? p.resolve(msg.results) : p.reject(new Error(msg.error));
      }
    });
    this.worker.on('error', (e) => console.error('[analysis] worker crashed:', e));
    this.worker.on('exit', () => {
      this.worker = null;
      for (const p of this.pending.values()) p.reject(new Error('analysis worker stopped'));
      this.pending.clear();
    });
    return this.worker;
  }

  async kick() {
    if (this.current || !FFMPEG || !this.isEnabled() || !this.queue.length) return;
    const group = this.queue.shift();
    this.current = { group, done: 0, total: group.fileIds.length };
    try {
      const lib = this.getLibrary();
      const describe = async (id) => {
        const f = lib.files[id];
        if (!f) return null;
        const info = await this.probe(f);
        return { id, path: f.path, sig: sigHash(f), duration: info?.duration || 0 };
      };
      const files = (await Promise.all(group.fileIds.map(describe))).filter(Boolean);
      const refs = (await Promise.all(group.refs.map(describe))).filter(Boolean);
      const id = ++this.jobSeq;
      const results = await new Promise((resolve, reject) => {
        this.pending.set(id, { resolve, reject });
        this.ensureWorker().postMessage({ type: 'job', id, job: { kind: group.kind, files, refs } });
      });
      const basis = this.basis(group);
      for (const [fid, r] of Object.entries(results)) {
        this.store.data.files[fid] = { v: ANALYSIS_VERSION, basis, at: Date.now(), ...r };
      }
      this.store.save();
      const found = Object.values(results);
      console.log(`[analysis] ${group.label}: intro in ${found.filter((r) => r.intro).length}/${found.length}, credits in ${found.filter((r) => r.credits).length}/${found.length}`);
    } catch (e) {
      console.error(`[analysis] ${group.label} failed:`, e.message);
      const basis = this.basis(group);
      for (const fid of group.fileIds) {
        this.store.data.files[fid] = { v: ANALYSIS_VERSION, basis, at: Date.now(), intro: null, credits: null, error: e.message };
      }
      this.store.save();
    } finally {
      this.current = null;
      setImmediate(() => this.kick());
    }
  }

  // Drop index entries and fingerprints for files that are no longer in the library.
  async cleanup(valid) {
    let changed = false;
    for (const id of Object.keys(this.store.data.files)) {
      if (!valid.has(id)) {
        delete this.store.data.files[id];
        changed = true;
      }
    }
    if (changed) this.store.save();
    const lib = this.getLibrary();
    const keep = new Set(Object.values(lib.files).map((f) => `${f.id}-${sigHash(f)}`));
    try {
      for (const name of await fsp.readdir(FP_DIR)) {
        const stem = name.replace(/-(head|tail)\.fp$/, '');
        if (!keep.has(stem)) await fsp.rm(path.join(FP_DIR, name), { force: true });
      }
    } catch {}
  }
}
