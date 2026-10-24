import AppKit
import IOKit.pwr_mgt
import Observation

// The player: one MediaPlayer for as long as the player is open (the next
// episode opens in it), resume, Skip Intro, the Next Episode card, subtitles
// (with online search, timing nudges and sync to the dialogue), audio tracks,
// volume up to 200%, speed, and the keys, as the earlier web player did them
// (public/player.js, in the git history); and the picture (Upscaler.swift).

enum PlayerPanel: Equatable {
  case settings, online, speed, episodes
}

/// What the middle of the picture shows: the loading ring, or a play/pause sign fading out.
enum CenterSign: Equatable {
  case none
  case spinner
  case flash(id: Int, icon: String)
}

struct PlayerFailure: Equatable {
  let title: String
  let message: String
}

/// A search on OpenSubtitles.com, for the video playing.
struct OnlineSearch {
  var language: String
  var query = ""
  var results: [SubtitleResult]?
  var error: String?
  var loading = false
  /// The result being downloaded.
  var busy: Double?
  var busyText = "Downloading…"
  var status: OpenSubtitles.Status?
}

/// The buttons that open something while the pointer rests on them.
enum PopupButton: Hashable {
  case next, episodes, speed, settings
}

/// What changes many times a second: kept apart, so only the views showing it redraw.
@MainActor
@Observable
final class PlayerClock {
  var time: Double = 0
  /// The subtitles on screen.
  var subs: [CueRun] = []
  /// How much of the Next card's countdown has run (0...1).
  var countdown: Double = 0
}

@MainActor
@Observable
final class PlayerModel {
  static let speedStops: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
  static let saveEvery: Double = 5
  static let hideAfter: Double = 3
  static let noMarkers = Markers(intro: nil, credits: nil, manual: false, method: [:], state: "none")

  @ObservationIgnored let app: AppModel
  @ObservationIgnored weak var win: WindowModel?
  @ObservationIgnored let mp = MediaPlayer()
  @ObservationIgnored let surface: PlayerSurface
  @ObservationIgnored let clock = PlayerClock()

  private(set) var fid: String?
  private(set) var info: PlayInfo?
  private(set) var mediaInfo: MediaPlayer.Info?
  private(set) var markers = PlayerModel.noMarkers
  private(set) var nextId: String?
  private(set) var center: CenterSign = .spinner
  private(set) var failure: PlayerFailure?
  private(set) var playing = false
  private(set) var volume: Double
  private(set) var muted: Bool
  private(set) var speed: Double
  /// How the picture is shown (Prefs.picture), and what that does to this video.
  private(set) var picture: PictureMode
  private(set) var pictureStatus: Upscaler.Status = .off
  /// The audio track: the n-th audio stream (the order of probe.audio).
  private(set) var audio = 0
  private(set) var subId: String?
  private(set) var subDelay = 0.0
  /// The track being synced to the dialogue.
  private(set) var syncing: String?
  /// How far making subtitles from the dialogue has got, while it runs.
  private(set) var making: String?
  var online: OnlineSearch?
  /// The online search field (searched when submitted).
  var onlineQuery = ""
  private(set) var panel: PlayerPanel?
  /// The season the Episodes panel shows (else the one playing).
  var panelSeason: Int?
  private(set) var peekVisible = false
  private(set) var skipVisible = false
  /// The episode the Next card shows, while it shows.
  private(set) var nextCard: String?
  private(set) var trick: TrickplayManifest?
  /// The decoded sheets of `trick`, by number, kept while the video plays.
  private(set) var trickSheets: [Int: CGImage] = [:]
  private(set) var idle = false
  /// The seek bar is being dragged, to `dragTime`.
  var dragging = false
  var dragTime: Double = 0

  /// Opened by resting the pointer on its button: closes when the pointer leaves, unless used.
  @ObservationIgnored private var panelByHover = false
  @ObservationIgnored var hoveringControls = false
  @ObservationIgnored private var cues: [Cue] = []
  @ObservationIgnored private var openSeq = 0
  @ObservationIgnored private var started = false
  @ObservationIgnored private var landed = false
  @ObservationIgnored private var lastTick: Double?
  @ObservationIgnored private var lastSaved = Date.distantPast
  @ObservationIgnored private var introSkipped = false
  @ObservationIgnored private var nextDismissed = false
  @ObservationIgnored private var nextShownFor: String?
  @ObservationIgnored private var endedHandled = false
  @ObservationIgnored private var flashSeq = 0
  /// The player put the window in full screen (Esc takes it out again).
  @ObservationIgnored private var enteredFullScreen = false
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var idleTask: Task<Void, Never>?
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var spinnerTask: Task<Void, Never>?
  @ObservationIgnored private var countTask: Task<Void, Never>?
  @ObservationIgnored private var previewTask: Task<Void, Never>?
  @ObservationIgnored private var hoverTimers: [PopupButton: Task<Void, Never>] = [:]
  @ObservationIgnored private var sleepAssertion: IOPMAssertionID = 0
  @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

