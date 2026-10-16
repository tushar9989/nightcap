// Subtitle text helpers: decoding, SRT -> WebVTT, and removing the adverts and
// credits that uploaders and torrent groups put into subtitle files.

export function decodeText(buf) {
  if (buf[0] === 0xff && buf[1] === 0xfe) return new TextDecoder('utf-16le').decode(buf);
  if (buf[0] === 0xfe && buf[1] === 0xff) return new TextDecoder('utf-16be').decode(buf);
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buf);
  } catch {
    return new TextDecoder('windows-1252').decode(buf);
  }
}

export const srtToVtt = (text) =>
  'WEBVTT\n\n' + text.replace(/^﻿/, '').replace(/\r\n?/g, '\n').replace(/(\d{1,2}:\d{2}:\d{2}),(\d{3})/g, '$1.$2');

// What kind of subtitle text this is, from its content. Names are ffmpeg's
// demuxers, so a downloaded file is never left to ffmpeg's format guessing.
export function sniffFormat(text) {
  const t = text.replace(/^﻿/, '').replace(/\r/g, '').trimStart();
  if (/^WEBVTT/.test(t)) return 'vtt';
  if (/^\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}[ \t]*-->/m.test(t.slice(0, 2000))) return 'srt';
  if (/^\[Script Info\]/i.test(t)) return 'ass';
  if (/^\{\d+\}\{\d*\}/.test(t)) return 'microdvd';
  if (/^<SAMI>/i.test(t)) return 'sami';
  if (/^\[\d+\]\[\d+\]/.test(t)) return 'mpl2';
  return null;
}

function parseTime(s) {
  const m = s.trim().match(/^(?:(\d+):)?(\d{1,2}):(\d{1,2}(?:[.,]\d+)?)/);
  return m ? Number(m[1] || 0) * 3600 + Number(m[2]) * 60 + Number(m[3].replace(',', '.')) : NaN;
}

const fmtTime = (t) => {
  const ms = Math.max(0, Math.round(t * 1000));
  const h = Math.floor(ms / 3600000);
  const m = Math.floor(ms / 60000) % 60;
  const s = Math.floor(ms / 1000) % 60;
  const pad = (n, w = 2) => String(n).padStart(w, '0');
  return `${pad(h)}:${pad(m)}:${pad(s)}.${pad(ms % 1000, 3)}`;
};

// Splits WebVTT into blocks; cue blocks get { start, end, timing, text }.
function blocks(vtt) {
  return vtt.replace(/\r/g, '').split(/\n{2,}/).map((raw) => {
    const lines = raw.split('\n');
    const i = lines.findIndex((l) => l.includes('-->'));
    if (i < 0) return { raw };
    const [a, b] = lines[i].split('-->');
    const [endTs, ...settings] = b.trim().split(/\s+/);
    return { raw, head: lines.slice(0, i), start: parseTime(a), end: parseTime(endTs), settings: settings.join(' '), text: lines.slice(i + 1).join('\n') };
  });
}

// Removed wherever they appear: provider and uploader adverts.
const ALWAYS = [
  /open-?subtitles|osdb\.link/i,
  /advertise your (?:product|brand)|become (?:a )?vip member|rate this subtitle|free browser extension/i,
  /clearway law|leave reviews for lawyers/i,
  /addic7ed|subscene|podnapisi|yifysubtitles|subdl\.com|tvsubtitles|subtitlecat|subs?hub|explosiveskull|sub-?scene/i,
];
// Credits and links: only removed near the start or the end, where uploaders put them.
const AT_EDGES = [
  /\b(?:subtitles?|subs|captions?|captioned|captioning|synced|synchroni[sz]ed|re-?sync(?:ed)?|corrections?|corrected|transcript)\b(?:\s+(?:and|&)\s+\w+)?\s+by\b/i,
  /\bwww\.|https?:\/\/|\b[a-z0-9-]+\.(?:com|org|net|info|tv|io|me|ru|ro|to|cc)\b/i,
];
const EDGE_SECONDS = 240;

export function stripAds(vtt) {
  const all = blocks(vtt);
  const cues = all.filter((b) => b.text != null);
  const lastEnd = Math.max(0, ...cues.map((c) => c.end).filter(Number.isFinite));
  const removed = [];
  const kept = all.filter((b) => {
    if (b.text == null) return true;
    const text = b.text.replace(/<[^>]+>|\{\\[^}]*\}/g, ' ');
    const nearEdge = b.start < EDGE_SECONDS || b.start > lastEnd - EDGE_SECONDS;
    const ad = ALWAYS.some((re) => re.test(text)) || (nearEdge && AT_EDGES.some((re) => re.test(text)));
    if (ad) removed.push(b.text.replace(/\s+/g, ' ').trim());
    return !ad;
  });
  return { vtt: kept.map((b) => b.raw).join('\n\n').replace(/\n*$/, '\n'), removed };
}

// Moves every cue: t -> t * scale + offset (fixes subtitles timed for another
// release, e.g. a constant delay or 25 vs 23.976 fps).
export function retime(vtt, { offset = 0, scale = 1 }) {
  if (!offset && scale === 1) return vtt;
  return blocks(vtt).map((b) => {
    if (b.text == null) return b.raw;
    const s = b.start * scale + offset;
    const e = b.end * scale + offset;
    if (e <= 0) return null;
    return [...b.head, `${fmtTime(Math.max(0, s))} --> ${fmtTime(e)}${b.settings ? ` ${b.settings}` : ''}`, b.text].join('\n');
  }).filter((x) => x != null).join('\n\n').replace(/\n*$/, '\n');
}

// Cue intervals in seconds, for syncing against the audio.
export function cueTimes(vtt) {
  return blocks(vtt).filter((b) => b.text != null && b.text.trim() && b.end > b.start).map((b) => [b.start, b.end]);
}
