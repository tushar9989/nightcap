# Nightcap

A player for the films and shows on your own Mac, with the conveniences of
streaming apps. Point it at folders; it works out shows, seasons and movies,
remembers where you stopped, plays episode after episode, and shows
**Skip Intro** and **Next Episode** using intro/credits detection that runs
entirely on your machine. A sidebar lists what you're watching and your
shows and movies; each title has its own page with seasons and episodes.

## Features

- **A Mac app in macOS 26's design** – a floating glass sidebar, Back/Forward
  and search in the toolbar, glass player controls, Settings in its own
  window (⌘,), light or dark as the system is, its text set in Avenir Next
  like the subtitles. The sidebar lists each title
  with its picture and what's next or how long it is. Every title and
  episode has a picture chosen from its own frames: sharp, well exposed,
  faces before scenery, no black frames, captions, screens or documents.
- **Library from folders** – add any number of folders (local, external drives).
  Season subfolders become seasons; release-style names (`Show.S01E02…`,
  `Show Season 01 Episode 02 - Title`, `1x02`, `[Group] Show - 02`) are parsed;
  films and `Extras` (or `Xtras`) inside a show folder are handled, and a
  spin-off kept there (`Xtras - Baywatch Nights S01`) becomes a show of its
  own; split shows across drives are merged. Rescans every 15 minutes.
- **Resume** – progress is saved every few seconds and on pause; *Watching*
  resumes the episode in progress or the next one.
- **Skip Intro / Next Episode** – detected per episode (see below), with a
  countdown into the next episode at the end credits, optional auto-skip, and
  per-episode manual corrections from the player menu.
- **Plays anything** – the player decodes with ffmpeg's libraries (AVI/Xvid,
  MKV with AC3/DTS, 10-bit H.264…), using the Mac's hardware decoder for HD
  H.264, HEVC and ProRes, and macOS shows the picture and plays the sound. Nothing is
  converted first, so there is no conversion to wait for when you play or seek.
