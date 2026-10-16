import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Isolated data folder and a fake OpenSubtitles server for everything below.
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'marquee-subs-'));
process.env.DATA_DIR = path.join(tmp, 'data');

const { stripAds, retime, srtToVtt, sniffFormat, cueTimes } = await import('../server/subtext.js');
const { movieHash, canonicalQuery, rankResults, OpenSubtitles } = await import('../server/opensubtitles.js');
const { JsonStore } = await import('../server/util.js');

const PILOT_AD = `1
00:00:06,000 --> 00:00:12,074
Someone needs to stop Clearway Law.
Public shouldn't leave reviews for lawyers.

2
00:00:40,100 --> 00:00:42,500
The following story is inspired
by actual documented accounts.

3
00:01:10,000 --> 00:01:12,000
Subtitles by explosiveskull

4
00:20:00,000 --> 00:20:02,000
He wrote it down at www.example.com, she said.

5
00:41:00,000 --> 00:41:03,000
Sync and corrections by n17t01
www.addic7ed.com

6
00:41:30,000 --> 00:41:33,000
Support us and become VIP member
to remove all ads from www.OpenSubtitles.org
`;

test('adverts and uploader credits are removed, dialogue is kept', () => {
  const { vtt, removed } = stripAds(srtToVtt(PILOT_AD));
  assert.match(vtt, /^WEBVTT/);
  assert.match(vtt, /inspired\nby actual documented accounts/);
  assert.match(vtt, /www\.example\.com, she said/, 'links in the middle of an episode are dialogue');
  assert.doesNotMatch(vtt, /Clearway|explosiveskull|addic7ed|OpenSubtitles/i);
  assert.equal(removed.length, 4);
});

test('retime shifts and stretches cues and drops ones before zero', () => {
  const vtt = srtToVtt('1\n00:00:01,000 --> 00:00:02,000\nearly\n\n2\n00:01:00,000 --> 00:01:02,500\nlater\n');
  const out = retime(vtt, { offset: -2.5, scale: 25 / 23.976 });
  const times = cueTimes(out);
  assert.equal(times.length, 1);
  assert.ok(Math.abs(times[0][0] - (60 * 25 / 23.976 - 2.5)) < 0.002, String(times[0][0]));
  assert.match(out, /later/);
});

test('subtitle formats are recognised from their content', () => {
  assert.equal(sniffFormat('﻿1\r\n00:00:01,000 --> 00:00:02,000\r\nhi'), 'srt');
  assert.equal(sniffFormat('WEBVTT\n\n00:01.000 --> 00:02.000\nhi'), 'vtt');
  assert.equal(sniffFormat('[Script Info]\nTitle: x'), 'ass');
  assert.equal(sniffFormat('{1}{25}hello'), 'microdvd');
  assert.equal(sniffFormat('00:00:01,000 --> 00:00:02,000\nno cue numbers'), 'srt');
  assert.equal(sniffFormat('#EXTM3U\nfile:///etc/passwd'), null, 'never handed to ffmpeg to guess');
});

test('moviehash adds the size and the 64-bit words of the first and last 64 KiB', async () => {
  const file = path.join(tmp, 'ones.bin');
  fs.writeFileSync(file, Buffer.alloc(200000, 1));
  const word = 0x0101010101010101n;
  const expected = (200000n + 16384n * word) & 0xffffffffffffffffn;
  assert.equal(await movieHash(file, 200000), expected.toString(16).padStart(16, '0'));

  const zeros = path.join(tmp, 'zeros.bin');
  fs.writeFileSync(zeros, Buffer.alloc(150000));
  assert.equal(await movieHash(zeros, 150000), (150000).toString(16).padStart(16, '0'));
});

test('queries are sorted, lower-case, without empty values or leading zeros', () => {
  assert.equal(
    canonicalQuery({ season_number: 1, languages: 'EN', query: 'The X-Files', moviehash: null, parent_imdb_id: 'tt0106179', episode_number: 2 }),
    'episode_number=2&languages=en&parent_imdb_id=106179&query=the+x-files&season_number=1',
  );
});

