// Lines subtitles up with the dialogue, on this machine.
//
// The audio becomes a speech-activity curve, 50 values per second: energy in
// the voice band (300-3400 Hz) relative to the local noise floor. The cues
// become on/off intervals. Correlating the two over offsets of up to three
// minutes, and over the usual frame-rate mix-ups (subtitles timed for 25 fps
// on a 23.976 fps video drift by a minute per 25 minutes), finds where the
// subtitles fit. The fit is only used when it clearly beats every other
// offset; subtitles for another episode, or with a different cut, never do.

import { spawn } from 'node:child_process';
import path from 'node:path';
import { DATA_DIR, FFMPEG, JsonStore, sigHash } from './util.js';
import { cueTimes } from './subtext.js';

export const RATE = 50; // activity values per second
const SAMPLE_RATE = 8000;
const HOP = SAMPLE_RATE / RATE;
const SCALES = [1, 25 / 23.976, 23.976 / 25, 24 / 23.976, 23.976 / 24, 25 / 24, 24 / 25];
const MIN_Z = 4; // peak height in standard deviations of all offsets
const MIN_RATIO = 1.3; // peak versus the best offset more than 2 s away

// Energy per frame (dB) -> speech activity 0..1: how far each frame rises
// above the quietest frames around it (20th percentile of 1 s minima, +-5 s).
export function activityFromEnergy(db) {
  const blocks = [];
  for (let i = 0; i < db.length; i += RATE) {
    let m = Infinity;
    for (let j = i; j < Math.min(db.length, i + RATE); j++) m = Math.min(m, db[j]);
    blocks.push(m);
  }
  const out = new Float32Array(db.length);
  for (let b = 0; b < blocks.length; b++) {
    const win = blocks.slice(Math.max(0, b - 5), b + 6).sort((x, y) => x - y);
    const floor = win[Math.floor(win.length * 0.2)];
    for (let i = b * RATE; i < Math.min(db.length, (b + 1) * RATE); i++) out[i] = Math.max(0, Math.min(1, (db[i] - floor - 6) / 12));
  }
  return out;
}

// Speech activity of one audio track of a video (about 3 s per 45 min).
export function speechActivity(file, audio = 0) {
  return new Promise((resolve, reject) => {
    if (!FFMPEG) return reject(new Error('ffmpeg is needed to sync subtitles'));
    const ff = spawn(FFMPEG, ['-nostdin', '-loglevel', 'error', '-i', file, '-map', `0:a:${audio}`, '-vn', '-sn', '-dn', '-ac', '1',
      '-af', `aresample=${SAMPLE_RATE},highpass=f=300,lowpass=f=3400`, '-f', 's16le', 'pipe:1'], { stdio: ['ignore', 'pipe', 'pipe'] });
    const db = [];
    let acc = 0;
    let n = 0;
    let carry = null;
    let err = '';
    ff.stderr.on('data', (d) => (err = (err + d).slice(-2000)));
    ff.stdout.on('data', (buf) => {
      if (carry) buf = Buffer.concat([carry, buf]);
      const even = buf.length & ~1;
      carry = even < buf.length ? buf.subarray(even) : null;
      for (let i = 0; i < even; i += 2) {
        const v = buf.readInt16LE(i);
        acc += v * v;
        if (++n === HOP) {
          db.push(10 * Math.log10(acc / HOP + 1));
          acc = 0;
          n = 0;
        }
      }
    });
    ff.on('error', reject);
    ff.on('close', (code) => {
      if (code !== 0 && !db.length) return reject(new Error(err.trim().split('\n').pop() || 'could not read the audio'));
      resolve(activityFromEnergy(Float32Array.from(db)));
    });
  });
}

