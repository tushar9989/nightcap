import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'nightcap-tp-'));
process.env.DATA_DIR = path.join(tmp, 'data');
const { FFMPEG } = await import('../server/util.js');
const { Trickplay, jpegSize } = await import('../server/trickplay.js');

test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

test('reads the size of a JPEG', { skip: !FFMPEG && 'needs ffmpeg' }, () => {
  const out = path.join(tmp, 'one.jpg');
  spawnSync(FFMPEG, ['-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=red:s=96x54', '-frames:v', '1', '-y', out]);
  assert.deepEqual(jpegSize(fs.readFileSync(out)), { width: 96, height: 54 });
});

test('makes thumbnail sheets for a video, in the frame shape of the video', { skip: !FFMPEG && 'needs ffmpeg' }, async () => {
  // 70 s, 4:3, a keyframe every second.
  const video = path.join(tmp, 'clip.mp4');
  spawnSync(FFMPEG, ['-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=10:duration=70', '-g', '10', '-pix_fmt', 'yuv420p', '-y', video]);
  const st = fs.statSync(video);
  const file = { id: 'clip0000test', titleId: 't', name: 'Clip', path: video, size: st.size, mtime: st.mtimeMs, subs: [] };
  const lib = { titles: [{ id: 't', kind: 'movie', addedAt: 1, seasons: [{ episodes: [file.id] }] }], files: { [file.id]: file }, folderStatus: {} };
  const tp = new Trickplay({ getLibrary: () => lib, probe: async () => ({ duration: 70, video: { width: 320, height: 240 } }), isEnabled: () => true });
  const m = await tp.generate(file);
  assert.equal(m.interval, 2, 'short videos get a frame every 2 s');
  assert.equal(m.width, 240);
  assert.equal(m.height, 180);
  assert.equal(m.sheets, 1);
  assert.equal(m.count, 36);
  assert.ok(fs.existsSync(tp.sheetPath(file, 0)));
  assert.equal(tp.sheetPath(file, 1), null);
  assert.equal(tp.state(file), 'ready');
  assert.equal(tp.status().done, 1);
});
