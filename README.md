# Nightcap

A player for the films and shows on your own Mac, with the conveniences of
streaming apps. Point it at folders; it works out shows, seasons and movies,
remembers where you stopped, plays episode after episode, and shows
**Skip Intro** and **Next Episode** using intro/credits detection that runs
entirely on your machine. A sidebar lists what you're watching and your
shows and movies; each title has its own page with seasons and episodes.

## Features

- **Library from folders** – add any number of folders (local, external drives).
  Season subfolders become seasons; release-style names (`Show.S01E02…`,
  `Show Season 01 Episode 02 - Title`, `1x02`, `[Group] Show - 02`) are parsed;
  films and `Extras` inside a show folder are handled; split shows across
  drives are merged. Rescans every 15 minutes.
- **Resume** – progress is saved every few seconds and on pause; *Watching*
  resumes the episode in progress or the next one.
- **Skip Intro / Next Episode** – detected per episode (see below), with a
  countdown into the next episode at the end credits, optional auto-skip, and
  per-episode manual corrections from the player menu.
- **Plays anything** – browser-friendly files play directly; others (AVI/Xvid,
  MKV with AC3/DTS, 10-bit H.264…) are repackaged or converted on the fly by
  ffmpeg, using the Mac's hardware encoder. The player keeps about a minute and
  a half of converted video ahead (and one behind), so skipping ±10 s is
  instant; only longer jumps start a new conversion (well under a second).
