// Preview thumbnails ("trickplay"): a frame every few seconds, tiled into JPEG
// sheets, for the seek bar and the episode previews. Only keyframes are
// decoded, so a 45-minute episode takes about a second.
//
// On disk: DATA_DIR/trickplay/<fileId>-<sigHash>/{index.json, sheet-<n>.jpg}

import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { DATA_DIR, FFMPEG, ensureDir, run, sigHash } from './util.js';

const VERSION = 1;
const DIR = ensureDir(path.join(DATA_DIR, 'trickplay'));
const WIDTH = 240;
const COLS = 10;
const ROWS = 10;
const RETRY_FAILED_MS = 6 * 3600e3;

// Seconds between thumbnails: finer for short videos.
const intervalFor = (duration) => (duration <= 600 ? 2 : duration <= 3600 ? 5 : 10);

// Width and height from a JPEG's start-of-frame marker.
export function jpegSize(buf) {
  let i = 2;
  while (i + 9 < buf.length) {
    if (buf[i] !== 0xff) return null;
    const marker = buf[i + 1];
    const len = buf.readUInt16BE(i + 2);
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
      return { height: buf.readUInt16BE(i + 5), width: buf.readUInt16BE(i + 7) };
    }
    i += 2 + len;
  }
  return null;
}

export class Trickplay {
  constructor({ getLibrary, probe, isEnabled }) {
    this.getLibrary = getLibrary;
    this.probe = probe;
    this.isEnabled = isEnabled;
    this.ready = new Map(); // fileId -> manifest
    this.failed = new Map(); // `${id}-${sig}` -> time
    this.queue = []; // fileIds, next first
    this.current = null;
    this.loadIndex();
  }

  loadIndex() {
    for (const name of fs.readdirSync(DIR)) {
      try {
        const m = JSON.parse(fs.readFileSync(path.join(DIR, name, 'index.json'), 'utf8'));
        if (m.v === VERSION) this.ready.set(m.fileId, m);
      } catch {}
    }
  }

  manifest(file) {
    const m = this.ready.get(file.id);
    return m && m.key === sigHash(file) ? m : null;
  }

  sheetPath(file, n) {
    const m = this.manifest(file);
    return m && Number.isInteger(n) && n >= 0 && n < m.sheets ? path.join(DIR, `${file.id}-${m.key}`, `sheet-${n}.jpg`) : null;
  }

  state(file) {
    if (this.manifest(file)) return 'ready';
    if (this.current === file.id) return 'working';
    if (this.queue.includes(file.id)) return 'queued';
    return this.failed.has(`${file.id}-${sigHash(file)}`) ? 'failed' : 'none';
  }

  // Every episode and movie (not extras), recently added titles first.
  wanted() {
    const lib = this.getLibrary();
    const ids = [];
    for (const t of [...lib.titles].sort((a, b) => b.addedAt - a.addedAt)) {
      for (const s of t.seasons) if (!s.extras) ids.push(...s.episodes);
    }
    return ids.filter((id) => lib.files[id]);
  }

  sync() {
    const lib = this.getLibrary();
    if (this.isEnabled()) {
      const queued = new Set(this.queue);
      for (const id of this.wanted()) {
        const f = lib.files[id];
        if (!queued.has(id) && this.current !== id && !this.manifest(f) && !this.recentlyFailed(f)) this.queue.push(id);
      }
    }
    if (Object.values(lib.folderStatus || {}).every((s) => s.online)) this.cleanup();
    this.kick();
  }

  recentlyFailed(f) {
    const at = this.failed.get(`${f.id}-${sigHash(f)}`);
    return at && Date.now() - at < RETRY_FAILED_MS;
  }

  // Put these files at the front of the queue, in this order.
  prioritize(fileIds) {
    if (!this.isEnabled()) return;
    const files = this.getLibrary().files;
    const ids = fileIds.filter((id) => files[id] && !this.manifest(files[id]) && this.current !== id && !this.recentlyFailed(files[id]));
    this.queue = [...ids, ...this.queue.filter((id) => !ids.includes(id))];
    this.kick();
  }

