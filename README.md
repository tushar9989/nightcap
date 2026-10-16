# Marquee

A Netflix-style app for the movies and TV shows on your own disks. Point it at
folders; it works out shows, seasons and movies, remembers where you stopped,
plays episode after episode, and shows **Skip Intro** and **Next Episode**
using intro/credits detection that runs entirely on your machine.

## Features

- **Library from folders** – add any number of folders (local, external drives).
  Season subfolders become seasons; release-style names (`Show.S01E02…`,
  `Show Season 01 Episode 02 - Title`, `1x02`, `[Group] Show - 02`) are parsed;
  films and `Extras` inside a show folder are handled; split shows across
  drives are merged. Rescans every 15 minutes.
- **Resume like Netflix** – progress is saved every few seconds and on pause;
  *Continue Watching* resumes the episode in progress or the next one.
- **Skip Intro / Next Episode** – detected per episode (see below), with a
  countdown into the next episode at the end credits, optional auto-skip, and
  per-episode manual corrections from the player menu.
- **Plays anything** – browser-friendly files play directly; others (AVI/Xvid,
  MKV with AC3/DTS, 10-bit H.264…) are repackaged or converted on the fly by
  ffmpeg, using the Mac's hardware encoder. Seeking works either way.
- **Volume up to 200%** (like VLC), with a limiter so boosted audio doesn't clip harshly.
- **Playback speed 0.25×–3×** with pitch-corrected voices, remembered across
  episodes; the speed button shows when you are not at 1×.
- Subtitles (`.srt`/`.vtt`/`.ass` next to the video, or embedded text tracks),
  audio-track switching, media keys / Now Playing, full screen.

## Requirements

- macOS (tested on macOS 26) – Linux/Windows should work but are untested
- [Node.js](https://nodejs.org) 22 or newer
- [ffmpeg](https://ffmpeg.org): `brew install ffmpeg` (needed for most formats and for detection)
- Google Chrome (or Edge/Brave) for the app window – Safari cannot play the
  on-the-fly converted streams

## Run it

```sh
npm start                    # starts the engine and opens the app window
scripts/make-mac-app.sh      # builds ~/Applications/Marquee.app (Dock/Spotlight launcher)
```

`Marquee.app` starts the engine in the background if it is not running and
opens the window. The engine keeps running after you close the window (so new
episodes keep being analysed); stop it from **Settings → Stop Marquee**.
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

## Your data

Stored in `data/` (ignored by git): `config.json` (folders, settings),
`progress.json` (watch progress), `library.json` (last scan),
`analysis.json` + `fingerprints/` (detection index), `probe.json`,
`thumbs/`, `subs/` (caches). Delete `data/` to start fresh.

The server only listens on `127.0.0.1` and rejects requests from other sites.
`HOST=0.0.0.0 npm start` exposes it on your network (no login – only do this
on a network you trust). `PORT` and `DATA_DIR` can be set the same way.

## Keyboard

Space play/pause · ←/→ 10 s (Shift: 30 s) · ↑/↓ volume (to 200%) ·
`[` / `]` speed −/+ 0.25× (`{` / `}` fine 0.05×, `=` normal) · M mute ·
F full screen · S skip intro · N next episode · C subtitles · 0–9 jump to 0–90% ·
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
  window.js           opens the app window
public/               the app (no build step, no dependencies)
scripts/make-mac-app.sh
```
