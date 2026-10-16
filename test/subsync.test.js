import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RATE, activityFromEnergy, bestAlignment } from '../server/subsync.js';

function rng(seed) {
  let s = seed >>> 0;
  return () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 2 ** 32);
}

// 40 minutes of "dialogue": lines of 1-4 s with pauses, plus music and noise
// that have no subtitles, as a speech-activity curve and the true line times.
function episode(seed) {
  const r = rng(seed);
  const len = 40 * 60 * RATE;
  const act = new Float32Array(len);
  for (let i = 0; i < len; i++) act[i] = r() * 0.25;
  const lines = [];
  let t = 20;
  while (t < 40 * 60 - 10) {
    if (r() < 0.08) {
      // a music cue: loud, but nobody speaks
      const d = 10 + r() * 30;
      for (let i = Math.round(t * RATE); i < Math.min(len, (t + d) * RATE); i++) act[i] = 0.5 + r() * 0.5;
      t += d + 1;
      continue;
    }
    const d = 1 + r() * 3;
    lines.push([t, t + d]);
    for (let i = Math.round(t * RATE); i < Math.min(len, (t + d) * RATE); i++) act[i] = 0.55 + r() * 0.45;
    t += d + 0.4 + r() * 5;
  }
  return { act, lines };
}

const distort = (lines, { offset = 0, scale = 1 }) => lines.map(([a, b]) => [a * scale + offset, b * scale + offset]);

test('finds a constant delay', () => {
  const { act, lines } = episode(1);
  const r = bestAlignment(act, distort(lines, { offset: 3.7 }));
  assert.ok(r.confident, JSON.stringify(r));
  assert.equal(r.scale, 1);
  assert.ok(Math.abs(r.offset + 3.7) <= 0.04, `offset ${r.offset}`);
});

test('finds subtitles timed for 25 fps on a 23.976 fps video', () => {
  const { act, lines } = episode(2);
  // Timed for the faster PAL release: everything is 4% early, plus a cut logo.
  const r = bestAlignment(act, distort(lines, { scale: 23.976 / 25, offset: -12.3 }));
  assert.ok(r.confident, JSON.stringify(r));
  assert.ok(Math.abs(r.scale - 25 / 23.976) < 1e-9, `scale ${r.scale}`);
  // t_video = (t_sub) * 25/23.976 + offset, with t_sub = t * 23.976/25 - 12.3
  assert.ok(Math.abs(r.offset - 12.3 * (25 / 23.976)) <= 0.06, `offset ${r.offset}`);
});

test('subtitles of another episode are not trusted', () => {
  const a = episode(3);
  const b = episode(4);
  const r = bestAlignment(a.act, b.lines);
  assert.equal(r.confident, false, JSON.stringify(r));
});

test('speech activity rises above the local noise floor', () => {
  const db = new Float32Array(60 * RATE).fill(30);
  for (let i = 20 * RATE; i < 22 * RATE; i++) db[i] = 55; // a line of dialogue
  for (let i = 40 * RATE; i < 41 * RATE; i++) db[i] = 33; // a faint rustle
  const act = activityFromEnergy(db);
  assert.equal(act[21 * RATE], 1);
  assert.equal(act[10 * RATE], 0);
  assert.equal(act[40 * RATE + 10], 0);
});
