import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  FP, computeFingerprint, findSharedSegment, detectRepeatedSegments, frameToSec,
  encodeFingerprint, decodeFingerprint, MATCH_DEFAULTS, secToFrames,
} from '../server/fingerprint.js';

const SR = FP.sampleRate;

function rng(seed) {
  let s = seed >>> 0;
  return () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 2 ** 32);
}

// Music-like audio: random notes with harmonics plus noise hits.
function music(seconds, seed) {
  const r = rng(seed);
  const out = new Float32Array(Math.round(seconds * SR));
  let i = 0;
  while (i < out.length) {
    const len = Math.round((0.15 + r() * 0.4) * SR);
    const f = 110 * 2 ** (Math.floor(r() * 36) / 12);
    const g = 0.15 + r() * 0.2;
    const hit = r() < 0.3;
    for (let k = 0; k < len && i + k < out.length; k++) {
      const t = k / SR;
      const env = Math.min(1, k / 200) * Math.exp(-t * 3);
      let v = 0;
      for (let h = 1; h <= 4; h++) v += Math.sin(2 * Math.PI * f * h * t) / h;
      if (hit && k < 800) v += (r() * 2 - 1) * (1 - k / 800);
      out[i + k] = g * env * v;
    }
    i += len;
  }
  return out;
}

function episode({ coldOpen, intro, body, seed, gain = 1 }) {
  const r = rng(seed * 7 + 3);
  const parts = [music(coldOpen, seed * 11 + 1), intro, music(body, seed * 13 + 5)];
  const total = parts.reduce((s, p) => s + p.length, 0);
  const out = new Float32Array(total);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  for (let k = 0; k < out.length; k++) out[k] = out[k] * gain + (r() * 2 - 1) * 0.004;
  return out;
}

const theme = music(60, 999);

test('fingerprint round-trips through the on-disk format', () => {
  const fp = computeFingerprint(music(5, 1));
  const back = decodeFingerprint(encodeFingerprint(fp, 12.5, 600));
  assert.equal(back.offset, 12.5);
  assert.deepEqual([...back.fp], [...fp]);
});

test('finds a shared theme placed at different, misaligned offsets', () => {
  const a = episode({ coldOpen: 31.37, intro: theme, body: 90, seed: 1 });
  const b = episode({ coldOpen: 77.912, intro: theme, body: 90, seed: 2, gain: 0.6 });
  const seg = findSharedSegment(computeFingerprint(a), computeFingerprint(b));
  assert.ok(seg, 'expected a match');
  const aStart = frameToSec(seg.a0);
  const aEnd = frameToSec(seg.a1);
  const bStart = frameToSec(seg.b0);
  assert.ok(Math.abs(aStart - 31.37) < 1, `a start ${aStart}`);
  assert.ok(Math.abs(aEnd - 91.37) < 1, `a end ${aEnd}`);
  assert.ok(Math.abs(bStart - 77.912) < 1, `b start ${bStart}`);
});

test('unrelated audio does not match', () => {
  const a = computeFingerprint(music(180, 5));
  const b = computeFingerprint(music(180, 6));
  assert.equal(findSharedSegment(a, b), null);
});

test('season detection agrees across siblings and skips an episode without the theme', () => {
  const opens = [10.2, 45.7, 0, 120.33, 64.1];
  const members = opens.map((open, i) => ({
    id: `e${i}`,
    offset: 0,
    fp: computeFingerprint(
      i === 3
        ? music(300, 4242) // this one has no intro
        : episode({ coldOpen: open, intro: theme, body: 60, seed: 20 + i }),
    ),
  }));
  const res = detectRepeatedSegments(members, members.map((m) => m.id), MATCH_DEFAULTS);
  for (const [i, open] of opens.entries()) {
    const r = res.get(`e${i}`);
    if (i === 3) {
      assert.equal(r, undefined, 'episode without intro should have none');
      continue;
    }
    assert.ok(r, `e${i} missing`);
    assert.ok(Math.abs(r.start - open) < 1, `e${i} start ${r.start} vs ${open}`);
    assert.ok(Math.abs(r.end - (open + 60)) < 1, `e${i} end ${r.end} vs ${open + 60}`);
  }
});

test('segments shorter than the minimum are ignored', () => {
  const jingle = music(8, 77);
  const a = episode({ coldOpen: 20, intro: jingle, body: 100, seed: 8 });
  const b = episode({ coldOpen: 50, intro: jingle, body: 100, seed: 9 });
  assert.equal(findSharedSegment(computeFingerprint(a), computeFingerprint(b), { minFrames: secToFrames(15) }), null);
});

test('fingerprinting ten minutes of audio is fast', () => {
  const pcm = music(600, 3);
  const t = performance.now();
  computeFingerprint(pcm);
  const ms = performance.now() - t;
  assert.ok(ms < 5000, `took ${ms} ms`);
  console.log(`  10 min fingerprint: ${ms.toFixed(0)} ms`);
});

test('a season alternating between two intro versions still finds both', () => {
  const themeB = music(32, 4321);
  // A A B B B A A: the first two episodes' nearest neighbours mostly use B.
  const plan = ['A', 'A', 'B', 'B', 'B', 'A', 'A'];
  const members = plan.map((v, i) => ({
    id: `e${i}`,
    offset: 0,
    fp: computeFingerprint(episode({ coldOpen: 20 + i * 7.3, intro: v === 'A' ? theme : themeB, body: 40, seed: 60 + i })),
  }));
  const res = detectRepeatedSegments(members, members.map((m) => m.id), MATCH_DEFAULTS);
  plan.forEach((v, i) => {
    const r = res.get(`e${i}`);
    assert.ok(r, `e${i} (${v}) missing`);
    assert.ok(Math.abs(r.end - r.start - (v === 'A' ? 60 : 32)) < 1.5, `e${i} length ${r.end - r.start}`);
  });
});