  init(app: AppModel, win: WindowModel) {
    self.app = app
    self.win = win
    volume = Prefs.volume
    muted = Prefs.muted
    speed = Prefs.speed
    picture = Prefs.picture
    surface = PlayerSurface(player: mp)
    mp.rate = Float(speed)
    mp.picture = picture
    applyVolume()
    mp.onOpen = { [weak self] info in self?.opened(info) }
    mp.onSeeked = { [weak self] _ in self?.seeked() }
    mp.onEnded = { [weak self] in self?.ended() }
    mp.onError = { [weak self] message in self?.failed(message) }
    mp.onAspect = { [weak self] _ in self?.surface.needsLayout = true }
    mp.onPicture = { [weak self] status in self?.pictureStatus = status }
    surface.onClick = { [weak self] count in self?.surfaceClicked(count) }
    let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
    // The picture setting can change in Settings or in another window's player.
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.followPicture() }
    }
    // The keys go to the player, not to a search field left focused under it.
    win.window?.makeFirstResponder(nil)
  }

  var duration: Double {
    if let d = info?.probe?.duration, d != 0, !d.isNaN { return d }
    return mediaInfo?.duration ?? 0
  }

  /// Where playback is (where a seek is going, while it lands).
  var time: Double { started ? mp.currentTime : 0 }

  var title: Title? { fid.flatMap { app.location($0)?.title } }

  /// The window's name while this plays.
  var windowTitle: String? {
    guard let fid, let f = app.file(fid) else { return nil }
    guard let t = app.location(fid)?.title else { return f.name }
    let code = app.epCode(fid)
    if t.isShow { return [t.name, code, f.name].filter { !$0.isEmpty }.joined(separator: " · ") }
    return code.isEmpty ? t.name : "\(t.name) · \(f.name)"
  }

  // ---- Opening and closing --------------------------------------------------------------

  func open(_ fid: String, start: Double?) {
    if self.fid == fid && start == nil { return }
    if self.fid != nil { saveProgress() }
    self.fid = fid
    openSeq += 1
    let seq = openSeq
    info = nil
    resetEpisodeState()
    nextId = app.nextAfter(fid)
    showControls()
    setLoading(true)
    win?.updateTitle()
    Task {
      let info: PlayInfo
      do {
        info = try await app.engine.playInfo(fid)
      } catch {
        guard seq == openSeq else { return }
        showError("Cannot open this video", errorText(error))
        return
      }
      guard seq == openSeq else { return }  // switched again meanwhile
      self.info = info
      markers = info.markers
      nextId = app.nextAfter(fid)
      audio = pickAudio(info.probe)
      var at = start ?? 0
      if start == nil, let p = app.progress(fid) ?? info.progress {
        let dur = duration
        at = !p.watched && p.position > 5 && (dur == 0 || p.position < dur - 10) ? p.position - 2 : 0
      }
      startMedia(max(0, at))
      loadPreviews(fid)
      autoSubtitles()
      updateNowPlaying()
    }
  }

  /// Leaves the player (back to the page under it).
  func exit() {
    win?.closePlayer()
  }

  /// Called by the window when the player goes away.
  func close() {
    if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
    defaultsObserver = nil
    guard fid != nil else { return }
    saveProgress()
    mp.close()
    fid = nil
    openSeq += 1
    timer?.invalidate()
    timer = nil
    for task in [idleTask, saveTask, spinnerTask, countTask, previewTask] { task?.cancel() }
    trick = nil
    trickSheets = [:]
    for task in hoverTimers.values { task.cancel() }
    hoverTimers = [:]
    closePanel()
    keepAwake(false)
    NowPlaying.release(self)
    if idle { win?.setWindowButtons(visible: true) }
    idle = false
    if enteredFullScreen, win?.isFullScreen == true { win?.toggleFullScreen() }
    enteredFullScreen = false
  }

  private func resetEpisodeState() {
    started = false
    landed = false
    mediaInfo = nil
    markers = PlayerModel.noMarkers
    cues = []
    clock.subs = []
    clock.time = 0
    subId = nil
    subDelay = 0
    online = nil
    onlineQuery = ""
    syncing = nil
    making = nil
    trick = nil
    trickSheets = [:]
    previewTask?.cancel()
    lastTick = nil
    introSkipped = false
    nextDismissed = false
    lastSaved = .distantPast
    endedHandled = false
    hideNext()
    hidePeek()
    skipVisible = false
    failure = nil
    closePanel()
  }

  private func pickAudio(_ probe: ProbeInfo?) -> Int {
    let tracks = probe?.audio ?? []
    if tracks.count <= 1 { return 0 }
    let pref = Prefs.audioLang
    if !pref.isEmpty, let i = tracks.firstIndex(where: { $0.lang == pref }) { return i }
    return max(0, tracks.firstIndex(where: \.default) ?? -1)
  }

  // ---- Media ------------------------------------------------------------------------------

  private func startMedia(_ at: Double) {
    guard let info else { return }
    setLoading(true)
    started = true
    landed = false
    // Without ffprobe's list of tracks, the decoder picks the file's default.
    mp.open(path: info.path, at: at, audioIndex: info.probe == nil ? nil : audio, play: true)
    syncPlaying()
  }

  private func opened(_ m: MediaPlayer.Info) {
    mediaInfo = m
    if info?.probe == nil { audio = max(0, m.audioIndex) }
    updateNowPlaying()
  }

  private func seeked() {
    guard !mp.isSeeking else { return }  // a later seek is still landing
    spinnerTask?.cancel()
    if !landed {
      landed = true
      showControls()
    }
    setLoading(false)
    failure = nil
    updateNowPlaying()
  }

  private func ended() {
    syncPlaying()
    if endedHandled { return }
    endedHandled = true
    saveProgress()
    if nextId != nil && app.lib.settings.autoplayNext && !nextDismissed { return playNext() }
    if nextId != nil { return showNext(0) }
    let f = fid
    Task {
      await sleep(seconds: 1.2)
      if fid == f && f != nil && !mp.isPlaying { exit() }
    }
  }

  private func failed(_ message: String) {
    syncPlaying()
    showError("This video could not be played", message)
  }

  func retry() {
    failure = nil
    if info == nil, let f = fid {
      fid = nil
      open(f, start: nil)
    } else {
      startMedia(time)
    }
  }

  func seek(_ to: Double) {
    guard info != nil, started else { return }  // still opening
    let dur = duration
    let t = max(0, dur > 0 ? min(to, dur - 0.25) : to)
    nextDismissed = nextDismissed && t >= (markers.credits?.start ?? .infinity)
    endedHandled = false
    mp.seek(to: t)
    // The ring only if landing takes a moment.
    spinnerTask?.cancel()
    spinnerTask = Task {
      try? await Task.sleep(nanoseconds: 250_000_000)
      if !Task.isCancelled && mp.isSeeking { setLoading(true) }
    }
    lastTick = t
    update(force: true)
    saveSoon()
    updateNowPlaying()
  }

  func togglePlay() {
    guard started, failure == nil else { return }
    if mp.isPlaying { mp.pause() } else { mp.play() }
    syncPlaying()
    flash(playing ? "play.fill" : "pause.fill")
    if !playing { saveProgress() }
    showControls()
  }

  func play() {
    guard started, !mp.isPlaying else { return }
    mp.play()
    syncPlaying()
    showControls()
  }

  func pause() {
    guard started, mp.isPlaying else { return }
    mp.pause()
    syncPlaying()
    saveProgress()
    showControls()
  }

  /// Playing or not, as the player says; the Mac stays awake while it plays.
  private func syncPlaying() {
    let now = mp.isPlaying && fid != nil
    if now != playing { playing = now }
    keepAwake(now)
    updateNowPlaying()
  }

  private func keepAwake(_ on: Bool) {
    if on && sleepAssertion == 0 {
      var id: IOPMAssertionID = 0
      let r = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "Nightcap is playing a video" as CFString, &id)
      if r == kIOReturnSuccess { sleepAssertion = id }
    } else if !on && sleepAssertion != 0 {
      IOPMAssertionRelease(sleepAssertion)
      sleepAssertion = 0
    }
  }

  // Seek-bar thumbnails: made in the background on first play (about a
  // second per episode), so keep asking until they exist. The player keeps
  // the decoded sheets itself: a 45-minute episode's take about 100 MB, more
  // than the shared cache holds, and a sheet it let go never came back.
  private func loadPreviews(_ fid: String) {
    previewTask?.cancel()
    previewTask = Task {
      for _ in 0...60 {
        if Task.isCancelled || self.fid != fid { return }
        if let m = Previews.manifest(fid) {
          trick = m
          for n in 0..<m.sheets {
            let sheet = await Previews.sheet(fid, m, n)
            if Task.isCancelled || self.fid != fid { return }
            if let sheet { trickSheets[n] = sheet }
          }
          return
        }
        await sleep(seconds: 3)
      }
    }
  }

  /// The seek-bar thumbnail nearest to `t`, once its sheet is decoded.
  func trickFrame(_ t: Double) -> CGImage? {
    guard let m = trick else { return nil }
    let p = Previews.place(m, t)
    return trickSheets[p.sheet]?.cropping(to: p.rect)
  }

  // ---- Volume (0...200%) and speed (0.25...3×, remembered) ----------------------------------

  private func applyVolume() {
    mp.volume = Float(volume)
    mp.isMuted = muted || volume == 0
  }

  func setVolume(_ v: Double, osd: Bool = false) {
    volume = max(0, min(Prefs.maxVolume, jsRound(v * 100) / 100))
    muted = volume == 0
    Prefs.volume = volume
    Prefs.muted = muted
    applyVolume()
    if osd { self.osd("Volume \(Int(jsRound(volume * 100)))%") }
  }

  func toggleMute() {
    if muted && volume == 0 { volume = 1 }
    muted.toggle()
    Prefs.muted = muted
    Prefs.volume = volume
    applyVolume()
    osd(muted ? "Muted" : "Volume \(Int(jsRound(volume * 100)))%")
  }

  /// The level heard: 0 when muted.
  var level: Double { muted ? 0 : volume }

  func setSpeed(_ s: Double, osd: Bool = false) {
    speed = jsRound(min(Prefs.maxSpeed, max(Prefs.minSpeed, s)) * 100) / 100
    Prefs.speed = speed
    mp.rate = Float(speed)
    updateNowPlaying()
    if osd { self.osd(speed == 1 ? "Normal speed" : "Speed \(fmtSpeed(speed))") }
  }

  /// Steps to the next multiple of `step`, up or down.
  func stepSpeed(_ dir: Double, _ step: Double) {
    let base = dir > 0 ? (speed / step + 1e-6).rounded(.down) : (speed / step - 1e-6).rounded(.up)
    setSpeed((base + dir) * step, osd: true)
  }

  // ---- Progress ------------------------------------------------------------------------------

  private func saveSoon() {
    saveTask?.cancel()
    saveTask = Task {
      try? await Task.sleep(nanoseconds: 800_000_000)
      if !Task.isCancelled { saveProgress() }
    }
  }

  func saveProgress() {
    guard let fid, started else { return }
    let dur = duration
    guard dur > 0 else { return }
    let position = time
    if position < 1 && app.progress(fid) == nil { return }
    lastSaved = Date()
    if let entry = try? app.engine.recordProgress(fid, position: position, duration: dur) { app.setProgress(fid, entry) }
  }

  // ---- Every frame ------------------------------------------------------------------------------

  private func tick() {
    guard fid != nil else { return }
    update(force: false)
  }

  private func update(force: Bool) {
    let t = time
    if clock.time != t { clock.time = t }
    renderSubs(t)
    if landed && !mp.isSeeking { checkMarkers(t) }
    if playing && Date().timeIntervalSince(lastSaved) > PlayerModel.saveEvery { saveProgress() }
    lastTick = t
  }

  private func checkMarkers(_ t: Double) {
    let settings = app.lib.settings
    let intro = markers.intro
    let inIntro = intro.map { t >= $0.start && t < $0.end - 1 } ?? false
    // Auto-skip only when playback runs into the intro, not after seeking into it.
    if let intro, inIntro, settings.autoSkipIntro, !introSkipped, let last = lastTick, last < intro.start + 0.75, t - last < 1.5 {
      introSkipped = true
      seek(intro.end)
      osd("Intro skipped")
      return
    }
    if skipVisible != inIntro { skipVisible = inIntro }

    let credits = markers.credits?.start
    if nextId != nil, let credits, t >= credits, !nextDismissed, nextShownFor != fid, t < duration - 0.5 {
      showNext(settings.autoplayNext ? settings.nextCountdown : 0)
    } else if nextShownFor == fid, let credits, t < credits - 1 {
      hideNext()
    }
  }

  func skipIntro() {
    guard let intro = markers.intro else { return }
    introSkipped = true
    seek(intro.end)
  }

  // ---- Subtitles ------------------------------------------------------------------------------

  /// Shows a track (nil: off) at once; its cues follow when loaded (the task returned).
  @discardableResult
  func selectSubtitle(_ id: String?, remember: Bool = true) -> Task<Void, Never>? {
    subId = id
    subDelay = delayFor(id)
    cues = []
    clock.subs = []
    let sub = info?.subtitles.first { $0.id == id }
    if remember { Prefs.subLabel = sub?.label }
    if let sub { Prefs.lastSubLabel = sub.label }
    guard let sub, let fid else { return nil }
    return Task {
      do {
        let text = try await app.engine.subtitleText(fid, sub.id)
        guard self.fid == fid, subId == sub.id else { return }
        cues = Cues.parse(text)
        if cues.isEmpty { win?.toast("That subtitle track is empty") }
      } catch {
        guard self.fid == fid, subId == sub.id else { return }
        win?.toast("Could not load subtitles")
      }
    }
  }

  private func autoSubtitles() {
    guard let label = Prefs.subLabel, let info else { return }
    let lang = (label.jsSplit(" ").first ?? "").jsLowercased
    let hit = info.subtitles.first { $0.label == label } ?? info.subtitles.first { $0.label.jsLowercased.jsStartsWith(lang) }
    if let hit {
      selectSubtitle(hit.id, remember: false)
    } else if info.onlineConfigured && app.lib.settings.autoFetchSubtitles {
      Task { await autoFetch() }
    }
  }

  /// Watching with subtitles on, but this video has none in that language:
  /// fetch the best match online.
  private func autoFetch() async {
    guard let fid else { return }
    let language = app.lib.settings.subtitleLanguage
    if language.isEmpty { return }
    do {
      let r = try await app.engine.autoSubtitle(fid, language: language, audio: audio)
      guard self.fid == fid, let track = r.track, subId == nil, Prefs.subLabel != nil else { return }
      addTrack(track)
      selectSubtitle(track.id, remember: false)
      osd("Subtitles: \(track.label)")
    } catch {
      guard self.fid == fid else { return }
      let message = errorText(error)
      logLine("[subs] automatic download failed: \(message)")
      if PlayerModel.quotaRe.test(message) { win?.toast(message, ms: 6000) }
    }
  }

  private static let quotaRe = Re("allowed|quota|limit", "i")

  private func addTrack(_ track: SubtitleTrack) {
    if info?.subtitles.contains(where: { $0.id == track.id }) == false { info?.subtitles.append(track) }
  }

  /// Subtitles on or off (C): back on with the ones last shown.
  func toggleSubtitles() {
    let subs = info?.subtitles ?? []
    if subId != nil {
      selectSubtitle(nil)
    } else if !subs.isEmpty {
      selectSubtitle((subs.first { $0.label == Prefs.lastSubLabel } ?? subs[0]).id)
    }
    osd(subId != nil ? "Subtitles on" : "Subtitles off")
  }

  private func delayFor(_ id: String?) -> Double {
    guard let id, let fid else { return 0 }
    return Prefs.subDelay("\(fid):\(id)")
  }

  func setSubDelay(_ d: Double, osd: Bool = true) {
    guard let subId, let fid else { return self.osd("Subtitles are off") }
    subDelay = jsRound(max(-600, min(600, d)) * 100) / 100
    Prefs.setSubDelay("\(fid):\(subId)", subDelay)
    if osd {
      self.osd(subDelay != 0 ? "Subtitles \(jsNumber(abs(subDelay))) s \(subDelay > 0 ? "later" : "earlier")" : "Subtitle timing reset")
    }
  }

  private func renderSubs(_ now: Double) {
    let t = now - subDelay
    if cues.isEmpty {
      if !clock.subs.isEmpty { clock.subs = [] }
      return
    }
    var runs: [CueRun] = []
    for c in cues {
      if c.start > t { break }
      if c.end > t {
        if !runs.isEmpty { runs.append(CueRun(text: "\n")) }
        runs += c.runs
      }
    }
    if runs != clock.subs { clock.subs = runs }
  }

  /// Fits the selected track to the dialogue (about 3 s, on this Mac).
  func syncToAudio() {
    guard let id = subId, let fid, syncing == nil else { return }
    syncing = id
    Task {
      defer { syncing = nil }
      do {
        let r = try await app.engine.syncSubtitle(fid, id, audio: audio)
        guard self.fid == fid else { return }
        setTrackSync(id, r.sync)
        if r.result.applied || r.result.inSync {
          setSubDelay(0, osd: false)
          if subId == id { await selectSubtitle(id, remember: false)?.value }
          win?.toast(r.result.applied ? "Subtitles synced: \(describeSync(r.sync))" : "These subtitles already match the dialogue")
        } else {
          let reason = r.result.reason.flatMap { $0.isEmpty ? nil : $0 } ?? "Could not match these subtitles to the dialogue"
          win?.toast("\(reason). Use Earlier / Later (G / H) instead.", ms: 5000)
        }
      } catch {
        win?.toast(errorText(error), ms: 5000)
      }
    }
  }

  func undoSync() {
    guard let id = subId, let fid else { return }
    do {
      try app.engine.clearSubtitleSync(fid, id)
      setTrackSync(id, nil)
      Task {
        await selectSubtitle(id, remember: false)?.value
        win?.toast("Original subtitle timing restored")
      }
    } catch {
      win?.toast(errorText(error))
    }
  }

  private func setTrackSync(_ id: String, _ sync: SubTiming?) {
    if let i = info?.subtitles.firstIndex(where: { $0.id == id }) { info?.subtitles[i].sync = sync }
  }

  // ---- Subtitles made on this Mac ---------------------------------------------------------------

  /// Apple's recogniser hears English: offered while the audio track playing
  /// is English or unlabelled.
  var canMakeSubtitles: Bool {
    guard let tracks = info?.probe?.audio else { return true }
    guard audio < tracks.count else { return false }
    let code = tracks[audio].lang.jsLowercased
    return code.isEmpty || code == "und" || (lang3[code] ?? code) == "en"
  }

  /// English subtitles from the dialogue of the audio track playing (about
  /// 30 s for an episode, on this Mac), shown when made.
  func makeSubtitles() {
    guard let fid, making == nil else { return }
    let seq = openSeq
    making = "Making subtitles…"
    Task {
      do {
        let track = try await app.engine.makeSubtitles(fid, audio: audio) { [weak self] step in
          guard let self, seq == openSeq, making != nil else { return }
          making = PlayerModel.makingText(step)
        }
        guard seq == openSeq else { return }
        making = nil
        addTrack(track)
        selectSubtitle(track.id)
        win?.toast("Subtitles added: \(track.label)", ms: 4000)
      } catch {
        guard seq == openSeq else { return }
        making = nil
        win?.toast(errorText(error), ms: 6000)
      }
    }
  }

  private static func makingText(_ step: MadeSubs.Step) -> String {
    switch step {
    case let .model(f): return "Getting Apple’s English speech model… \(Int(f * 100))%"
    case .audio: return "Reading the audio…"
    case let .listening(f): return "Listening to the dialogue… \(Int(f * 100))%"
    }
  }

  // ---- Online subtitles (OpenSubtitles.com) ---------------------------------------------------------

  /// The online panel's search, started the first time it opens for this video
  /// (once OpenSubtitles is set up).
  func startOnline() {
    if online == nil { online = OnlineSearch(language: app.lib.settings.subtitleLanguage.isEmpty ? "en" : app.lib.settings.subtitleLanguage) }
    // It may have been set up in Settings since the video opened.
    if info?.onlineConfigured == false, app.engine.onlineSubs.status().configured { info?.onlineConfigured = true }
    guard info?.onlineConfigured == true else { return }
    if let o = online, o.results == nil, !o.loading, o.error == nil { onlineSearch() }
  }

  func submitOnlineQuery() {
    online?.query = onlineQuery.jsTrimmed
    onlineSearch()
  }

  func setOnlineLanguage(_ code: String) {
    online?.language = code
    onlineSearch()
  }

  func onlineSearch() {
    guard let fid, var o = online else { return }
    o.loading = true
    o.error = nil
    online = o
    let seq = openSeq
    Task {
      do {
        let r = try await app.engine.searchSubtitles(fid, language: o.language, query: o.query.isEmpty ? nil : o.query)
        guard seq == openSeq, online != nil else { return }
        online?.results = r.results
        online?.status = r.status
        if online?.query.isEmpty == true {
          online?.query = r.query
          onlineQuery = r.query
        }
      } catch {
        guard seq == openSeq, online != nil else { return }
        online?.error = errorText(error)
        online?.results = nil
      }
      online?.loading = false
    }
  }

  func onlineDownload(_ r: SubtitleResult) {
    guard let fid, online != nil else { return }
    online?.busy = r.id
    online?.busyText = r.hashMatch ? "Downloading…" : "Downloading and syncing to the dialogue…"
    let seq = openSeq
    Task {
      do {
        let res = try await app.engine.downloadSubtitle(fid, r, audio: audio)
        guard seq == openSeq else { return }
        online?.status = res.status
        online?.busy = nil
        guard let track = res.track else {
          win?.toast("The downloaded subtitle could not be read", ms: 6000)
          return
        }
        addTrack(track)
        closePanel()
        selectSubtitle(track.id)
        let synced = track.sync.map { " (synced to the dialogue: \(describeSync($0)))" } ?? ""
        win?.toast("Subtitles added: \(track.label)\(synced)", ms: 4000)
      } catch {
        guard seq == openSeq else { return }
        online?.busy = nil
        win?.toast(errorText(error), ms: 6000)
      }
    }
  }

  func removeTrack(_ id: String) {
    guard let fid else { return }
    Task {
      do {
        let tracks = try await app.engine.removeSubtitle(fid, id)
        guard self.fid == fid else { return }
        info?.subtitles = tracks
        if subId == id { selectSubtitle(nil, remember: false) }
      } catch {
        win?.toast(errorText(error))
      }
    }
  }

  // ---- Picture ------------------------------------------------------------------------------------

  /// Chooses how the picture is shown, in every player (the others follow Prefs).
  func choosePicture(_ m: PictureMode) {
    Prefs.picture = m
    followPicture()
  }

  /// Takes up the picture setting when it changed. Playing, the new picture
  /// follows the half second already queued; paused, the frame is shown again.
  private func followPicture() {
    let m = Prefs.picture
    guard m != picture else { return }
    picture = m
    mp.picture = m
    if started && landed && failure == nil && !mp.isPlaying && !mp.ended && !mp.isSeeking { seek(time) }
  }

  // ---- Audio --------------------------------------------------------------------------------------

  func switchAudio(_ i: Int) {
    guard i != audio, let tracks = info?.probe?.audio, i < tracks.count else { return }
    audio = i
    Prefs.audioLang = tracks[i].lang
    mp.selectAudio(i)
    spinnerTask?.cancel()
    spinnerTask = Task {
      try? await Task.sleep(nanoseconds: 250_000_000)
      if !Task.isCancelled && mp.isSeeking { setLoading(true) }
    }
  }

  // ---- Intro and credits (corrections) ------------------------------------------------------------

  /// Tenths of a second, as the corrections are stored.
  var nowTenths: Double { jsRound(time * 10) / 10 }

  func setMarkers(intro: Override<Span>? = nil, credits: Override<Mark>? = nil, reset: Bool = false, _ message: String) {
    guard let fid else { return }
    do {
      markers = try app.engine.setMarkers(fid, intro: intro, credits: credits, reset: reset)
      app.setMarkers(fid, markers)
      win?.toast(message)
    } catch {
      win?.toast(errorText(error))
    }
  }

  // ---- Next episode -------------------------------------------------------------------------------

  private func showNext(_ countdown: Int) {
    guard let next = nextId else { return }
    nextShownFor = fid
    nextCard = next
    countTask?.cancel()
    clock.countdown = 0
    guard countdown > 0 else { return }
    // The countdown only runs while the video plays (or has ended).
    let total = Double(countdown)
    countTask = Task {
      var remaining = total
      var last = Date()
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
        if Task.isCancelled { return }
        let now = Date()
        let dt = now.timeIntervalSince(last)
        last = now
        if !mp.isPlaying && !mp.ended { continue }
        remaining -= dt
        clock.countdown = min(1, 1 - remaining / total)
        if remaining <= 0 { return playNext() }
      }
    }
  }

  private func hideNext() {
    countTask?.cancel()
    nextShownFor = nil
    nextCard = nil
  }

  func dismissNext() {
    nextDismissed = true
    countTask?.cancel()
    nextCard = nil
  }

  func playNext() {
    countTask?.cancel()
    guard let next = nextId else { return }
    saveProgress()
    open(next, start: nil)
  }

  /// Plays another episode from the Episodes panel.
  func playEpisode(_ id: String) {
    closePanel()
    open(id, start: nil)
  }

  // ---- What shows over the picture ---------------------------------------------------------------------

  private func setLoading(_ on: Bool) {
    center = on ? .spinner : .none
  }

  private func flash(_ icon: String) {
    flashSeq += 1
    center = .flash(id: flashSeq, icon: icon)
  }

  func osd(_ text: String) {
    win?.toast(text, ms: 1200)
  }

  private func showError(_ title: String, _ message: String) {
    setLoading(false)
    failure = PlayerFailure(title: title, message: message)
    showControls()
  }

  /// Shows the controls, and hides them again after 3 s of playing untouched.
  func showControls() {
    if idle {
      idle = false
      win?.setWindowButtons(visible: true)
    }
    idleTask?.cancel()
    idleTask = Task {
      try? await Task.sleep(nanoseconds: UInt64(PlayerModel.hideAfter * 1e9))
      guard !Task.isCancelled, fid != nil else { return }
      if playing && panel == nil && !dragging && !hoveringControls {
        idle = true
        NSCursor.setHiddenUntilMouseMoves(true)
        win?.setWindowButtons(visible: false)
      }
    }
  }

  func toggleFullScreen() {
    guard let win else { return }
    if !win.isFullScreen { enteredFullScreen = true }
    win.toggleFullScreen()
  }

  func fullScreenChanged(_ on: Bool) {
    if !on { enteredFullScreen = false }
  }

  /// A click on the picture: play or pause (after a moment, in case it's a
  /// double click, which is full screen). With a panel open it closes the panel.
  @ObservationIgnored private var clickTask: Task<Void, Never>?

  private func surfaceClicked(_ count: Int) {
    if count >= 2 {
      clickTask?.cancel()
      if count == 2 { toggleFullScreen() }
      return
    }
    if panel != nil { return closePanel() }
    clickTask?.cancel()
    clickTask = Task {
      try? await Task.sleep(nanoseconds: 220_000_000)
      if !Task.isCancelled { togglePlay() }
    }
  }

  // ---- Panels and hover cards -------------------------------------------------------------------------

  func togglePanel(_ kind: PlayerPanel) {
    if panel == kind { return closePanel() }
    hidePeek()
    panel = kind
    panelByHover = false
    panelSeason = nil
    if kind == .online { startOnline() }
    showControls()
  }

  func closePanel() {
    panel = nil
    panelByHover = false
  }

  /// Something in the panel was used: it stays open.
  func panelUsed() {
    panelByHover = false
  }

  /// Where the open panel is (the window's coordinates, from its top left).
  @ObservationIgnored var panelFrame: CGRect = .zero

  /// The mouse went down in the window: a click in the panel keeps it open
  /// (whatever it lands on, menus and fields included).
  func mouseDown(at point: CGPoint) {
    if panel != nil && panelFrame.contains(point) { panelUsed() }
  }

  private func hoverPanel(_ kind: PlayerPanel) {
    if panel == kind || (panel != nil && !panelByHover) { return }
    togglePanel(kind)
    panelByHover = true
  }

  private func unhoverPanel(_ kind: PlayerPanel) {
    if panelByHover && panel == kind { closePanel() }
  }

  /// A click on a button whose panel the pointer opened keeps it open.
  private func clickPanel(_ kind: PlayerPanel) {
    if panelByHover && panel == kind { panelByHover = false } else { togglePanel(kind) }
  }

  /// Resting on the Next button shows what comes next.
  private func showPeek() {
    guard nextId != nil, panel == nil || panelByHover else { return }
    if panel != nil { closePanel() }
    peekVisible = true
  }

  private func hidePeek() {
    peekVisible = false
  }

  private func later(_ b: PopupButton, _ seconds: Double, _ fn: @escaping @MainActor () -> Void) {
    hoverTimers[b]?.cancel()
    hoverTimers[b] = Task {
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
      if !Task.isCancelled { fn() }
    }
  }

  private func cancelHover(_ b: PopupButton) {
    hoverTimers[b]?.cancel()
    hoverTimers[b] = nil
  }

  private static func panelKind(_ b: PopupButton) -> PlayerPanel? {
    switch b {
    case .episodes: .episodes
    case .speed: .speed
    case .settings: .settings
    case .next: nil
    }
  }

  /// The pointer came onto (or left) a button that opens something.
  func buttonHover(_ b: PopupButton, _ inside: Bool) {
    if inside {
      later(b, 0.25) { [weak self] in
        guard let self else { return }
        if let kind = PlayerModel.panelKind(b) { hoverPanel(kind) } else { showPeek() }
      }
    } else {
      later(b, 0.4) { [weak self] in
        guard let self else { return }
        if let kind = PlayerModel.panelKind(b) { unhoverPanel(kind) } else { hidePeek() }
      }
    }
  }

  func buttonClick(_ b: PopupButton) {
    cancelHover(b)
    if let kind = PlayerModel.panelKind(b) { clickPanel(kind) } else { playNext() }
  }

  /// The pointer came onto (or left) the Next card that the Next button opened.
  func peekHover(_ inside: Bool) {
    hoveringControls = inside
    if inside { cancelHover(.next) } else { later(.next, 0.4) { [weak self] in self?.hidePeek() } }
  }

  func panelHover(_ inside: Bool) {
    for b in [PopupButton.episodes, .speed, .settings] {
      if inside {
        cancelHover(b)
      } else {
        later(b, 0.4) { [weak self] in
          if let kind = PlayerModel.panelKind(b) { self?.unhoverPanel(kind) }
        }
      }
    }
  }

  // ---- Keys ------------------------------------------------------------------------------------------

  /// A key pressed while the player is open; true if it was used.
  func onKey(_ e: NSEvent) -> Bool {
    guard fid != nil else { return false }
    if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
    if win?.window?.firstResponder is NSText { return false }  // typing in a field
    guard let k = e.characters, let scalar = k.unicodeScalars.first, k.unicodeScalars.count == 1 else { return false }
    let shift = e.modifierFlags.contains(.shift)
    func key(_ code: Int) -> Character { Character(Unicode.Scalar(UInt32(code))!) }
    let left = key(NSLeftArrowFunctionKey), right = key(NSRightArrowFunctionKey)
    let up = key(NSUpArrowFunctionKey), down = key(NSDownArrowFunctionKey)
    let c = Character(scalar)
    switch c {
    case " ", "k", "K": togglePlay()
    case left, "j": seek(time - (shift ? 30 : 10))
    case right, "l": seek(time + (shift ? 30 : 10))
    case up: setVolume(volume + 0.05, osd: true)
    case down: setVolume(volume - 0.05, osd: true)
    case "]", ">": stepSpeed(1, 0.25)
    case "[", "<": stepSpeed(-1, 0.25)
    case "}": stepSpeed(1, 0.05)
    case "{": stepSpeed(-1, 0.05)
    case "=": setSpeed(1, osd: true)
    case "g", "G": setSubDelay(subDelay - (shift ? 1 : 0.1))
    case "h", "H": setSubDelay(subDelay + (shift ? 1 : 0.1))
    case "m", "M": toggleMute()
    case "f", "F": toggleFullScreen()
    case "s" where skipVisible, "S" where skipVisible: skipIntro()
    case "n" where nextId != nil, "N" where nextId != nil: playNext()
    case "c", "C": toggleSubtitles()
    case "\u{1b}":
      if panel != nil {
        closePanel()
      } else if enteredFullScreen && win?.isFullScreen == true {
        toggleFullScreen()
      } else {
        exit()
        return true
      }
    case "0"..."9" where duration > 0:
      seek(Double(scalar.value - 0x30) / 10 * duration)
    default:
      return false
    }
    showControls()
    return true
  }

  // ---- Now Playing (Control Center, media keys) --------------------------------------------------------

  /// Tells Control Center what this player shows; the media keys then come here.
  func updateNowPlaying() {
    guard let fid, let f = app.file(fid) else { return }
    let t = title
    NowPlaying.update(
      self, fileId: fid, title: t?.isShow == true ? f.name : t?.name ?? f.name,
      artist: t?.isShow == true ? "\(t!.name) · \(app.epCode(fid))" : "", duration: duration, elapsed: time,
      rate: playing ? speed : 0, hasNext: nextId != nil)
  }

  /// Media keys and Control Center.
  func remote(_ command: RemoteCommand) {
    switch command {
    case .play: play()
    case .pause: pause()
    case .toggle: togglePlay()
    case .back: seek(time - 10)
    case .forward: seek(time + 10)
    case .seek(let t): seek(t)
    case .next: playNext()
    }
  }
}