- **Previews** – thumbnails above the seek bar while you scrub, episodes that
  play a slideshow of themselves when you rest the pointer on them (title
  pages, Watching and the player's episode list), and an animated Next
  Episode card.
  In the player, resting on Next shows the next episode playing its preview,
  and resting on Episodes, Speed or Subtitles opens that menu (a click keeps
  it open).
  Made locally from keyframes, about a second and 2 MB per episode.
- **A sharper picture** – standard-definition video (DVD rips, up to 960
  pixels a side) is doubled as it plays by Apple's super resolution, built
  into macOS 26 (VideoToolbox's low-latency scaler, about 1.5 ms a frame on an
  M1 Pro), optionally with light sharpening. **Settings → Playback → Picture**
  or the player's Subtitles button menu: Original, Sharper (the default), or
  Sharper + sharpening.
- **Volume up to 200%** (like VLC), with a limiter so boosted audio doesn't clip harshly.
- **Playback speed 0.25×–3×** with pitch-corrected voices, remembered across
  episodes; the speed button shows when you are not at 1×.
- **Subtitles** – `.srt`/`.vtt`/`.ass` next to the video and embedded text
  tracks, plus **online search on OpenSubtitles.com** (preferring subtitles
  timed for your exact file), optional automatic download for episodes that
  have none, English subtitles **made on this Mac** from the dialogue (Apple's
  speech recognition, see below; a wrong line can be fixed in the player, and
  a name you correct is learned for the show), **sync to the dialogue** done locally,
  manual timing nudges, and adverts stripped from subtitle files.
- **A video player for any file** – Nightcap is in Finder's **Open With**
  menu for video files, takes files dropped on its Dock icon, and has
  **File → Open…** (⌘O). A video from your library plays as part of its
  show; any other plays on its own, with resume, subtitles (next to it, in a
  `Subs` folder beside it, embedded, or online), seek-bar previews, and Next
  through the files opened together. To make it the default for a kind of
  file: Finder → **Get Info** on one → **Open with: Nightcap** → **Change All…**
- Audio-track switching, media keys / Now Playing, full screen.

## Requirements

- macOS 26 or later (its design, and the bundled ffmpeg libraries, need it). The app is built
  for the processor of the Mac that builds it.
- To build the app: the Xcode Command Line Tools (`xcode-select --install`)
  and [ffmpeg](https://ffmpeg.org) from Homebrew (`brew install ffmpeg`).
  The finished app needs neither: ffmpeg and its libraries are copied into it.

## Run it

```sh
scripts/make-mac-app.sh      # builds ~/Applications/Nightcap.app, then open it from Finder/Spotlight/Dock
```

Nightcap is one native app in one process: AppKit and SwiftUI windows, a
player built on ffmpeg's libraries, and the engine (scanning, detection,
previews, subtitles) running inside it. There is no server and no browser.
Quitting it (⌘Q, or closing its last window) saves everything and ends every
ffmpeg run it started; so does `kill`. ⌘N opens another window; a video
opened from Finder plays in the window in front.
macOS will ask once for permission when a folder lives in Downloads, Desktop or
Documents (again after the app is rebuilt).

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
   - **Titles only two episodes have** (a two-part premiere) count when the two
     match each other and nobody else, closely, for 45 s or more, and (intros)
     at the same point in both: a recap replays part one somewhere else.
   - **A long cold open** can push the intro past the first 10 minutes: an
     episode that found none, or one running into that limit, is fingerprinted
     further (40 % of it, up to 20 minutes) and matched again.
   - **Other seasons.** An episode that still matches nothing is compared with
     the nearest episodes of the show's other seasons (a premiere re-edited
     with a later season's titles). Two must agree, and for an intro the shared
     part must be all of what those two share: a pilot whose own opening song
     quotes the theme does not get the quote as its intro.
3. **Video check for credits.** The credits start is refined by looking for
   the first frame of crisp text on black just before the shared end music.
   Movies, and shows without a shared end theme, use this video check alone
   (keyframes of the last 20 minutes; dark film scenes are told apart from
   credits by how many visible pixels are dim).

The fingerprints are saved as an **index** (`fingerprints/*.fp` in the data
folder) and the results in `analysis.json`. Adding an episode only fingerprints that
episode; the matching for its season then re-runs from the index in
milliseconds. Changing the matching (bumping `Analyzer.version`) re-matches the
whole library without decoding anything again (only a longer start for the
episodes that need one).

On *The X-Files* (201 episodes, DVD rips): intros found in 200 (the miss is the
Pilot, which has no title sequence); end credits in 198, checked against the
actual frames. On *Baywatch* (241 episodes, German DVD rips with English
sound): intros in 240 (233 before the three rules above) and end credits in 236
(231), every new one checked against the frames. The miss is the pilot, a TV
film whose opening song only quotes the theme: mark it in the player. Season
2's double-length premiere has its credits found 66 s late, as its longer
credits share only their last 35 s with the other seasons'.

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
- Downloads are kept in `subs-downloaded/` in the data folder; your media
  folders are not touched.

**Sync to the dialogue** (runs locally) works two ways:

- **By the words**, for English subtitles on English (or unlabelled) audio,
  when macOS has its English speech model (syncing never downloads it):
  Apple's speech recognition hears the episode (about 35 s), and runs of
  three words found once in the subtitles and once in the dialogue, in the
  same order, tie the two together, a few thousand per episode. Where their
  offsets jump and stay jumped, the subtitles were timed for another cut of
  the video (a scene longer, a longer pause at an ad break), and each part is
  moved by its own offset; frame-rate mix-ups (23.976 / 24 / 25 fps) are
  found too. Subtitles for another episode share too few words and are left
  alone. Tried on *Baywatch* and *X-Files* episodes cut and slowed by known
  amounts, cues went back to within 0.35 s of their published timing, but
  for 7 of 10,800 (sounds such as *(tires screeching)* and lines at a cut).
- **By the loudness of speech**, otherwise (about 3 s per episode): the audio
  is turned into a speech-activity curve (voice-band energy above the local
  noise floor, 50 values a second) and correlated with the subtitle cues over
  offsets of ±3 minutes and the same frame-rate mix-ups, as one offset. The
  correction is only applied when the fit clearly beats every other offset.

Downloads not made for your exact file are synced automatically (by the
loudness at once, then by the words); any track can be synced from the
Subtitles menu, undone, or nudged with G / H.

Subtitles provided by [OpenSubtitles.com](https://www.opensubtitles.com).

## Subtitles made on this Mac

For a video with no subtitles, or none that fit, **Subtitles button → Make
subtitles on this Mac** writes English subtitles from the dialogue of the
audio track playing. The dialogue never leaves the Mac:

- Apple's speech recognition (SpeechTranscriber, built into macOS 26) hears
  the words and when each is said. If macOS doesn't have its English speech
  model yet, it fetches it first; the menu shows how far it has got.
- Each name's spellings are made one: the recogniser spells an unfamiliar name
  several ways (Mulder, Molder, Maldo…), and the most common spelling is used.
- For an episode of a show, the names to expect are looked up on
  [TVmaze](https://www.tvmaze.com), a free TV database (only the show's name
  and the season and episode numbers are sent): the show's characters, the
  episode's guest characters and the names in its summary. A name heard that
  is nearly one of them is spelt as it is written there (Boudhaas, Buddhaas →
  Budahas). Telling the recogniser the names beforehand changes nothing (it
  ignores them), so they are applied right after it has heard the episode.
- Songs are left out, as subtitles leave out lyrics. While the words are
  heard, Apple's sound classifier (SoundAnalysis) rates every second of the
  audio for singing; where a song is sung (the score averaged over about 5 s),
  the words heard there go, but not a line said over the song. On *Baywatch*'s
  pilot, whose montages run on songs, about 89 lyric lines became 15, and no
  line of dialogue went; on three *X-Files* episodes no dialogue went (a camp
  song in a cold open did).
- The words become cues the way subtitle style guides ask:
  - one sentence to a cue, a long one broken at a comma, a pause or before a
    conjunction (a title's full stop, as in *Mrs. Budahas*, doesn't end one)
  - at most two lines of 42 characters, and 7 seconds
  - fillers (uh, um), and marks heard on their own (", , ,"), left out
  - a quick exchange shares a two-line cue (speakers aren't told apart, so
    there are no dashes)

This takes about 30 s for a 45-minute episode. Compared with the published
subtitles of three X-Files episodes:
- 88–94 % of the words were found.
- 98.5–99.8 % of those words were shown within half a second of the published
  timing.
- The names the dictionary doesn't know were spelt right 90 % of the time in
  *Deep Throat* with TVmaze's names (48 % without them), 77 % in *The Jersey
  Devil* (73 %); *Conduit*'s are mostly places TVmaze doesn't list (44 % either way).

It is offered when the audio track playing is English or unlabelled. Made
subtitles are kept with the downloaded ones and listed as *English · Made on
this Mac*; the Subtitles menu can remove them.

**Fixing a line.** When a made line is wrong, press **E** in the player (or
pause and click the line, or Subtitles button → **Fix a line**): playback
pauses and the line becomes a field. Return saves, ⌥Return starts a second
line, Esc cancels; saving an empty line takes it out. Paused after the line
has gone, **Back to the last line** (in its place) brings it back, as E
does; under a paused line, **Line before** and **Line after** step through
the lines, as ⌥← and ⌥→ do (playing or paused). The fix goes into the
track and into a log of corrections. A name you correct is learned for the
show:
- the same misheard spelling is fixed in the episode's other lines at once
  (*Boudhaas* → *Budahas* fixes every *Boudhaas*);
- subtitles made later for any episode of the show expect it, as they expect
  TVmaze's names.

While the video is open, the Subtitles menu can undo the last fix. **Settings → Subtitles → Names from
Your Fixes** lists the names learned for each show, and can forget any of them.

Character names from [TVmaze](https://www.tvmaze.com) (CC BY-SA).

## Your data

Stored in `~/Library/Application Support/Nightcap`: `config.json` (folders,
settings), `progress.json` (watch progress), `library.json` (last scan),
`analysis.json` + `fingerprints/` (detection index), `opensubtitles.json`
(API key and sign-in token, readable by you only), `trickplay/` (preview
thumbnails), `stills/` (the frames chosen as pictures), `subs-downloaded/` +
`subs-downloaded.json`, `subsync.json` (timing corrections), `names.json`
(names looked up on TVmaze, kept 30 days, and the names learned from your
fixes), `subs-corrections.json` (every fix to made subtitles: the line
before and after), `probe.json`,
`thumbs/`, `subs/` (caches), `nightcap.log`. Quit Nightcap and delete the
folder to start fresh. The player's own choices (volume, speed, subtitle
track and timing nudges, picture) are kept in the app's preferences.

Earlier versions (a Node engine) kept the same files in this repository's
`data/` folder (ignored by git). The first launch of the app copies them over
as APFS clones (instant, no extra space), so progress, detection results,
previews and downloaded subtitles carry over without analysing again; `data/`
itself is left as it was. Set `DATA_DIR` to use another folder.

## Keyboard

Space play/pause · ←/→ 10 s (Shift: 30 s) · ↑/↓ volume (to 200%) ·
`[` / `]` speed −/+ 0.25× (`{` / `}` fine 0.05×, `=` normal) · M mute ·
F full screen · S skip intro · N next episode · C subtitles · G / H subtitles
0.1 s earlier / later (Shift: 1 s) · E fix a line of made subtitles ·
⌥← / ⌥→ the made line before / after · 0–9 jump to 0–90% ·
Esc back. In the library: `/` or ⌘F to search · ⌘[ / ⌘] back / forward ·
⌃⌘S sidebar · ⇧⌘O add a folder · ⌘, Settings.

## Development

```sh
scripts/test-mac.sh             # builds and runs the engine's tests
scripts/test-mac.sh moviehash   # only the tests whose name contains "moviehash"
```

Swift and C only, no packages: the Command Line Tools' `swiftc` and `clang`,
and Homebrew's ffmpeg.

```
mac/
  engine/               the engine (no UI)
    Engine.swift        the library, progress, settings, play info, subtitles: what the windows call
    Scanner.swift       folders -> shows/seasons/episodes/movies; a video opened on its own
    Media.swift         ffprobe, thumbnails, local and embedded subtitles
    Analysis.swift      detection queue + persisted index, decoding, credit frames
    Fingerprint.swift   fingerprint + matching (unit-tested)
    OpenSubtitles.swift OpenSubtitles.com API client, file hash
    OnlineSubs.swift    search / download / auto-fetch for library videos; keeps made subtitles too
    MadeSubs.swift      subtitles made on this Mac: speech recognition, names, cue rules
    ShowNames.swift     names to expect in the dialogue: TVmaze's characters, names learned from fixes
    LineFixes.swift     fixes to made lines: the track, the log, the names they teach
    SubSync.swift       subtitle-to-dialogue sync (words heard, or speech activity + correlation)
    Subtext.swift       subtitle text: SRT -> WebVTT, advert removal, retiming
    Trickplay.swift     preview thumbnail sheets (seek bar, episode previews)
    Stills.swift        pictures for titles and episodes, chosen from their previews (Vision)
    Models.swift, Util.swift, JS.swift, JSDate.swift, Language.swift, FFTTables.swift, fdlibm.c
                        data types, stores, running ffmpeg; exact JavaScript behaviour where
                        the data files and results depend on it (they were made by the Node engine)
  player/
    ncdecoder.c         ffmpeg's libraries: open, seek, decode video (VideoToolbox for HD) and audio
    MediaPlayer.swift   macOS sample-buffer renderers on one clock; speed, volume boost, audio tracks
    Upscaler.swift      the picture setting: Apple's 2x super resolution (+ sharpening on Metal)
  ui/
    main.swift          the app: windows, menus, files from Finder, quitting, carrying over the earlier data
    AppModel.swift      the engine's state for the windows; what plays next, Watching
    Window.swift        a window: routes, search, keys, folder and file pickers, toasts
    Sidebar.swift, LibraryPages.swift, SettingsWindow.swift
    PlayerModel.swift, PlayerView.swift, PlayerPanels.swift, NowPlaying.swift, Prefs.swift
    Art.swift, Theme.swift
  tests/                the engine's tests (a small runner; Command Line Tools have no XCTest)
  App.h                 the C parts, for Swift
  icon.svg              the app icon
  render-icon.swift     renders icon.svg for the .icns
scripts/
  make-mac-app.sh       builds and bundles Nightcap.app
  test-mac.sh           runs mac/tests
```
