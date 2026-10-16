// Plays the server's converted streams (fragmented MP4) through Media Source
// Extensions rather than a plain <video src>. A plain src can't seek inside
// such a stream, so every jump used to restart ffmpeg. Here the player keeps
// the video it fetched around the play position, jumps inside it at once, and
// starts a new stream only for jumps outside it. Streams are requested with
// the video's own timestamps (abs=1), so pieces from different streams line up.

const AHEAD = 90; // seconds fetched ahead of the play position
const BEHIND = 60; // seconds kept behind it
const CATCH_UP = 10; // a jump this far past the fetched video waits for the running stream
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export const mseAvailable = () => typeof MediaSource === 'function' && typeof ReadableStream === 'function';

// ---- codecs from the stream's init segment (ftyp + moov) ----------------------------

const u32 = (b, i) => ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0;
const fourcc = (b, i) => String.fromCharCode(b[i], b[i + 1], b[i + 2], b[i + 3]);
const hex2 = (n) => n.toString(16).padStart(2, '0');

function* boxes(b, start, end) {
  for (let i = start; i + 8 <= end;) {
    let size = u32(b, i);
    let head = 8;
    if (size === 1) {
      size = u32(b, i + 8) * 2 ** 32 + u32(b, i + 12);
      head = 16;
    } else if (size === 0) size = end - i;
    if (size < head || i + size > end) return;
    yield { type: fourcc(b, i + 4), start: i + head, end: i + size };
    i += size;
  }
}

const child = (b, box, type, skip = 0) => {
  for (const c of boxes(b, box.start + skip, box.end)) if (c.type === type) return c;
  return null;
};

function reverseBits32(n) {
  let r = 0;
  for (let i = 0; i < 32; i++) r = (r * 2) + ((n >>> i) & 1);
  return r;
}

function sampleCodec(b, entry) {
  const t = entry.type;
  if (t === 'avc1' || t === 'avc3') {
    const c = child(b, entry, 'avcC', 78);
    return c && `${t}.${hex2(b[c.start + 1])}${hex2(b[c.start + 2])}${hex2(b[c.start + 3])}`;
  }
  if (t === 'hvc1' || t === 'hev1') {
    const c = child(b, entry, 'hvcC', 78);
    if (!c) return null;
    const p = b[c.start + 1];
    const flags = [];
    for (let i = 6; i < 12; i++) flags.push(b[c.start + i]);
    while (flags.length && !flags.at(-1)) flags.pop();
    return [`${t}`, `${['', 'A', 'B', 'C'][p >> 6]}${p & 31}`, reverseBits32(u32(b, c.start + 2)).toString(16),
      `${p & 32 ? 'H' : 'L'}${b[c.start + 12]}`, ...flags.map((f) => f.toString(16).toUpperCase())].join('.');
  }
  if (t === 'mp4a') return 'mp4a.40.2'; // the server sends AAC
  return null;
}

// The MIME type for addSourceBuffer: undefined while the moov box is still
// incomplete, null for codecs this player doesn't know.
function mimeOf(b) {
  for (const box of boxes(b, 0, b.length)) {
    if (box.type !== 'moov') continue;
    const codecs = [];
    for (const trak of boxes(b, box.start, box.end)) {
      if (trak.type !== 'trak') continue;
      const stsd = ['mdia', 'minf', 'stbl', 'stsd'].reduce((x, type) => x && child(b, x, type), trak);
      const entry = stsd && boxes(b, stsd.start + 8, stsd.end).next().value;
      if (!entry) continue;
      const codec = sampleCodec(b, entry);
      if (!codec) return null;
      codecs.push(codec);
    }
    return codecs.length ? `video/mp4; codecs="${codecs.join(', ')}"` : null;
  }
  return undefined;
}

function concat(a, b) {
  const out = new Uint8Array(a.length + b.length);
  out.set(a);
  out.set(b, a.length);
  return out;
}

// ---- the stream ---------------------------------------------------------------------

export class MseStream {
  // urlAt(seconds) -> stream URL; onFatal(error) is called when this way of
  // playing can't work (the player then falls back to a plain src).
  constructor(video, { urlAt, duration, onFatal }) {
    this.video = video;
    this.urlAt = urlAt;
    this.onFatal = onFatal;
    this.ms = new MediaSource();
    this.sb = null;
    this.feed = null;
    this.closed = false;
    this.queue = Promise.resolve(); // SourceBuffer operations run one at a time
    this.opened = new Promise((resolve) => this.ms.addEventListener('sourceopen', resolve, { once: true }));
    this.objectUrl = URL.createObjectURL(this.ms);
    video.src = this.objectUrl;
    this.opened.then(() => {
      if (duration > 0 && !this.closed) this.ms.duration = duration;
    });
  }