- **Previews** – thumbnails above the seek bar while you scrub, episodes that
  play a slideshow of themselves when you rest the pointer on them (title
  pages, Watching and the player's episode list), and an animated Next
  Episode card.
  In the player, resting on Next shows the next episode playing its preview,
  and resting on Episodes or Subtitles opens that menu (a click keeps it open).
  Made locally from keyframes, about a second and 2 MB per episode.
- **Volume up to 200%** (like VLC), with a limiter so boosted audio doesn't clip harshly.
- **Playback speed 0.25×–3×** with pitch-corrected voices, remembered across
  episodes; the speed button shows when you are not at 1×.
- **Subtitles** – `.srt`/`.vtt`/`.ass` next to the video and embedded text
  tracks, plus **online search on OpenSubtitles.com** (preferring subtitles
  timed for your exact file), optional automatic download for episodes that
  have none, **sync to the dialogue** done locally (see below), manual timing
  nudges, and adverts stripped from subtitle files.
- Audio-track switching, media keys / Now Playing, full screen.

## Requirements

- macOS (tested on macOS 26) – Linux/Windows should work but are untested
- [Node.js](https://nodejs.org) 22 or newer
- [ffmpeg](https://ffmpeg.org): `brew install ffmpeg` (needed for most formats and for detection)
- Google Chrome (or Edge/Brave) for the app window – Safari cannot play the
  on-the-fly converted streams

## Run it

```sh
npm start                    # starts the engine and opens the app window
scripts/make-mac-app.sh      # builds ~/Applications/Nightcap.app (Dock/Spotlight launcher)
```

Nightcap runs as long as its window: closing the window, or quitting or
force-quitting its browser, stops the engine a few seconds later along with
everything it was running (conversions, detection, previews). Opening the app
again starts it fresh; if an engine from older code is still running, the app
replaces it. Several windows share one engine, which stops after the last
one closes. If the engine stops under an open window (say it was force-quit),
the window says so and pauses; opening Nightcap again reconnects it in place.
`node server/index.js --no-open` runs the engine on its own, with
no window, until you stop it (for development).
macOS will ask once for permission when a folder lives in Downloads, Desktop or
Documents.

## Intro & credits detection

Everything runs locally; nothing is uploaded.

1. **Audio fingerprints.** The first ~10 minutes and last ~7 minutes of every
   episode are decoded to mono 5.5 kHz audio and turned into a robust
   fingerprint (Haitsma–Kalker: 32 bits per 46 ms frame, from band-energy
   changes between 300 Hz and 2 kHz).
2. **Matching within a season.** Each episode is compared with its neighbours:
   an inverted index on the fingerprint words votes for the time offset at which
   audio lines up, then the longest stretch that stays similar (smoothed bit
   distance ≤ 10/32) is the shared segment. At least two neighbours must agree;
   if the nearest ones disagree (seasons that alternate between intro versions)
   the search widens. Shared music near the start is the intro (15 s–2.5 min);
   near the end, the end credits.
3. **Video check for credits.** The credits start is refined by looking for
   the first frame of crisp text on black just before the shared end music.
   Movies, and shows without a shared end theme, use this video check alone
   (keyframes of the last 20 minutes; dark film scenes are told apart from
   credits by how many visible pixels are dim).

The fingerprints are saved as an **index** (`data/fingerprints/*.fp`) and the
results in `data/analysis.json`. Adding an episode only fingerprints that
episode; the matching for its season then re-runs from the index in
milliseconds. Changing the matching (bumping `ANALYSIS_VERSION`) re-matches the
whole library without decoding anything again.

On *The X-Files* (201 episodes, DVD rips): intros found in 199 (the two misses
are the Pilot, which has no title sequence, and one episode with a different
opening); end credits in 199, checked against the actual frames.

Limits: credits that roll over moving footage (some films) are not detected –
those still count as watched at 95%. Corrections made in the player
(**Subtitles button → Intro & credits**) are kept over detection.

## Subtitles from OpenSubtitles.com

Search and downloads use your own free API key: create an account on
[opensubtitles.com](https://www.opensubtitles.com), add a consumer under
[API consumers](https://www.opensubtitles.com/en/consumers) and paste its key
in **Settings → Subtitles** (or set `OPENSUBTITLES_API_KEY`). Without signing
in, a free key allows 5 downloads a day; signing in uses your account's daily
allowance. The password is only sent to OpenSubtitles, never stored.

- Each episode is searched by show, season and episode, together with the
  file's OpenSubtitles hash, so subtitles made for that exact release come
  first (marked *Made for this file*).
- With **Download missing subtitles automatically** on, watching with
  subtitles on fetches the best match for episodes that have none.
- Downloads are kept in `data/subs-downloaded/`; your media folders are not
  touched.

**Sync to the dialogue** (runs locally, about 3 s per episode): the audio is
turned into a speech-activity curve (voice-band energy above the local noise
floor, 50 values a second) and correlated with the subtitle cues over offsets
of ±3 minutes and the usual frame-rate mix-ups (23.976 / 24 / 25 fps). The
correction is only applied when the fit clearly beats every other offset, so
subtitles for a different cut or episode are left alone. Downloads not made
for your exact file are synced automatically; any track can be synced from
the Subtitles menu, undone, or nudged with G / H.

Subtitles provided by [OpenSubtitles.com](https://www.opensubtitles.com).

## Your data

Stored in `data/` (ignored by git): `config.json` (folders, settings),
`progress.json` (watch progress), `library.json` (last scan),
`analysis.json` + `fingerprints/` (detection index), `opensubtitles.json`
(API key and sign-in token, readable by you only), `trickplay/` (preview
thumbnails), `subs-downloaded/` +
`subs-downloaded.json`, `subsync.json` (timing corrections), `probe.json`,
`thumbs/`, `subs/` (caches). Delete `data/` to start fresh.

The server only listens on `127.0.0.1` and rejects requests from other sites.
`HOST=0.0.0.0 npm start` exposes it on your network (no login – only do this
on a network you trust). `PORT` and `DATA_DIR` can be set the same way.

## Keyboard

Space play/pause · ←/→ 10 s (Shift: 30 s) · ↑/↓ volume (to 200%) ·
`[` / `]` speed −/+ 0.25× (`{` / `}` fine 0.05×, `=` normal) · M mute ·
F full screen · S skip intro · N next episode · C subtitles · G / H subtitles
0.1 s earlier / later (Shift: 1 s) · 0–9 jump to 0–90% ·
Esc back. In the library: `/` to search.

## Development

```sh
npm test
```

```
server/
  index.js            HTTP API, static files, progress
  scanner.js          folders -> shows/seasons/episodes/movies
  media.js            ffprobe, direct streaming (ranges), remux/transcode, thumbnails, subtitles
  analysis.js         detection queue + persisted index
  analysis-worker.js  worker thread: decoding, fingerprinting, credit frames
  fingerprint.js      fingerprint + matching (pure, unit-tested)
  opensubtitles.js    OpenSubtitles.com API client, file hash
  online-subs.js      search / download / auto-fetch for library videos
  subsync.js          subtitle-to-dialogue sync (speech activity + correlation)
  subtext.js          subtitle text: SRT -> WebVTT, advert removal, retiming
  trickplay.js        preview thumbnail sheets (seek bar, episode previews)
  window.js           opens the app window
public/               the app (no build step, no dependencies)
  stream.js           Media Source playback of converted streams (instant short seeks)
scripts/make-mac-app.sh
```
