// Runs in a worker thread so fingerprinting never blocks playback.
// Receives one job at a time (a season, or a movie) and replies with the
// intro and credits markers it found for each file.

import { parentPort, workerData } from 'node:worker_threads';
import { spawn } from 'node:child_process';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  FP, MATCH_DEFAULTS, computeFingerprint, decodeFingerprint, detectRepeatedSegments,
  encodeFingerprint, secToFrames,
} from './fingerprint.js';

const { fpDir, ffmpeg } = workerData;

const INTRO = { ...MATCH_DEFAULTS, minFrames: secToFrames(15), maxFrames: secToFrames(150) };
const CREDITS = { ...MATCH_DEFAULTS, minFrames: secToFrames(15), maxFrames: secToFrames(600) };

function exec(args, maxErr = 8e6) {
  return new Promise((resolve, reject) => {
    const child = spawn(ffmpeg, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    try {
      os.setPriority(child.pid, 10); // background work: stay out of playback's way
    } catch {}
    const out = [];
    let err = '';
    child.stdout.on('data', (d) => out.push(d));
    child.stderr.on('data', (d) => {
      if (err.length < maxErr) err += d;
    });
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, stdout: Buffer.concat(out), stderr: err }));
  });
}

const headWindow = (dur) => {
  const len = dur ? Math.min(dur, Math.max(120, Math.min(dur * 0.25, 600))) : 600;
  return { start: 0, len };
};
const tailWindow = (dur, movie = false) => {
  if (!dur) return null;
  const len = movie ? Math.min(dur, Math.max(300, Math.min(dur * 0.2, 1200))) : Math.min(dur, Math.max(120, Math.min(dur * 0.25, 420)));
  return { start: Math.max(0, dur - len), len };
};

async function decodeAudio(file, start, len) {
  const args = ['-nostdin', '-hide_banner', '-loglevel', 'error'];
  if (start > 0) args.push('-ss', start.toFixed(3));
  args.push('-t', len.toFixed(3), '-i', file.path, '-map', '0:a:0', '-vn', '-sn', '-dn', '-ac', '1', '-ar', String(FP.sampleRate), '-f', 'f32le', 'pipe:1');
  const r = await exec(args, 20000);
  if (r.code !== 0) {
    if (/matches no streams|does not contain any stream/i.test(r.stderr)) return new Float32Array(0);
    throw new Error(`audio decode failed: ${r.stderr.trim().split('\n').pop()}`);
  }
  const n = r.stdout.length >> 2;
  const pcm = new Float32Array(n);
  new Uint8Array(pcm.buffer).set(r.stdout.subarray(0, n * 4));
  return pcm;
}

// Loads the fingerprint for a part of a file from the index on disk, or
// computes and stores it.
async function fingerprint(file, part) {
  const win = part === 'head' ? headWindow(file.duration) : tailWindow(file.duration);
  if (!win) return { fp: new Uint32Array(0), offset: 0 };
  const cache = path.join(fpDir, `${file.id}-${file.sig}-${part}.fp`);
  try {
    const hit = decodeFingerprint(await fsp.readFile(cache));
    if (hit && Math.abs(hit.offset - win.start) < 0.01) return hit;
  } catch {}
  const pcm = await decodeAudio(file, win.start, win.len);
  const fp = computeFingerprint(pcm);
  await fsp.writeFile(cache, encodeFingerprint(fp, win.start, win.len));
  return { fp, offset: win.start };
}