  destroy() {
    this.closed = true;
    this.feed?.ctrl.abort();
    this.feed = null;
    URL.revokeObjectURL(this.objectUrl);
  }

  // The fetched range around t, allowing for tiny gaps between fragments.
  rangeAt(t, slack = 0.3) {
    const b = this.video.buffered;
    for (let i = 0; i < b.length; i++) if (b.start(i) - slack <= t && t <= b.end(i) + slack) return [b.start(i), b.end(i)];
    return null;
  }

  // Whether a jump to t plays without a new stream: it is fetched already,
  // or the running stream is about to get there.
  canReach(t) {
    const r = this.rangeAt(t, 0);
    if (r && r[1] - t >= 1) return true;
    const f = this.feed;
    return !!f && !f.done && t >= f.from && t <= f.head + CATCH_UP;
  }

  seek(t) {
    const restart = !this.canReach(t);
    this.video.currentTime = t;
    if (restart) this.start(t);
  }

  // Fetches a stream from `at` on, replacing the running one.
  async start(at) {
    this.feed?.ctrl.abort();
    const feed = { ctrl: new AbortController(), from: at, head: at, done: false };
    this.feed = feed;
    const live = () => feed === this.feed && !this.closed;
    try {
      await this.opened;
      if (!live()) return;
      // Forget a piece of the previous stream that was cut off mid-way.
      if (this.sb) await this.op(() => this.ms.readyState === 'open' && this.sb.abort());
      const res = await fetch(this.urlAt(at), { signal: feed.ctrl.signal });
      if (!res.ok) throw new Error(`the stream failed (${res.status})`);
      const reader = res.body.getReader();
      let start = new Uint8Array(0); // the stream's first bytes, until its codecs are known
      let evicted = Date.now();
      for (;;) {
        const { value, done } = await reader.read();
        if (!live()) return;
        if (done) break;
        let bytes = value;
        if (!this.sb) {
          start = concat(start, value);
          const type = mimeOf(start);
          if (type === undefined) continue;
          if (!type || !MediaSource.isTypeSupported(type)) throw new Error(`unsupported stream (${type})`);
          this.sb = this.ms.addSourceBuffer(type);
          bytes = start;
        }
        await this.append(bytes, live);
        if (!live()) return;
        const r = this.rangeAt(feed.head);
        if (r) feed.head = Math.max(feed.head, r[1]);
        // Far enough ahead: stop reading (ffmpeg then waits) until playback catches up.
        while (live() && feed.head - this.video.currentTime > AHEAD) await sleep(500);
        if (Date.now() - evicted > 5000) {
          evicted = Date.now();
          await this.evict();
        }
      }
      if (!live()) return;
      feed.done = true;
      await this.op(() => this.ms.readyState === 'open' && this.ms.endOfStream());
    } catch (e) {
      if (!live() || e.name === 'AbortError') return;
      this.onFatal(e);
    }
  }

  // Runs one SourceBuffer operation once the previous ones have finished.
  op(fn) {
    const run = this.queue.then(() => new Promise((resolve, reject) => {
      if (this.closed) return resolve();
      const sb = this.sb;
      try {
        fn();
      } catch (e) {
        return reject(e);
      }
      if (!sb?.updating) return resolve();
      const finish = (ok) => () => {
        sb.removeEventListener('updateend', onEnd);
        sb.removeEventListener('error', onError);
        if (ok) resolve();
        else reject(new Error('the video data could not be added'));
      };
      const onEnd = finish(true);
      const onError = finish(false);
      sb.addEventListener('updateend', onEnd);
      sb.addEventListener('error', onError);
    }));
    this.queue = run.catch(() => {});
    return run;
  }

  async append(bytes, live) {
    for (let tries = 0; ; tries++) {
      try {
        return await this.op(() => this.sb.appendBuffer(bytes));
      } catch (e) {
        // The browser's buffer is full (very high bitrates): keep less behind, then retry.
        if (e.name !== 'QuotaExceededError' || tries >= 30) throw e;
        await this.evict(10);
        await sleep(1000);
        if (!live()) return;
      }
    }
  }

  // Drops video more than `behind` seconds behind the play position, and old
  // pieces far ahead of it.
  async evict(behind = BEHIND) {
    if (!this.sb) return;
    const t = this.video.currentTime;
    const b = this.sb.buffered;
    const cuts = [];
    for (let i = 0; i < b.length; i++) {
      const s = b.start(i);
      const e = b.end(i);
      if (s < t - behind) cuts.push([s, Math.min(e, t - behind)]);
      else if (s > t + 2 * AHEAD) cuts.push([s, e]);
    }
    for (const [s, e] of cuts) if (e - s > 0.5) await this.op(() => this.sb.remove(s, e));
  }
}