  async kick() {
    if (this.current || !FFMPEG || !this.isEnabled()) return;
    const files = this.getLibrary().files;
    let id;
    while ((id = this.queue.shift())) if (files[id] && !this.manifest(files[id])) break;
    if (!id) return;
    this.current = id;
    try {
      await this.generate(files[id]);
    } catch (e) {
      this.failed.set(`${id}-${sigHash(files[id])}`, Date.now());
      console.warn(`[previews] ${files[id].name}: ${e.message}`);
    } finally {
      this.current = null;
      setImmediate(() => this.kick());
    }
  }

  async generate(file) {
    const info = await this.probe(file);
    if (!info?.video || !info.duration) throw new Error('no video to preview');
    const key = sigHash(file);
    const interval = intervalFor(info.duration);
    const final = path.join(DIR, `${file.id}-${key}`);
    const tmp = `${final}.tmp`;
    await fsp.rm(tmp, { recursive: true, force: true });
    await fsp.mkdir(tmp, { recursive: true });
    const vf = `fps=1/${interval}:round=near,scale=${WIDTH}:trunc(${WIDTH}/dar/2)*2,setsar=1,tile=${COLS}x${ROWS}`;
    const r = await run(FFMPEG, ['-nostdin', '-hide_banner', '-loglevel', 'error', '-skip_frame', 'nokey', '-i', file.path, '-map', '0:v:0', '-an', '-sn', '-dn',
      '-vf', vf, '-q:v', '6', '-start_number', '0', path.join(tmp, 'sheet-%d.jpg')], {
      timeout: 15 * 60e3,
      onSpawn: (child) => {
        try {
          os.setPriority(child.pid, 10);
        } catch {}
      },
    });
    const names = (await fsp.readdir(tmp)).filter((n) => /^sheet-\d+\.jpg$/.test(n));
    if (r.code !== 0 || !names.length) {
      await fsp.rm(tmp, { recursive: true, force: true });
      throw new Error(r.stderr.trim().split('\n').pop() || 'ffmpeg failed');
    }
    const first = await fsp.readFile(path.join(tmp, 'sheet-0.jpg'));
    const size = jpegSize(first);
    if (!size) throw new Error('unreadable preview sheet');
    let bytes = 0;
    for (const n of names) bytes += (await fsp.stat(path.join(tmp, n))).size;
    const manifest = {
      v: VERSION,
      fileId: file.id,
      key,
      interval,
      width: size.width / COLS,
      height: size.height / ROWS,
      cols: COLS,
      rows: ROWS,
      sheets: names.length,
      count: Math.min(names.length * COLS * ROWS, Math.floor(info.duration / interval) + 1),
      bytes,
    };
    await fsp.writeFile(path.join(tmp, 'index.json'), JSON.stringify(manifest));
    await fsp.rm(final, { recursive: true, force: true });
    await fsp.rename(tmp, final);
    this.ready.set(file.id, manifest);
    return manifest;
  }

  status() {
    const files = this.getLibrary().files;
    const wanted = this.wanted();
    let bytes = 0;
    for (const m of this.ready.values()) bytes += m.bytes || 0;
    return {
      enabled: this.isEnabled(),
      available: !!FFMPEG,
      total: wanted.length,
      done: wanted.filter((id) => this.manifest(files[id])).length,
      queued: this.queue.length,
      current: this.current ? files[this.current]?.name || null : null,
      bytes,
    };
  }

  // Remove previews of videos that left the library or changed on disk.
  async cleanup() {
    const files = this.getLibrary().files;
    const keep = new Set(Object.values(files).map((f) => `${f.id}-${sigHash(f)}`));
    let names = [];
    try {
      names = await fsp.readdir(DIR);
    } catch {}
    for (const name of names) {
      if (keep.has(name) || (this.current && name.startsWith(`${this.current}-`))) continue;
      await fsp.rm(path.join(DIR, name), { recursive: true, force: true });
      const id = name.split('-')[0];
      if (this.ready.get(id) && `${id}-${this.ready.get(id).key}` === name) this.ready.delete(id);
    }
  }
}
