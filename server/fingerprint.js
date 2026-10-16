// Audio fingerprinting and segment matching, used to find intros and end
// credits that repeat across the episodes of a season.
//
// The fingerprint is the Haitsma–Kalker ("Philips") robust hash: the audio is
// cut into overlapping frames, each frame's spectrum is split into 33
// logarithmic bands between 300 Hz and 2 kHz, and each of the 32 bits records
// whether the energy difference between two neighbouring bands grew or shrank
// since the previous frame. The same music played in two episodes gives
// nearly identical 32-bit words, even after different encodes, volume changes
// or small timing offsets. Unrelated audio differs in about half of the bits.

export const FP = {
  version: 1,
  sampleRate: 5512,
  frameSize: 2048, // ~371 ms
  hop: 256, // ~46 ms, ~21.5 fingerprints per second
  bands: 33,
  fmin: 300,
  fmax: 2000,
  silenceRms: 0.0015,
};
export const FRAMES_PER_SEC = FP.sampleRate / FP.hop;

export const frameToSec = (i) => (i * FP.hop + FP.frameSize / 2) / FP.sampleRate;
export const secToFrames = (s) => Math.round(s * FRAMES_PER_SEC);

function makeFFT(n) {
  const levels = Math.log2(n);
  const rev = new Uint32Array(n);
  for (let i = 0; i < n; i++) {
    let r = 0;
    for (let b = 0, x = i; b < levels; b++, x >>= 1) r = (r << 1) | (x & 1);
    rev[i] = r;
  }
  const cos = new Float64Array(n / 2);
  const sin = new Float64Array(n / 2);
  for (let i = 0; i < n / 2; i++) {
    cos[i] = Math.cos((2 * Math.PI * i) / n);
    sin[i] = -Math.sin((2 * Math.PI * i) / n);
  }
  return (re, im) => {
    for (let i = 0; i < n; i++) {
      const j = rev[i];
      if (i < j) {
        let t = re[i]; re[i] = re[j]; re[j] = t;
        t = im[i]; im[i] = im[j]; im[j] = t;
      }
    }
    for (let size = 2; size <= n; size <<= 1) {
      const half = size >> 1;
      const step = n / size;
      for (let start = 0; start < n; start += size) {
        for (let k = 0, t = 0; k < half; k++, t += step) {
          const a = start + k;
          const b = a + half;
          const xr = re[b] * cos[t] - im[b] * sin[t];
          const xi = re[b] * sin[t] + im[b] * cos[t];
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
  };
}

const fft = makeFFT(FP.frameSize);
const hann = new Float64Array(FP.frameSize).map(
  (_, i) => 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (FP.frameSize - 1)),
);
const bandEdges = Array.from({ length: FP.bands + 1 }, (_, k) =>
  Math.round(((FP.fmin * (FP.fmax / FP.fmin) ** (k / FP.bands)) * FP.frameSize) / FP.sampleRate),
);

// pcm: Float32Array of mono samples at FP.sampleRate.
// Returns one 32-bit word per frame. 0 marks a silent frame.
export function computeFingerprint(pcm) {
  const N = FP.frameSize;
  const count = pcm.length < N ? 0 : Math.floor((pcm.length - N) / FP.hop) + 1;
  const out = new Uint32Array(count);
  const re = new Float64Array(N);
  const im = new Float64Array(N);
  let energy = new Float64Array(FP.bands);
  let prev = new Float64Array(FP.bands);
  for (let f = 0; f < count; f++) {
    const off = f * FP.hop;
    let sq = 0;
    for (let i = 0; i < N; i++) {
      const s = pcm[off + i];
      sq += s * s;
      re[i] = s * hann[i];
      im[i] = 0;
    }
    fft(re, im);
    for (let m = 0; m < FP.bands; m++) {
      let e = 0;
      for (let b = bandEdges[m]; b < bandEdges[m + 1]; b++) e += re[b] * re[b] + im[b] * im[b];
      energy[m] = e;
    }
    if (Math.sqrt(sq / N) < FP.silenceRms) {
      out[f] = 0;
    } else {
      let v = 0;
      for (let m = 0; m < 32; m++) {
        if (energy[m] - energy[m + 1] - (prev[m] - prev[m + 1]) > 0) v |= 1 << m;
      }
      out[f] = v >>> 0 || 1;
    }
    [prev, energy] = [energy, prev];
  }
  return out;
}

export function popcount(x) {
  x -= (x >>> 1) & 0x55555555;
  x = (x & 0x33333333) + ((x >>> 2) & 0x33333333);
  x = (x + (x >>> 4)) & 0x0f0f0f0f;
  return Math.imul(x, 0x01010101) >>> 24;
}

// Candidate alignments between A and B. Every frame of A looks up the frames
// of B that share its low or high 16 bits, and votes for the offset (j - i)
// that would line them up. Repeated audio piles its votes onto one offset.
function candidateOffsets(A, B, maxCandidates = 6) {
  const BUCKET_LIMIT = 40;
  const heads = [new Int32Array(65536).fill(-1), new Int32Array(65536).fill(-1)];
  const sizes = [new Uint16Array(65536), new Uint16Array(65536)];
  const next = [new Int32Array(B.length), new Int32Array(B.length)];
  const key = (v, h) => (h ? v >>> 16 : v & 0xffff);
  for (let j = 0; j < B.length; j++) {
    if (B[j] === 0) continue;
    for (let h = 0; h < 2; h++) {
      const k = key(B[j], h);
      next[h][j] = heads[h][k];
      heads[h][k] = j;
      if (sizes[h][k] < 65535) sizes[h][k]++;
    }
  }
  const base = A.length;
  const votes = new Float32Array(A.length + B.length + 1);
  for (let i = 0; i < A.length; i++) {
    if (A[i] === 0) continue;
    for (let h = 0; h < 2; h++) {
      const k = key(A[i], h);
      if (sizes[h][k] > BUCKET_LIMIT) continue;
      for (let j = heads[h][k]; j !== -1; j = next[h][j]) votes[j - i + base] += 1;
    }
  }
  // Timing jitter spreads a match over neighbouring offsets; sum a small window.
  const smooth = new Float32Array(votes.length);
  for (let d = 0; d < votes.length; d++) {
    smooth[d] = votes[d] + 0.5 * ((votes[d - 1] || 0) + (votes[d + 1] || 0));
  }
  const picks = [];
  const suppress = Math.round(FRAMES_PER_SEC * 2);
  const taken = new Uint8Array(votes.length);
  for (let c = 0; c < maxCandidates; c++) {
    let best = -1;
    let bestV = 6; // ignore offsets with almost no evidence
    for (let d = 0; d < smooth.length; d++) {
      if (!taken[d] && smooth[d] > bestV) {
        bestV = smooth[d];
        best = d;
      }
    }
    if (best < 0) break;
    picks.push(best - base);
    for (let d = Math.max(0, best - suppress); d <= Math.min(smooth.length - 1, best + suppress); d++) taken[d] = 1;
  }
  return picks;
}

// Longest stretch where A[i] and B[i + d] stay similar, judged on a ~1 s
// moving average of the bit distance. Short dips (up to `gapFrames`) are
// bridged so a line of dialogue over the theme song does not split it.
function bestRunAtOffset(A, B, d, opts) {
  const i0 = Math.max(0, -d);
  const i1 = Math.min(A.length, B.length - d);
  const n = i1 - i0;
  if (n <= 0) return null;
  const dist = new Float32Array(n);
  const voiced = new Uint8Array(n);
  for (let k = 0; k < n; k++) {
    const a = A[i0 + k];
    const b = B[i0 + k + d];
    if (a === 0 && b === 0) dist[k] = 0;
    else if (a === 0 || b === 0) dist[k] = 16;
    else {
      dist[k] = popcount(a ^ b);
      voiced[k] = 1;
    }
  }
  const half = opts.smoothFrames >> 1;
  const prefix = new Float64Array(n + 1);
  for (let k = 0; k < n; k++) prefix[k + 1] = prefix[k] + dist[k];
  const runs = [];
  let start = -1;
  let lastGood = -1;
  for (let k = 0; k < n; k++) {
    const lo = Math.max(0, k - half);
    const hi = Math.min(n, k + half + 1);
    const good = (prefix[hi] - prefix[lo]) / (hi - lo) <= opts.maxBits;
    if (good) {
      if (start < 0) start = k;
      else if (k - lastGood > opts.gapFrames) {
        runs.push([start, lastGood]);
        start = k;
      }
      lastGood = k;
    }
  }
  if (start >= 0) runs.push([start, lastGood]);

  let best = null;
  for (let [s, e] of runs) {
    // Trim the blur the moving average adds at both ends.
    while (s < e && dist[s] > opts.edgeBits) s++;
    while (e > s && dist[e] > opts.edgeBits) e--;
    const len = e - s + 1;
    if (len < opts.minFrames || len > opts.maxFrames) continue;
    let sum = 0;
    let v = 0;
    for (let k = s; k <= e; k++) {
      sum += dist[k];
      v += voiced[k];
    }
    if (v < len * 0.5) continue; // mostly shared silence, not shared audio
    const mean = sum / len;
    if (mean > opts.maxBits) continue; // scattered near-misses chained together
    if (!best || len > best.len) best = { a0: i0 + s, a1: i0 + e, len, mean };
  }
  if (best) {
    best.b0 = best.a0 + d;
    best.b1 = best.a1 + d;
    best.offset = d;
  }
  return best;
}

export const MATCH_DEFAULTS = {
  smoothFrames: 21,
  maxBits: 10,
  edgeBits: 11,
  gapFrames: Math.round(FRAMES_PER_SEC * 2.5),
  minFrames: secToFrames(15),
  maxFrames: secToFrames(150),
};

// Finds the longest shared audio segment between two fingerprints.
// Returns frame ranges in both, or null.
export function findSharedSegment(A, B, options = {}) {
  const opts = { ...MATCH_DEFAULTS, ...options };
  if (A.length < opts.minFrames || B.length < opts.minFrames) return null;
  let best = null;
  for (const d of candidateOffsets(A, B)) {
    const run = bestRunAtOffset(A, B, d, opts);
    if (run && (!best || run.len > best.len)) best = run;
  }
  return best;
}

// Given fingerprints for every episode of a group (usually one season),
// finds each episode's segment by comparing it with its nearest siblings and
// keeping the answer at least two of them agree on. Seasons can alternate
// between intro versions, so when the nearest siblings disagree the search
// widens to more episodes (comparisons are cheap once fingerprints exist).
//   members: [{ id, fp: Uint32Array, offset: seconds where fp starts }]
//   targets: ids to produce results for (others only serve as references)
// Returns Map(id -> { start, end, support, compared })
export function detectRepeatedSegments(members, targets, options = {}) {
  const minSiblings = options.minSiblings ?? 4;
  const maxSiblings = options.maxSiblings ?? 10;
  const byId = new Map(members.map((m, i) => [m.id, { ...m, index: i }]));
  const cache = new Map();
  const pair = (a, b) => {
    const key = a.id < b.id ? `${a.id}|${b.id}` : `${b.id}|${a.id}`;
    if (!cache.has(key)) {
      const [x, y] = a.id < b.id ? [a, b] : [b, a];
      cache.set(key, findSharedSegment(x.fp, y.fp, options));
    }
    const r = cache.get(key);
    if (!r) return null;
    const mine = a.id < b.id ? [r.a0, r.a1] : [r.b0, r.b1];
    return { start: a.offset + frameToSec(mine[0]), end: a.offset + frameToSec(mine[1]) };
  };
  const overlaps = (x, y) =>
    Math.min(x.end, y.end) - Math.max(x.start, y.start) >= 0.5 * Math.min(x.end - x.start, y.end - y.start);
  const span = (arr) => arr.reduce((s, x) => s + x.end - x.start, 0);
  const bestCluster = (found) => {
    let best = [];
    for (const c of found) {
      const cluster = found.filter((o) => overlaps(c, o));
      if (cluster.length > best.length || (cluster.length === best.length && span(cluster) > span(best))) best = cluster;
    }
    return best;
  };
  const median = (xs) => {
    const s = [...xs].sort((a, b) => a - b);
    const m = s.length >> 1;
    return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
  };

  const results = new Map();
  for (const id of targets) {
    const me = byId.get(id);
    if (!me || me.fp.length === 0) continue;
    const siblings = [];
    for (let step = 1; step < members.length; step++) {
      for (const idx of [me.index + step, me.index - step]) {
        if (members[idx]?.fp.length) siblings.push(members[idx]);
      }
    }
    const found = [];
    let compared = 0;
    let cluster = [];
    for (const s of siblings.slice(0, maxSiblings)) {
      const r = pair(me, s);
      compared++;
      if (r) found.push(r);
      if (compared >= minSiblings) {
        cluster = bestCluster(found);
        if (cluster.length >= 2) break;
      }
    }
    cluster = bestCluster(found);
    // With several references, ask for at least two to agree.
    if (!cluster.length || cluster.length < (compared >= 3 ? 2 : 1)) continue;
    results.set(id, {
      start: median(cluster.map((c) => c.start)),
      end: median(cluster.map((c) => c.end)),
      support: cluster.length,
      compared,
    });
  }
  return results;
}

// Serialisation for the on-disk fingerprint index.
const MAGIC = 0x4c4e4650; // "LNFP"
export function encodeFingerprint(fp, offset, length) {
  const buf = Buffer.alloc(32 + fp.length * 4);
  buf.writeUInt32LE(MAGIC, 0);
  buf.writeUInt32LE(FP.version, 4);
  buf.writeUInt32LE(FP.sampleRate, 8);
  buf.writeUInt32LE(FP.hop, 12);
  buf.writeDoubleLE(offset, 16);
  buf.writeFloatLE(length, 24);
  buf.writeUInt32LE(fp.length, 28);
  Buffer.from(fp.buffer, fp.byteOffset, fp.byteLength).copy(buf, 32);
  return buf;
}

export function decodeFingerprint(buf) {
  if (buf.length < 32 || buf.readUInt32LE(0) !== MAGIC) return null;
  if (buf.readUInt32LE(4) !== FP.version || buf.readUInt32LE(8) !== FP.sampleRate || buf.readUInt32LE(12) !== FP.hop) return null;
  const count = buf.readUInt32LE(28);
  if (buf.length !== 32 + count * 4) return null;
  const fp = new Uint32Array(count);
  Buffer.from(fp.buffer).set(buf.subarray(32));
  return { fp, offset: buf.readDoubleLE(16), length: buf.readFloatLE(24) };
}