// ---- Formatting, as the player wrote things ----------------------------------------------------------

func fmtSpeed(_ s: Double) -> String { "\(fixedNumber(s, 2))×" }

func fmtDelay(_ d: Double) -> String {
  d != 0 ? "\(d > 0 ? "+" : "−")\(fixedNumber(abs(d), 2)) s" : "0 s"
}

/// "3.6 s earlier, frame rate fixed" for a stored correction.
func describeSync(_ sync: SubTiming?) -> String {
  guard let sync else { return "" }
  var parts: [String] = []
  if abs(sync.offset) >= 0.05 { parts.append("\(fixedNumber(abs(sync.offset), 1)) s \(sync.offset < 0 ? "earlier" : "later")") }
  if sync.scale != 1 { parts.append("frame rate fixed") }
  return parts.isEmpty ? "checked" : parts.joined(separator: ", ")
}

/// 950, 1.2K, 34K, 1.5M.
func fmtCount(_ n: Double) -> String {
  if n >= 1e6 { return "\(fixedNumber(n / 1e6, 1))M" }
  if n >= 1e3 { return "\(fixedNumber(n / 1e3, n >= 1e4 ? 0 : 1))K" }
  return jsNumber(n)
}

private let lang3: [String: String] = [
  "eng": "en", "jpn": "ja", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it", "por": "pt", "kor": "ko",
  "chi": "zh", "zho": "zh", "hin": "hi", "rus": "ru", "ara": "ar", "dut": "nl", "nld": "nl", "swe": "sv", "nor": "no", "dan": "da",
  "fin": "fi", "pol": "pl", "tur": "tr", "tam": "ta", "tel": "te",
]

