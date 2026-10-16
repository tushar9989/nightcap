import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';
import { FFMPEG, FFPROBE, DATA_DIR, JsonStore, Limiter, ensureDir, fileSig, sigHash, run } from './util.js';
import { decodeText, srtToVtt, sniffFormat } from './subtext.js';

const PROBE_VERSION = 2;
const probeStore = new JsonStore(path.join(DATA_DIR, 'probe.json'), { files: {} });
const inflight = new Map();
const probeLimit = new Limiter(3);

export function flushProbes() {
  probeStore.flush();
}

export function cachedProbe(file) {
  const c = probeStore.data.files[file.id];
  return c && c.sig === fileSig(file) && c.v === PROBE_VERSION ? c.info : null;
}

// Codec, duration and track info for a file (cached until the file changes).
export async function probe(file) {
  const hit = cachedProbe(file);
  if (hit || !FFPROBE) return hit;
  if (inflight.has(file.id)) return inflight.get(file.id);
  const p = probeLimit
    .run(async () => {
      const r = await run(FFPROBE, ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', file.path], { timeout: 60000 });
      if (r.code !== 0) return null;
      const j = JSON.parse(r.stdout.toString());
      const streams = j.streams || [];
      const v = streams.find((s) => s.codec_type === 'video' && !s.disposition?.attached_pic);
      const tag = (s, k) => s.tags?.[k] || s.tags?.[k.toUpperCase()];
      const info = {
        duration: Number(j.format?.duration) || Number(v?.duration) || 0,
        format: j.format?.format_name || '',
        video: v ? { codec: v.codec_name, profile: v.profile || '', pixFmt: v.pix_fmt || '', width: v.width, height: v.height } : null,
        audio: streams
          .filter((s) => s.codec_type === 'audio')
          .map((s, i) => ({ index: i, codec: s.codec_name, channels: s.channels, lang: tag(s, 'language') || '', title: tag(s, 'title') || '', default: !!s.disposition?.default })),
        subs: streams
          .filter((s) => s.codec_type === 'subtitle')
          .map((s, i) => ({ index: i, codec: s.codec_name, lang: tag(s, 'language') || '', title: tag(s, 'title') || '', forced: !!s.disposition?.forced })),
      };
      probeStore.data.files[file.id] = { sig: fileSig(file), v: PROBE_VERSION, info };
      probeStore.save();
      return info;
    })
    .catch(() => null)
    .finally(() => inflight.delete(file.id));
  inflight.set(file.id, p);
  return p;
}

const MIME = {
  '.mp4': 'video/mp4', '.m4v': 'video/mp4', '.mov': 'video/mp4', '.webm': 'video/webm', '.mkv': 'video/webm',
  '.ogv': 'video/ogg', '.avi': 'video/x-msvideo', '.ts': 'video/mp2t', '.m2ts': 'video/mp2t',
};

// Direct file playback with HTTP range support so the browser can seek.
export function serveFile(req, res, filePath, size, type) {
  type ||= MIME[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
  const range = req.headers.range;
  const headers = { 'Content-Type': type, 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store' };
  let start = 0;
  let end = size - 1;
  if (range) {
    const m = range.match(/bytes=(\d*)-(\d*)/);
    if (m) {
      if (m[1] === '' && m[2] !== '') {
        start = Math.max(0, size - Number(m[2]));
      } else {
        start = Number(m[1] || 0);
        if (m[2]) end = Math.min(Number(m[2]), size - 1);
      }
    }
    if (start >= size || start > end) {
      res.writeHead(416, { 'Content-Range': `bytes */${size}` });
      return res.end();
    }
    res.writeHead(206, { ...headers, 'Content-Range': `bytes ${start}-${end}/${size}`, 'Content-Length': end - start + 1 });
  } else {
    res.writeHead(200, { ...headers, 'Content-Length': size });
  }
  if (req.method === 'HEAD') return res.end();
  const stream = fs.createReadStream(filePath, { start, end, highWaterMark: 1 << 20 });
  stream.on('error', () => res.destroy());
  res.on('close', () => stream.destroy());
  stream.pipe(res);
}

let vtOk;
async function hardwareEncoderWorks() {
  if (vtOk !== undefined) return vtOk;
  if (os.platform() !== 'darwin') return (vtOk = false);
  const r = await run(FFMPEG, ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=128x128:d=0.2', '-c:v', 'h264_videotoolbox', '-f', 'null', '-'], { timeout: 15000 }).catch(() => ({ code: 1 }));
  return (vtOk = r.code === 0);
}

// Streams the file through ffmpeg as fragmented MP4.
//   mode "remux": keep the video as is, convert audio to AAC (cheap)
//   mode "transcode": re-encode video to H.264 too
// Seeking is done by the player requesting a new stream at `start`.
export async function streamTranscoded(req, res, file, { start = 0, mode = 'remux', audio = 0 }) {
  if (!FFMPEG) {
    res.writeHead(501);
    return res.end('ffmpeg is not installed');
  }
  const info = await probe(file);
  const a = info?.audio?.[audio];
  const args = ['-nostdin', '-hide_banner', '-loglevel', 'error'];
  if (start > 0) args.push('-ss', String(start));
  args.push('-i', file.path, '-map', '0:v:0', '-map', `0:a:${audio}?`, '-sn', '-dn', '-map_chapters', '-1');
  if (mode === 'transcode') {
    if (await hardwareEncoderWorks()) args.push('-c:v', 'h264_videotoolbox', '-b:v', '8M', '-maxrate', '12M', '-bufsize', '16M', '-pix_fmt', 'yuv420p');
    else args.push('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '21', '-pix_fmt', 'yuv420p');
    args.push('-vf', "scale='min(1920,iw)':-2", '-g', '96');
  } else {
    args.push('-c:v', 'copy');
    if (info?.video?.codec === 'hevc') args.push('-tag:v', 'hvc1');
  }
  if (a && a.codec === 'aac' && (a.channels || 2) <= 6) args.push('-c:a', 'copy');
  else args.push('-c:a', 'aac', '-b:a', '192k', '-ac', '2');
  args.push('-movflags', 'frag_keyframe+empty_moov+default_base_moof', '-f', 'mp4', 'pipe:1');

  const child = spawn(FFMPEG, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  let err = '';
  child.stderr.on('data', (d) => (err = (err + d).slice(-4000)));
  res.writeHead(200, { 'Content-Type': 'video/mp4', 'Cache-Control': 'no-store' });
  child.stdout.pipe(res);
  const stop = () => child.kill('SIGKILL');
  res.on('close', stop);
  child.on('close', (code) => {
    if (code && code !== 255 && !res.writableEnded) console.warn(`[stream] ffmpeg exited ${code}: ${err.trim().split('\n').pop()}`);
    res.end();
  });
}

// ---- Thumbnails -------------------------------------------------------------

const THUMB_DIR = ensureDir(path.join(DATA_DIR, 'thumbs'));
const thumbLimit = new Limiter(2);
const thumbInflight = new Map();

export async function frameThumb(file, { at = 0.3, width = 480 } = {}) {
  const out = path.join(THUMB_DIR, `${file.id}-${sigHash(file)}-${width}-${Math.round(at * 100)}.jpg`);
  try {
    await fsp.access(out);
    return out;
  } catch {}
  if (!FFMPEG) return null;
  if (thumbInflight.has(out)) return thumbInflight.get(out);
  const p = thumbLimit
    .run(async () => {
      const info = await probe(file);
      if (info && !info.video) return null;
      const t = info?.duration ? info.duration * at : 60;
      const tmp = `${out}.tmp.jpg`;
      const r = await run(FFMPEG, ['-nostdin', '-hide_banner', '-loglevel', 'error', '-ss', t.toFixed(2), '-i', file.path, '-map', '0:v:0', '-vf', `thumbnail=8,scale=${width}:-2`, '-frames:v', '1', '-q:v', '3', '-y', tmp], { timeout: 60000 });
      if (r.code !== 0) {
        await fsp.rm(tmp, { force: true });
        return null;
      }
      await fsp.rename(tmp, out);
      return out;
    })
    .catch(() => null)
    .finally(() => thumbInflight.delete(out));
  thumbInflight.set(out, p);
  return p;
}

// ---- Subtitles -----------------------------------------------------------------

const SUB_DIR = ensureDir(path.join(DATA_DIR, 'subs'));
const TEXT_SUB_CODECS = new Set(['subrip', 'srt', 'ass', 'ssa', 'webvtt', 'mov_text', 'text']);

const LANG_NAMES = { eng: 'English', en: 'English', spa: 'Spanish', fre: 'French', fra: 'French', ger: 'German', deu: 'German', ita: 'Italian', por: 'Portuguese', jpn: 'Japanese', kor: 'Korean', chi: 'Chinese', zho: 'Chinese', hin: 'Hindi', rus: 'Russian', ara: 'Arabic', dut: 'Dutch', nld: 'Dutch', swe: 'Swedish', nor: 'Norwegian', dan: 'Danish', fin: 'Finnish', pol: 'Polish', tur: 'Turkish' };

export async function listSubtitles(file) {
  const out = file.subs.map((s, i) => ({ id: `x${i}`, label: s.label, source: 'file' }));
  const info = await probe(file);
  for (const s of info?.subs || []) {
    if (!TEXT_SUB_CODECS.has(s.codec)) continue;
    const lang = LANG_NAMES[s.lang] || s.lang || '';
    const label = [lang, s.title && s.title !== lang ? s.title : '', s.forced ? 'Forced' : ''].filter(Boolean).join(' · ') || `Track ${s.index + 1}`;
    out.push({ id: `e${s.index}`, label, source: 'embedded' });
  }
  return out;
}

// Returns the subtitle as WebVTT text.
export async function subtitleVtt(file, subId) {
  const kind = subId[0];
  const index = Number(subId.slice(1));
  if (kind === 'x') {
    const sub = file.subs[index];
    if (!sub) return null;
    const ext = path.extname(sub.path).toLowerCase();
    if (ext === '.srt' || ext === '.vtt') {
      const text = decodeText(await fsp.readFile(sub.path));
      return ext === '.vtt' ? text.replace(/^﻿/, '') : srtToVtt(text);
    }
  }
  if (!FFMPEG) return null;
  const cache = path.join(SUB_DIR, `${file.id}-${sigHash(file)}-${subId}.vtt`);
  try {
    return await fsp.readFile(cache, 'utf8');
  } catch {}
  const args = kind === 'x'
    ? ['-nostdin', '-loglevel', 'error', '-i', file.subs[index].path, '-f', 'webvtt', 'pipe:1']
    : ['-nostdin', '-loglevel', 'error', '-i', file.path, '-map', `0:s:${index}`, '-f', 'webvtt', 'pipe:1'];
  const r = await run(FFMPEG, args, { timeout: 180000 });
  if (r.code !== 0) return null;
  const text = r.stdout.toString('utf8');
  await fsp.writeFile(cache, text);
  return text;
}

// Subtitle text (SRT, WebVTT, ASS/SSA, MicroDVD, SAMI, MPL2) as WebVTT.
export async function textToVtt(text, ext = '') {
  const fmt = sniffFormat(text);
  if (fmt === 'vtt') return text.replace(/^﻿/, '');
  if (fmt === 'srt' || (!fmt && ext === '.srt')) return srtToVtt(text);
  if (!fmt || !FFMPEG) return null;
  const tmp = path.join(SUB_DIR, `convert-${process.pid}-${Date.now()}.txt`);
  await fsp.writeFile(tmp, text);
  try {
    const r = await run(FFMPEG, ['-nostdin', '-loglevel', 'error', '-f', fmt, '-i', tmp, '-f', 'webvtt', 'pipe:1'], { timeout: 60000 });
    return r.code === 0 ? r.stdout.toString('utf8') : null;
  } finally {
    await fsp.rm(tmp, { force: true });
  }
}