// Small grayscale frames plus their timestamps (from ffmpeg's showinfo).
//   keyOnly: decode keyframes only (fast scan of a long window)
//   fps: sample at a fixed rate (precise look at a short window)
async function grayFrames(file, start, len, { keyOnly = false, fps = 0 } = {}) {
  const W = 160;
  const H = 90;
  const args = ['-nostdin', '-hide_banner', '-loglevel', 'info'];
  if (keyOnly) args.push('-skip_frame', 'nokey');
  args.push('-ss', start.toFixed(3), '-t', len.toFixed(3), '-i', file.path, '-map', '0:v:0', '-an', '-sn', '-dn',
    '-vf', `${fps ? `fps=${fps},` : ''}scale=${W}:${H}:flags=area,format=gray,showinfo`, '-fps_mode', 'passthrough', '-f', 'rawvideo', 'pipe:1');
  const r = await exec(args);
  if (r.code !== 0) return null;
  const times = [...r.stderr.matchAll(/\bn:\s*\d+\s+pts:\s*-?\d+\s+pts_time:\s*(-?[\d.]+)/g)].map((m) => start + Number(m[1]));
  const n = Math.min(times.length, Math.floor(r.stdout.length / (W * H)));
  return { W, H, n, times, frames: r.stdout };
}

// Marks frames that look like end credits: black background with a little
// crisp bright text. Letterbox/pillarbox bars (black in nearly every frame) are
// left out so a dark widescreen scene is not mistaken for credits.
function creditFrames({ W, H, n, times, frames }) {
  const px = W * H;
  const rowDark = new Uint32Array(H);
  const colDark = new Uint32Array(W);
  for (let f = 0; f < n; f++) {
    const o = f * px;
    for (let y = 0; y < H; y++) {
      let s = 0;
      for (let x = 0; x < W; x++) s += frames[o + y * W + x];
      if (s / W < 24) rowDark[y]++;
    }
    for (let x = 0; x < W; x++) {
      let s = 0;
      for (let y = 0; y < H; y++) s += frames[o + y * W + x];
      if (s / H < 24) colDark[x]++;
    }
  }
  const bar = (count) => n >= 20 && count >= n * 0.97;
  let top = 0, bottom = H, left = 0, right = W;
  while (top < H && bar(rowDark[top])) top++;
  while (bottom > top && bar(rowDark[bottom - 1])) bottom--;
  while (left < W && bar(colDark[left])) left++;
  while (right > left && bar(colDark[right - 1])) right--;
  if ((bottom - top) * (right - left) < px * 0.2) [top, bottom, left, right] = [0, H, 0, W];
  const area = (bottom - top) * (right - left);

  const flags = [];
  for (let f = 0; f < n; f++) {
    const o = f * px;
    let black = 0;
    let dim = 0;
    let bright = 0;
    for (let y = top; y < bottom; y++) {
      for (let x = left; x < right; x++) {
        const v = frames[o + y * W + x];
        if (v <= 24) black++;
        else if (v <= 48) dim++;
        else if (v >= 110) bright++;
      }
    }
    // Credits are crisp text on pure black: few of the visible pixels are dim.
    // A dark scene keeps shadow detail, so most of its visible pixels are dim.
    const visible = area - black;
    const crisp = visible < area * 0.01 || dim / visible <= 0.4;
    flags.push({ t: times[f], credits: black / area >= 0.8 && bright / area <= 0.18 && crisp, text: bright / area >= 0.002 });
  }
  return flags;
}

// End credits on screen: a sustained stretch of credit-like frames near the
// end. Only keyframes are decoded, so even the last 20 minutes of a film take
// a few seconds.
async function videoCredits(file, movie) {
  const win = tailWindow(file.duration, movie);
  if (!win) return null;
  const g = await grayFrames(file, win.start, win.len, { keyOnly: true });
  if (!g || g.n < 5) return null;
  const flags = creditFrames(g);
  const minRun = movie ? 30 : 20;
  const GAP = 12;
  let best = null;
  let run = null;
  const close = () => {
    if (!run) return;
    const span = run.end - run.start;
    const total = flags.filter((x) => x.t >= run.start && x.t <= run.end).length;
    if (span >= minRun && run.text >= run.flagged * 0.25 && run.flagged >= total * 0.6 && (!best || span > best.end - best.start)) best = run;
    run = null;
  };
  for (const fr of flags) {
    if (!fr.credits) continue;
    if (run && fr.t - run.end > GAP) close();
    if (!run) run = { start: fr.t, end: fr.t, flagged: 0, text: 0 };
    run.end = fr.t;
    run.flagged++;
    if (fr.text) run.text++;
  }
  close();
  if (!best) return null;
  return { start: (await refineStart(file, best.start)) ?? best.start };
}