/// An audio track's language ("jpn", "en") as a name ("Japanese"); "" when unknown.
func audioLanguageName(_ code: String) -> String {
  if code.isEmpty || code == "und" { return "" }
  return languageName(lang3[code] ?? code)
}

/// "Japanese · Commentary · 5.1", or "Track 2".
func audioTrackName(_ a: ProbeInfo.Audio, _ i: Int) -> String {
  let lang = audioLanguageName(a.lang)
  let name = [lang, !a.title.isEmpty && a.title != lang ? a.title : ""].filter { !$0.isEmpty }.joined(separator: " · ")
  let channels = a.channels ?? 0
  let layout = channels > 2 ? " · \(channels == 6 ? "5.1" : channels == 8 ? "7.1" : "\(channels)ch")" : ""
  return (name.isEmpty ? "Track \(i + 1)" : name) + layout
}

/// What decodes the picture, for the Intro & credits column.
func decodingLabel(_ m: MediaPlayer.Info?) -> String {
  guard let m else { return "" }
  guard m.hasVideo else { return "Sound only" }
  let names = ["h264": "H.264", "hevc": "HEVC", "mpeg4": "MPEG-4", "av1": "AV1", "vp9": "VP9", "vp8": "VP8", "mpeg2video": "MPEG-2"]
  let codec = names[m.videoCodec] ?? m.videoCodec.uppercased()
  return "\(codec), decoded by \(m.hardware ? "the Mac’s hardware" : "the processor")"
}