// Best { offset, scale } so that cue time t belongs at t * scale + offset.
export function bestAlignment(activity, cues, { maxOffset = 180, scales = SCALES } = {}) {
  const len = activity.length;
  let mean = 0;
  for (let i = 0; i < len; i++) mean += activity[i];
  mean /= len || 1;
  // Prefix sums make each cue's overlap with the curve two lookups.
  const P = new Float64Array(len + 1);
  for (let i = 0; i < len; i++) P[i + 1] = P[i] + activity[i] - mean;
  const at = (i) => P[i < 0 ? 0 : i > len ? len : i];
  const MAX = Math.round(maxOffset * RATE);
  const results = [];
  for (const scale of scales) {
    const cs = cues.map(([a, b]) => [Math.round(a * scale * RATE), Math.round(b * scale * RATE)]);
    const c = new Float64Array(2 * MAX + 1);
    for (let k = -MAX; k <= MAX; k++) {
      let sum = 0;
      for (const [a, b] of cs) sum += at(b + k) - at(a + k);
      c[k + MAX] = sum;
    }
    let best = 0;
    let m = 0;
    for (let i = 0; i < c.length; i++) {
      m += c[i];
      if (c[i] > c[best]) best = i;
    }
    m /= c.length;
    let v = 0;
    let second = -Infinity;
    for (let i = 0; i < c.length; i++) {
      v += (c[i] - m) ** 2;
      if (Math.abs(i - best) > 2 * RATE && c[i] > second) second = c[i];
    }
    const sd = Math.sqrt(v / c.length) || 1;
    results.push({ scale, offset: (best - MAX) / RATE, z: (c[best] - m) / sd, ratio: second > m ? (c[best] - m) / (second - m) : Infinity });
  }
  results.sort((a, b) => b.z - a.z);
  const top = results[0];
  return { ...top, confident: top.z >= MIN_Z && top.ratio >= MIN_RATIO };
}

// Remembers each track's correction; the subtitle route applies it.
export class SubSync {
  constructor() {
    this.store = new JsonStore(path.join(DATA_DIR, 'subsync.json'), { tracks: {} });
    this.cache = new Map(); // `${sigHash}:${audio}` -> activity (last few videos)
    this.inflight = new Map();
  }

  flush() {
    this.store.flush();
  }

  get(file, subId) {
    const s = this.store.data.tracks[`${file.id}:${subId}`];
    return s && s.sig === sigHash(file) ? { offset: s.offset, scale: s.scale } : null;
  }

  clear(file, subId) {
    delete this.store.data.tracks[`${file.id}:${subId}`];
    this.store.save();
  }

  async activity(file, audio) {
    const key = `${sigHash(file)}:${audio}`;
    if (this.cache.has(key)) return this.cache.get(key);
    const act = await speechActivity(file.path, audio);
    this.cache.set(key, act);
    while (this.cache.size > 3) this.cache.delete(this.cache.keys().next().value);
    return act;
  }

  // vtt: the track as served before any correction.
  align(file, subId, vtt, { audio = 0 } = {}) {
    const key = `${file.id}:${subId}`;
    if (this.inflight.has(key)) return this.inflight.get(key);
    const p = (async () => {
      const cues = cueTimes(vtt);
      if (cues.length < 20) return { confident: false, applied: false, reason: 'Too few subtitles to sync' };
      const act = await this.activity(file, audio);
      const r = bestAlignment(act, cues);
      const offset = Math.round(r.offset * 100) / 100;
      const result = { offset, scale: r.scale, confident: r.confident, z: Math.round(r.z * 10) / 10, ratio: Math.round(r.ratio * 100) / 100 };
      if (!r.confident) return { ...result, applied: false, reason: 'No clear match with the dialogue' };
      // Already in sync: keep the file as it is.
      if (Math.abs(offset) < 0.15 && r.scale === 1) {
        this.clear(file, subId);
        return { ...result, applied: false, inSync: true };
      }
      this.store.data.tracks[key] = { offset, scale: r.scale, z: result.z, ratio: result.ratio, sig: sigHash(file), at: Date.now() };
      this.store.save();
      return { ...result, applied: true };
    })().finally(() => this.inflight.delete(key));
    this.inflight.set(key, p);
    return p;
  }
}