// Credits often appear on screen a few seconds before the end theme (or the
// first keyframe) we anchored on. Look at the 20 s before `t` at 5 fps and
// walk back through the unbroken run of credit-like frames.
async function refineStart(file, t) {
  const from = Math.max(0, t - 20);
  const g = await grayFrames(file, from, t - from + 1.5, { fps: 5 });
  if (!g || g.n < 3) return null;
  const flags = creditFrames(g);
  let i = flags.findIndex((f) => f.t >= t - 0.2);
  if (i < 0) i = flags.length - 1;
  if (!flags[i].credits) return null;
  while (i > 0 && flags[i - 1].credits) i--;
  return flags[i].t < t - 0.5 ? flags[i].t : null;
}

async function showJob(job, progress) {
  const all = [...job.files, ...job.refs];
  const heads = [];
  const tails = [];
  const errors = {};
  let step = 0;
  const total = all.length + job.files.length;
  for (const f of all) {
    try {
      heads.push({ id: f.id, ...(await fingerprint(f, 'head')) });
      tails.push({ id: f.id, ...(await fingerprint(f, 'tail')) });
    } catch (e) {
      errors[f.id] = e.message;
      heads.push({ id: f.id, fp: new Uint32Array(0), offset: 0 });
      tails.push({ id: f.id, fp: new Uint32Array(0), offset: 0 });
    }
    progress(++step, total);
  }
  const targets = job.files.map((f) => f.id);
  const intros = detectRepeatedSegments(heads, targets, INTRO);
  const credits = detectRepeatedSegments(tails, targets, CREDITS);

  const results = {};
  for (const f of job.files) {
    const res = { intro: null, credits: null, method: {} };
    const i = intros.get(f.id);
    if (i) {
      res.intro = { start: i.start < 3 ? 0 : round(i.start), end: round(i.end) };
      res.method.intro = `audio (${i.support}/${i.compared} episodes agree)`;
    }
    const c = credits.get(f.id);
    if (c && (!f.duration || c.start > f.duration * 0.5)) {
      let start = c.start;
      try {
        start = (await refineStart(f, c.start)) ?? c.start;
      } catch {}
      res.credits = { start: round(start) };
      res.method.credits = `audio (${c.support}/${c.compared} episodes agree)`;
    } else {
      try {
        const v = await videoCredits(f, false);
        if (v) {
          res.credits = { start: round(v.start) };
          res.method.credits = 'video (text on black)';
        }
      } catch {}
    }
    if (errors[f.id]) res.error = errors[f.id];
    results[f.id] = res;
    progress(++step, total);
  }
  return results;
}

async function movieJob(job, progress) {
  const results = {};
  const last = job.files.at(-1);
  for (const f of job.files) {
    const res = { intro: null, credits: null, method: {} };
    if (f === last) {
      try {
        const v = await videoCredits(f, true);
        if (v) {
          res.credits = { start: round(v.start) };
          res.method.credits = 'video (text on black)';
        }
      } catch (e) {
        res.error = e.message;
      }
    }
    results[f.id] = res;
  }
  progress(1, 1);
  return results;
}

const round = (x) => Math.round(x * 10) / 10;

let chain = Promise.resolve();
parentPort.on('message', (msg) => {
  if (msg.type !== 'job') return;
  chain = chain.then(async () => {
    const progress = (done, total) => parentPort.postMessage({ type: 'progress', id: msg.id, done, total });
    try {
      const run = msg.job.kind === 'movie' ? movieJob : showJob;
      parentPort.postMessage({ type: 'done', id: msg.id, results: await run(msg.job, progress) });
    } catch (e) {
      parentPort.postMessage({ type: 'error', id: msg.id, error: e.message });
    }
  });
});