// ---- Subtitle cues (WebVTT) ------------------------------------------------------------------------------

/// A stretch of subtitle text in one style.
struct CueRun: Equatable {
  var text: String
  var italic = false
  var bold = false
  var underline = false
}

struct Cue {
  let start: Double
  let end: Double
  let runs: [CueRun]
}

enum Cues {
  private static let crRe = Re("\\r")
  private static let blockRe = Re("\\n{2,}")
  private static let spaceRe = Re("\\s+")
  private static let commaRe = Re(",")
  private static let tsRe = Re(#"^(?:(\d+):)?(\d{1,2}):(\d{1,2}(?:\.\d+)?)$"#)
  private static let assRe = Re(#"\{\\[^}]*\}"#)
  private static let ampRe = Re("&")
  private static let ltRe = Re("<")
  private static let gtRe = Re(">")
  private static let formatRe = Re("&lt;(\\/?)([ibu])&gt;", "i")
  private static let tagRe = Re("&lt;\\/?[a-z][^&]*?&gt;", "i")

  static func parseTs(_ s: String) -> Double {
    guard let m = tsRe.match(commaRe.replace(s.jsTrimmed, ".", global: false)) else { return .nan }
    return jsNumberValue(m[1] ?? "0") * 3600 + jsNumberValue(m[2] ?? "") * 60 + jsNumberValue(m[3] ?? "")
  }

  static func parse(_ text: String) -> [Cue] {
    var cues: [Cue] = []
    for block in blockRe.split(crRe.replace(text, "")) {
      let lines = block.jsSplit("\n")
      guard let i = lines.firstIndex(where: { $0.jsIncludes("-->") }) else { continue }
      let parts = lines[i].jsSplit("-->")
      let start = parseTs(parts[0])
      let end = parseTs(spaceRe.split(parts.count > 1 ? parts[1].jsTrimmed : "")[0])
      let body = lines[(i + 1)...].joined(separator: "\n").jsTrimmed
      if !start.isNaN && !end.isNaN && !body.isEmpty { cues.append(Cue(start: start, end: end, runs: runs(html(body)))) }
    }
    return cues.stableSorted { numCompare($0.start, $1.start) }
  }

  /// The cue as the pages put it in the page: escaped, with only <i>, <b> and <u> kept.
  static func html(_ text: String) -> String {
    var esc = assRe.replace(text, "")
    esc = ampRe.replace(esc, "&amp;")
    esc = ltRe.replace(esc, "&lt;")
    esc = gtRe.replace(esc, "&gt;")
    return tagRe.replace(formatRe.replace(esc, "<$1$2>"), "")
  }

  /// That markup as styled runs, laid out as `white-space: pre-line` does:
  /// runs of spaces become one, line breaks stay, spaces at line ends go.
  static func runs(_ html: String) -> [CueRun] {
    var out: [CueRun] = []
    var italic = 0, bold = 0, underline = 0
    /// A space waiting for the next character, in the style it was written in (the first of a run survives).
    var pendingSpace: CueRun?
    var lineStart = true
    func current(_ s: String) -> CueRun { CueRun(text: s, italic: italic > 0, bold: bold > 0, underline: underline > 0) }
    func emit(_ run: CueRun) {
      if let last = out.last, last.italic == run.italic, last.bold == run.bold, last.underline == run.underline {
        out[out.count - 1].text += run.text
      } else {
        out.append(run)
      }
    }
    let u = Array(html.utf16)
    var i = 0
    var text: [UInt16] = []
    func flushText() {
      guard !text.isEmpty else { return }
      for ch in String(decoding: text, as: UTF16.self) {
        if ch == "\n" {
          pendingSpace = nil
          emit(current("\n"))
          lineStart = true
        } else if ch == " " || ch == "\t" {
          if !lineStart && pendingSpace == nil { pendingSpace = current(" ") }
        } else {
          if let space = pendingSpace { emit(space) }
          pendingSpace = nil
          lineStart = false
          emit(current(String(ch)))
        }
      }
      text = []
    }
    while i < u.count {
      if u[i] == 0x3C, let close = u[i...].firstIndex(of: 0x3E) {  // one of <i> </i> <b> </b> <u> </u>
        flushText()
        let tag = String(decoding: u[(i + 1)..<close], as: UTF16.self).jsLowercased
        let delta = tag.jsStartsWith("/") ? -1 : 1
        switch tag.jsStartsWith("/") ? String(tag.dropFirst()) : tag {
        case "i": italic = max(0, italic + delta)
        case "b": bold = max(0, bold + delta)
        case "u": underline = max(0, underline + delta)
        default: break
        }
        i = close + 1
      } else if u[i] == 0x26 {  // &amp; &lt; &gt;
        let rest = String(decoding: u[i..<min(u.count, i + 5)], as: UTF16.self)
        if rest.jsStartsWith("&amp;") {
          text.append(0x26)
          i += 5
        } else if rest.jsStartsWith("&lt;") {
          text.append(0x3C)
          i += 4
        } else if rest.jsStartsWith("&gt;") {
          text.append(0x3E)
          i += 4
        } else {
          text.append(u[i])
          i += 1
        }
      } else {
        text.append(u[i])
        i += 1
      }
    }
    flushText()
    return out
  }
}