test('ranking puts the exact-file match first and partial or machine subtitles last', () => {
  const r = (o) => ({ downloads: 0, hashMatch: false, foreignOnly: false, machineTranslated: false, aiTranslated: false, trusted: false, hearingImpaired: false, fps: null, ...o });
  const out = rankResults([
    r({ id: 1, downloads: 90000 }),
    r({ id: 2, downloads: 10, hashMatch: true }),
    r({ id: 3, downloads: 500000, foreignOnly: true }),
    r({ id: 4, downloads: 5000, machineTranslated: true }),
    r({ id: 5, downloads: 80000, fps: 23.976 }),
  ], { fps: 23.976 });
  assert.deepEqual(out.map((x) => x.id), [2, 5, 1, 4, 3]);
});

// ---- fake API ------------------------------------------------------------------------

const KEY = 'testkey12345';
const futureToken = (exp) => `x.${Buffer.from(JSON.stringify({ exp })).toString('base64url')}.y`;
let server;
let base;
const seen = [];
let downloadsLeft = 2;
const SRT = '1\n00:00:01,000 --> 00:00:03,000\nHello, Mulder.\n\n2\n00:00:04,000 --> 00:00:05,000\nDownloaded from www.OpenSubtitles.org\n';

before(async () => {
  server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    seen.push({ method: req.method, path: url.pathname, query: url.search.slice(1), headers: req.headers });
    const send = (status, data) => {
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(data));
    };
    if (url.pathname === '/file/9001.srt') return res.end(SRT);
    if (req.headers['api-key'] !== KEY) return send(403, { message: 'You cannot consume this service' });
    if (!/^Marquee v\d/.test(req.headers['user-agent'])) return send(403, { message: 'User-Agent header is wrong' });
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      const b = body ? JSON.parse(body) : {};
      switch (`${req.method} ${url.pathname}`) {
        case 'GET /api/v1/infos/formats':
          return send(200, { data: { output_formats: ['srt', 'vtt'] } });
        case 'POST /api/v1/login':
          if (b.username !== 'mulder' || b.password !== 'trustno1') return send(401, { message: 'Error, invalid username/password' });
          return send(200, { token: futureToken(Math.floor(Date.now() / 1000) + 86400), base_url: 'api.opensubtitles.com', user: { allowed_downloads: 20, level: 'Sub leecher', vip: false }, status: 200 });
        case 'GET /api/v1/features':
          return send(200, { data: [
            { id: '2', attributes: { feature_id: '2', title: 'The X-Files', year: '2016', feature_type: 'Tvshow', subtitles_counts: { en: 40 } } },
            { id: '1', attributes: { feature_id: '1', title: 'The X-Files', year: '1993', feature_type: 'Tvshow', subtitles_counts: { en: 5000, fr: 900 } } },
            { id: '3', attributes: { feature_id: '3', title: 'The X-Files: I Want to Believe', year: '2008', feature_type: 'Movie' } },
          ] });
        case 'GET /api/v1/subtitles':
          return send(200, { data: [
            { id: '10', attributes: { subtitle_id: '10', language: 'en', download_count: 9000, release: 'The.X-Files.S01E02.WEB', files: [{ file_id: 8000, file_name: 'a.srt' }] } },
            { id: '11', attributes: { subtitle_id: '11', language: 'en', download_count: 12, release: 'The X-Files S01E02 DVDRip XviD-TSV', moviehash_match: true, files: [{ file_id: 9001, file_name: 'b.srt' }] } },
            { id: '12', attributes: { subtitle_id: '12', language: 'en', download_count: 99999, release: 'two cds', files: [{ file_id: 1 }, { file_id: 2 }] } },
          ] });
        case 'POST /api/v1/download':
          if (req.headers.authorization && req.headers.authorization !== `Bearer ${futureToken(JSON.parse(Buffer.from(req.headers.authorization.split('.')[1], 'base64url')).exp)}`) return send(401, { message: 'invalid token' });
          if (downloadsLeft <= 0) return send(406, { message: 'You have downloaded your allowed 5 subtitles for 24h.', remaining: 0, reset_time_utc: '2030-01-01T00:00:00.000Z' });
          downloadsLeft--;
          return send(200, { link: `${base.replace('/api/v1', '')}/file/${b.file_id}.srt`, file_name: 'b.srt', requests: 1, remaining: downloadsLeft, message: 'ok', reset_time: '23 hours', reset_time_utc: '2030-01-01T00:00:00.000Z' });
        case 'DELETE /api/v1/logout':
          return send(200, { message: 'token successfully destroyed', status: 200 });
        default:
          return send(404, { message: 'not found' });
      }
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}/api/v1`;
});

after(() => {
  server?.close();
  fs.rmSync(tmp, { recursive: true, force: true });
});

const client = () => new OpenSubtitles(new JsonStore(path.join(tmp, `os-${Math.random()}.json`), {}, { mode: 0o600 }), { base, envKey: '' });

test('an API key is checked before it is saved', async () => {
  const os1 = client();
  await assert.rejects(os1.setKey('wrongkey1234'), /did not accept/);
  assert.equal(os1.configured, false);
  await os1.setKey(KEY);
  assert.equal(os1.status().keyHint, '••••2345');
});

test('signing in keeps the token, never the password', async () => {
  const os1 = client();
  await os1.setKey(KEY);
  await assert.rejects(os1.login('mulder', 'nope'), /Wrong username or password/);
  const st = await os1.login('mulder', 'trustno1');
  assert.equal(st.signedIn, true);
  assert.equal(st.allowedDownloads, 20);
  os1.store.flush();
  const saved = fs.readFileSync(os1.store.file, 'utf8');
  assert.doesNotMatch(saved, /trustno1/);
  assert.equal(fs.statSync(os1.store.file).mode & 0o777, 0o600);
  await os1.logout();
  assert.equal(os1.status().signedIn, false);
});

test('finds the show, searches by episode and downloads within the quota', async () => {
  const os1 = client();
  await os1.setKey(KEY);
  const show = await os1.findShow('The X-Files', null);
  assert.equal(show.id, 1, 'the long-running show, not the revival');

  const results = rankResults(await os1.search({ languages: 'en', moviehash: 'abcdef0123456789', parent_feature_id: show.id, season_number: 1, episode_number: 2 }));
  assert.equal(results.length, 2, 'multi-CD subtitles are dropped');
  assert.equal(results[0].id, 9001);
  assert.equal(results[0].hashMatch, true);
  const q = seen.filter((s) => s.path === '/api/v1/subtitles').at(-1).query;
  assert.equal(q, 'episode_number=2&languages=en&moviehash=abcdef0123456789&parent_feature_id=1&season_number=1');

  const got = await os1.download(9001);
  assert.match(got.text, /Hello, Mulder/);
  assert.equal(os1.status().remaining, 1);
  await os1.download(9001);
  await assert.rejects(os1.download(9001), (e) => e.status === 429 && /allowed 5 subtitles.*Sign in/.test(e.message));
  assert.equal(os1.status().remaining, 0);
});

test('requests are spaced to respect the rate limit', async () => {
  const os1 = client();
  await os1.setKey(KEY);
  const t0 = Date.now();
  await Promise.all([1, 2, 3].map(() => os1.request('GET', '/infos/formats')));
  assert.ok(Date.now() - t0 >= 450, `took ${Date.now() - t0} ms`);
});

// Stands in for a network that resets the first `resets` connections to the
// API right after the client's first bytes (as some internet providers do).
async function flakyProxy(resets) {
  const target = new URL(base);
  const sockets = new Set();
  let connections = 0;
  const proxy = net.createServer((socket) => {
    connections++;
    sockets.add(socket);
    if (resets-- > 0) return socket.once('data', () => socket.resetAndDestroy());
    const up = net.connect(Number(target.port), target.hostname);
    sockets.add(up);
    socket.pipe(up).pipe(socket);
    up.on('error', () => socket.destroy());
    socket.on('error', () => up.destroy());
  });
  await new Promise((r) => proxy.listen(0, '127.0.0.1', r));
  return {
    base: `http://127.0.0.1:${proxy.address().port}/api/v1`,
    connections: () => connections,
    close: () => {
      for (const s of sockets) s.destroy();
      proxy.close();
    },
  };
}

test('connections the network resets are tried again', async () => {
  const flaky = await flakyProxy(3);
  try {
    const os1 = new OpenSubtitles(new JsonStore(path.join(tmp, 'os-flaky.json'), {}, { mode: 0o600 }), { base: flaky.base, envKey: '' });
    await os1.setKey(KEY);
    assert.equal(os1.configured, true);
    assert.equal(flaky.connections(), 4);
  } finally {
    flaky.close();
  }
  const blocked = await flakyProxy(Infinity);
  try {
    const os2 = new OpenSubtitles(new JsonStore(path.join(tmp, 'os-blocked.json'), {}, { mode: 0o600 }), { base: blocked.base, envKey: KEY });
    await assert.rejects(os2.request('GET', '/infos/formats'), /keeps cutting the connection/);
    assert.equal(blocked.connections(), 10);
  } finally {
    blocked.close();
  }
});
