import Foundation

// The engine: the library, watch progress, settings, and the background work
// (intro/credits detection, previews, online subtitles). It does what the
// Node server's routes did, as method calls from the app's windows.
//
// On disk (DATA_DIR):
//   config.json     folders and settings
//   progress.json   where each video was left, and titles taken off Watching
//   library.json    the last scan

/// An error to show: the message, and the status the server answered with
/// (400 bad request, 404 unknown, 429 out of downloads, 502 OpenSubtitles
/// failed, 500 anything else).
struct EngineError: Error, Equatable {
  let message: String
  let status: Int

  init(_ message: String, _ status: Int) {
    self.message = message
    self.status = status
  }
}

/// An error carrying a message for people (as JavaScript's Error#message).
protocol MessageError: Error {
  var message: String { get }
}

extension EngineError: MessageError {}
extension OSError: MessageError {}
extension Sync.Failure: MessageError {}
extension Trickplay.Failure: MessageError {}

/// A video as the library pages list it.
struct FileSummary: Equatable {
  var id: String
  var titleId: String
  /// Index of the season in its title.
  var season: Int
  var number: Int?
  var name: String
  /// Seconds; 0 until known.
  var duration: Double
}

/// The intro and credits of one video, detected or corrected.
struct MarkerPair: Equatable {
  var intro: Span?
  var credits: Mark?
}

/// Everything the library pages show.
struct LibrarySnapshot {
  var titles: [Title]
  var files: [String: FileSummary]
  /// File ids in the order the scan found them (lists of matching episodes keep it).
  var fileOrder: [String]
  /// Only videos with an intro or credits.
  var markers: [String: MarkerPair]
  var progress: [String: ProgressEntry]
  var hidden: [String: Int64]
  var folders: [Folder]
  var folderStatus: [String: FolderStatus]
  var settings: Settings
  var scanning: Bool
  var ffmpeg: Bool
}

struct EngineStatus {
  var scanning: Bool
  var analysis: Analyzer.Status
  var previews: Trickplay.Status
  var folderStatus: [String: FolderStatus]
  var ffmpeg: Bool
}

/// What the player needs to start a video.
struct PlayInfo {
  var id: String
  var titleId: String
  var name: String
  var path: String
  /// The file's extension, lowercase, without the dot.
  var ext: String
  var probe: ProbeInfo?
  var subtitles: [SubtitleTrack]
  /// OpenSubtitles has an API key / a signed-in account.
  var onlineConfigured: Bool
  var onlineSignedIn: Bool
  var markers: Markers
  var progress: ProgressEntry?
  var ffmpeg: Bool
}

/// Settings to change; nil leaves one as it is.
struct SettingsPatch {
  var autoSkipIntro: Bool?
  var autoplayNext: Bool?
  var analysis: Bool?
  var nextCountdown: Double?
  var subtitleLanguage: String?
  var autoFetchSubtitles: Bool?
  var previews: Bool?
}

/// A sync attempt and the correction now in use for the track.
struct SyncReport {
  var result: SyncResult
  var sync: SubTiming?
}

struct SubtitleSearchReply {
  var query: String
  var results: [SubtitleResult]
  var language: String
  var status: OpenSubtitles.Status
}

struct AutoSubtitleReply {
  var track: SubtitleTrack?
  /// Downloaded just now.
  var fresh: Bool
  var status: OpenSubtitles.Status
}

/// A video's preview thumbnails: the manifest once made, else how it's going
/// ("working", "queued", "failed" or "none").
enum PreviewInfo: Equatable {
  case ready(TrickplayManifest)
  case pending(String)
}

@MainActor
final class Engine {
  static let folderKinds = ["auto", "shows", "movies"]
  static let artTypes = ["poster", "backdrop", "card"]
  nonisolated static let artWidths = [320, 480, 800, 1280]
  static let rescanEvery: Double = 15 * 60
  /// x<N> file next to the video, e<N> embedded track, d<N> downloaded or made here.
  nonisolated static let subIdRe = Re(#"^[xed]\d+$"#)
  nonisolated static let downloadedIdRe = Re(#"^d\d+$"#)
  nonisolated static let tildeRe = Re(#"^~(?=$|\/)"#)

  let config: JsonStore<Config>
  let progress: JsonStore<ProgressData>
  let libraryStore: JsonStore<Library>
  let media = Media()
  let subsync = SubSync()
  let maker = SubtitleMaker()
  let names = ShowNames()
  let fixes = JsonStore(Paths.data("subs-corrections.json"), defaults: LineFixLog())
  private(set) var analyzer: Analyzer!
  private(set) var onlineSubs: OnlineSubs!
  private(set) var trickplay: Trickplay!
  private(set) var stills: Stills!
  private(set) var library: Library
  private var titles: [String: Title] = [:]
  /// Videos opened from outside the library (Finder, File › Open), until the app quits.
  private var loose: [String: LibraryFile] = [:]
  /// Called when the library, detection or previews change.
  var onChange: (() -> Void)?

  init() {
    ensureDir(Paths.data)
    config = JsonStore(Paths.data("config.json"), defaults: Config())
    progress = JsonStore(Paths.data("progress.json"), defaults: ProgressData())
    libraryStore = JsonStore(Paths.data("library.json"), defaults: Library())
    // The JavaScript engine's library.json has no fileOrder: its files were in scan order.
    if libraryStore.data.fileOrder.isEmpty, !libraryStore.data.files.isEmpty,
      let raw = FileManager.default.contents(atPath: libraryStore.file)
    {
      libraryStore.data.fileOrder = JSON.memberKeys(String(decoding: raw, as: UTF8.self), "files") ?? []
    }
    library = libraryStore.data
    titles = Engine.byId(library.titles)
    analyzer = Analyzer(
      getLibrary: { [unowned self] in self.library }, media: media,
      isEnabled: { [unowned self] in self.config.data.settings.analysis })
    onlineSubs = OnlineSubs(getTitle: { [unowned self] in self.titles[$0] }, media: media)
    trickplay = Trickplay(
      getLibrary: { [unowned self] in self.library }, getLoose: { [unowned self] in self.loose }, media: media,
      isEnabled: { [unowned self] in self.config.data.settings.previews })
    stills = Stills(trickplay: { [weak self] in self?.trickplay }, markers: { [weak self] in self?.analyzer.markers($0) })
    analyzer.onChange = { [weak self] in self?.onChange?() }
    trickplay.onChange = { [weak self] in
      self?.onChange?()
      self?.sweepStills()
    }
  }

  private static func byId(_ titles: [Title]) -> [String: Title] {
    Dictionary(titles.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
  }

  // ---- Lifetime ---------------------------------------------------------------------

  private var periodic: Task<Void, Never>?
  private var stopped = false

  /// Scans now and every 15 minutes.
  func start() {
    guard periodic == nil, !stopped else { return }
    if Tools.ffmpeg == nil { logLine("[engine] ffmpeg not found: intro/credits detection and previews are off") }
    requestScan()
    periodic = Task { [weak self] in
      while !Task.isCancelled {
        await sleep(seconds: Engine.rescanEvery)
        guard !Task.isCancelled, let self else { return }
        await self.rescan()
      }
    }
  }

  /// Saves everything and ends every ffmpeg run (the app is quitting).
  func shutdown() {
    guard !stopped else { return }
    stopped = true
    periodic?.cancel()
    stills.stop()
    config.flush()
    progress.flush()
    libraryStore.flush()
    analyzer.flush()
    onlineSubs.flush()
    subsync.flush()
    names.flush()
    fixes.flush()
    media.flush()
    Children.shared.killAll()
  }

  // ---- Library ------------------------------------------------------------------------

  private var scanTask: Task<Void, Never>?
  /// The folders the running scan reads.
  private var scanFolders: [Folder] = []
  private var scanAgain = false
  var scanning: Bool { scanTask != nil }

  /// Scans the folders and waits for it.
  func rescan() async {
    await requestScan().value
  }

  /// Starts a scan (`scanning` is true from now), or joins the running one;
  /// if the folders changed since it began, another scan follows. (The server
  /// joined the running scan regardless, so a folder added during one was
  /// missed until the next.)
  @discardableResult
  func requestScan() -> Task<Void, Never> {
    if let running = scanTask {
      if config.data.folders != scanFolders { scanAgain = true }
      return running
    }
    let task = Task { @MainActor in
      repeat {
        scanAgain = false
        scanFolders = config.data.folders
        let folders = scanFolders
        let t0 = nowMs()
        let lib = await Task.detached(priority: .userInitiated) { Scanner.scanLibrary(folders) }.value
        library = lib
        titles = Engine.byId(lib.titles)
        libraryStore.data = lib
        libraryStore.save()
        logLine("[scan] \(lib.titles.count) titles, \(lib.files.count) videos (\(nowMs() - t0) ms)")
        analyzer.sync()
        trickplay.sync()
        sweepStills()
        warmProbes()
      } while scanAgain
      scanTask = nil
      onChange?()
    }
    scanTask = task
    onChange?()
    return task
  }

  private var warming = false

  /// Reads durations in the background so episode lists can show runtimes.
  private func warmProbes() {
    guard !warming, Tools.ffprobe != nil else { return }
    warming = true
    let files = library.orderedFiles
    Task {
      for f in files where media.cachedProbe(f) == nil { _ = await media.probe(f) }
      warming = false
    }
  }

  /// a || b for numbers: a unless it is missing, 0 or NaN.
  private static func or(_ a: Double?, _ b: Double) -> Double {
    guard let a, a != 0, !a.isNaN else { return b }
    return a
  }

  func isWatched(_ fileId: String, position: Double, duration: Double) -> Bool {
    if duration == 0 || duration.isNaN { return false }
    if let credits = analyzer.markers(fileId).credits, position >= credits.start - 2 { return true }
    return position >= duration * 0.95 || duration - position <= 15
  }

  func snapshot() -> LibrarySnapshot {
    let ordered = library.orderedFiles
    var files: [String: FileSummary] = [:]
    var markers: [String: MarkerPair] = [:]
    for f in ordered {
      files[f.id] = FileSummary(
        id: f.id, titleId: f.titleId, season: f.season, number: f.number, name: f.name,
        duration: Engine.or(media.cachedProbe(f)?.duration, Engine.or(progress.data.files[f.id]?.duration, 0)))
      let m = analyzer.markers(f.id)
      if m.intro != nil || m.credits != nil { markers[f.id] = MarkerPair(intro: m.intro, credits: m.credits) }
    }
    // Opened from outside the library: known to the player, not on any page.
    for f in loose.values where files[f.id] == nil {
      files[f.id] = FileSummary(
        id: f.id, titleId: f.titleId, season: f.season, number: f.number, name: f.name,
        duration: Engine.or(media.cachedProbe(f)?.duration, Engine.or(progress.data.files[f.id]?.duration, 0)))
    }
    return LibrarySnapshot(
      titles: library.titles, files: files, fileOrder: ordered.map(\.id), markers: markers, progress: progress.data.files,
      hidden: progress.data.hidden, folders: config.data.folders, folderStatus: library.folderStatus, settings: config.data.settings,
      scanning: scanning, ffmpeg: Tools.ffmpeg != nil)
  }

  func status() -> EngineStatus {
    EngineStatus(
      scanning: scanning, analysis: analyzer.status(), previews: trickplay.status(), folderStatus: library.folderStatus,
      ffmpeg: Tools.ffmpeg != nil)
  }

  func file(_ id: String) throws -> LibraryFile {
    guard let f = library.files[id] ?? loose[id] else { throw EngineError("unknown file", 404) }
    return f
  }

  func title(_ id: String) -> Title? { titles[id] }

  // ---- Videos opened from outside the library ------------------------------------------

  /// The id to play a file by (Finder's Open With, File › Open): the library's
  /// own video when it is one (after a scan, if it sits in a library folder the
  /// last scan didn't see it in), else the file on its own. Nil when it can't be read.
  func openPath(_ rawPath: String) async -> String? {
    let p = resolvePath(rawPath)
    var st = stat()
    guard stat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
    if let id = libraryId(p, st) { return id }
    if inLibraryFolder(p) {
      await rescan()
      if let id = libraryId(p, st) { return id }
    }
    guard let f = Scanner.looseFile(p) else { return nil }
    loose[f.id] = f
    return f.id
  }

  /// The library's video at this path, or the same file reached another way
  /// (a link, another mount): same size, same file on disk.
  private func libraryId(_ p: String, _ st: stat) -> String? {
    let id = hashId(p)
    if library.files[id]?.path == p { return id }
    for f in library.orderedFiles where f.size == Int64(st.st_size) {
      var other = stat()
      if stat(f.path, &other) == 0 && other.st_dev == st.st_dev && other.st_ino == st.st_ino { return f.id }
    }
    return nil
  }

  private func inLibraryFolder(_ p: String) -> Bool {
    let real = Scanner.realpath(p) ?? p
    return config.data.folders.contains { folder in
      guard let root = Scanner.realpath(folder.path) else { return false }
      return real.hasPrefix(root.hasSuffix("/") ? root : "\(root)/")
    }
  }

  // ---- Folders ------------------------------------------------------------------------

  private static func isFolderKind(_ kind: String?) -> Bool {
    guard let kind else { return false }
    return folderKinds.contains { $0.jsEquals(kind) }
  }

  func addFolder(_ rawPath: String, kind: String? = nil) async throws -> LibrarySnapshot {
    var p = Engine.tildeRe.replace(rawPath.jsTrimmed, Paths.home, global: false)
    if p.isEmpty { throw EngineError("Choose a folder", 400) }
    p = resolvePath(p)
    var st = stat()
    guard stat(p, &st) == 0 else { throw EngineError("Folder not found", 400) }
    guard (st.st_mode & S_IFMT) == S_IFDIR else { throw EngineError("That is not a folder", 400) }
    let id = hashId(p, 8)
    if !config.data.folders.contains(where: { $0.id == id }) {
      config.data.folders.append(Folder(id: id, path: p, kind: Engine.isFolderKind(kind) ? kind! : "auto", addedAt: nowMs()))
    }
    config.save()
    await rescan()
    return snapshot()
  }

  func setFolderKind(_ id: String, _ kind: String) async throws -> LibrarySnapshot {
    guard let i = config.data.folders.firstIndex(where: { $0.id == id }) else { throw EngineError("unknown folder", 404) }
    if Engine.isFolderKind(kind) { config.data.folders[i].kind = kind }
    config.save()
    await rescan()
    return snapshot()
  }

  func removeFolder(_ id: String) async -> LibrarySnapshot {
    config.data.folders.removeAll { $0.id == id }
    config.save()
    await rescan()
    return snapshot()
  }

  /// Rescans now.
  func scan() async -> LibrarySnapshot {
    await rescan()
    return snapshot()
  }

  // ---- Settings -----------------------------------------------------------------------

  func updateSettings(_ patch: SettingsPatch) -> Settings {
    var s = config.data.settings
    if let v = patch.autoSkipIntro { s.autoSkipIntro = v }
    if let v = patch.autoplayNext { s.autoplayNext = v }
    if let v = patch.analysis { s.analysis = v }
    // Whole seconds, 0 to 60 (as Math.max(0, Math.min(60, Math.round(n)))).
    if let v = patch.nextCountdown, !v.isNaN { s.nextCountdown = Int(max(0, min(60, jsRound(v)))) }
    if let v = patch.subtitleLanguage { s.subtitleLanguage = v }
    if let v = patch.autoFetchSubtitles { s.autoFetchSubtitles = v }
    if let v = patch.previews { s.previews = v }
    if !languageCodeRe.test(s.subtitleLanguage) { s.subtitleLanguage = Settings.systemLanguage }
    config.data.settings = s
    config.save()
    if s.analysis { analyzer.kick() }
    trickplay.sync()
    return s
  }

  // ---- Watching -----------------------------------------------------------------------

  func recordProgress(_ fileId: String, position: Double, duration: Double) throws -> ProgressEntry {
    guard let f = library.files[fileId] ?? loose[fileId], position.isFinite, duration.isFinite else {
      throw EngineError("bad progress", 400)
    }
    let entry = ProgressEntry(
      position: position > 0 ? position : 0, duration: duration, updatedAt: nowMs(),
      watched: isWatched(f.id, position: position, duration: duration))
    progress.data.files[f.id] = entry
    progress.save()
    return entry
  }

  /// Marks videos watched (at their end) or unwatched (no progress).
  func setWatched(_ fileIds: [String], watched: Bool) async -> [String: ProgressEntry] {
    let ids = fileIds.filter { library.files[$0] != nil }
    let now = nowMs()
    for (i, id) in ids.enumerated() {
      if watched {
        var duration = Engine.or(progress.data.files[id]?.duration, 0)
        if duration == 0, let f = library.files[id] { duration = Engine.or(await media.probe(f)?.duration, 0) }
        progress.data.files[id] = ProgressEntry(position: duration, duration: duration, updatedAt: now + Int64(i), watched: true)
      } else {
        progress.data.files[id] = nil
      }
    }
    progress.save()
    return progress.data.files
  }

  /// Takes a title off the Watching list.
  func hide(_ titleId: String) -> [String: Int64] {
    if titles[titleId] != nil { progress.data.hidden[titleId] = nowMs() }
    progress.save()
    return progress.data.hidden
  }

  func playInfo(_ fileId: String) async throws -> PlayInfo {
    let f = try file(fileId)
    if library.files[f.id] == nil {
      // Opened from outside the library: its own previews only.
      trickplay.prioritize([f.id])
    } else {
      guard let t = titles[f.titleId] else { throw EngineError("unknown title", 404) }
      let season = f.season >= 0 && f.season < t.seasons.count ? t.seasons[f.season] : nil
      analyzer.prioritize(t.id, season?.id)
      // Previews for this video first, then the episodes after it (Next Episode card).
      let eps = season?.episodes ?? []
      let i = eps.firstIndex(of: f.id) ?? -1
      let next = f.season + 1 >= 0 && f.season + 1 < t.seasons.count ? t.seasons[f.season + 1] : nil
      let nextSeasonStart = next.map { $0.isExtras ? [] : Array($0.episodes.prefix(1)) } ?? []
      let before = i >= 0 ? Array(eps[..<i]) : Array(eps.dropLast())  // eps.slice(0, i)
      trickplay.prioritize([f.id] + eps[(i + 1)...] + nextSeasonStart + before)
    }
    let info = await media.probe(f)
    let subtitles = await subtitleTracks(f)
    let online = onlineSubs.status()
    return PlayInfo(
      id: f.id, titleId: f.titleId, name: f.name, path: f.path, ext: extname(f.path).jsSlice(1).jsLowercased, probe: info,
      subtitles: subtitles, onlineConfigured: online.configured, onlineSignedIn: online.signedIn, markers: analyzer.markers(f.id),
      progress: progress.data.files[f.id], ffmpeg: Tools.ffmpeg != nil)
  }

  // ---- Subtitles ----------------------------------------------------------------------

  func subtitleTracks(_ f: LibraryFile) async -> [SubtitleTrack] {
    (await media.listSubtitles(f) + onlineSubs.list(f.id)).map { t in
      var t = t
      t.sync = subsync.get(f, t.id)
      return t
    }
  }

  func subtitleTracks(_ fileId: String) async throws -> [SubtitleTrack] {
    await subtitleTracks(try file(fileId))
  }

  /// The track without adverts, before any timing correction.
  private func plainVtt(_ f: LibraryFile, _ subId: String) async -> String? {
    let n = subId.jsStartsWith("d") ? Int(subId.dropFirst()) : nil
    let vtt = subId.jsStartsWith("d") ? n.flatMap { onlineSubs.vtt(f.id, $0) } : await media.subtitleVtt(f, subId)
    // Made here: nothing but the dialogue, which an advert filter could only harm.
    if let n, onlineSubs.isMade(f.id, n) { return vtt }
    return vtt.map { Subtext.stripAds($0).vtt }
  }

  /// The track as the player shows it: WebVTT, adverts removed, timing corrected.
  func subtitleText(_ fileId: String, _ subId: String) async throws -> String {
    let f = try file(fileId)
    guard Engine.subIdRe.test(subId) else { throw EngineError("bad subtitle id", 400) }
    guard let vtt = await plainVtt(f, subId) else { throw EngineError("subtitle unavailable", 404) }
    return Subtext.retime(vtt, subsync.get(f, subId))
  }

  /// Deletes a downloaded track; the video's tracks after.
  func removeSubtitle(_ fileId: String, _ subId: String) async throws -> [SubtitleTrack] {
    let f = try file(fileId)
    guard Engine.downloadedIdRe.test(subId) else { throw EngineError("Only downloaded subtitles can be removed", 400) }
    if let n = Int(subId.dropFirst()) { onlineSubs.remove(f.id, n) }
    subsync.clear(f, subId)
    return await subtitleTracks(f)
  }

  /// Fits a track to the dialogue (see SubSync) and keeps the correction.
  private func syncTrack(_ f: LibraryFile, _ subId: String, audio: Int) async throws -> SyncReport {
    guard let vtt = await plainVtt(f, subId) else {
      return SyncReport(result: SyncResult(confident: false, applied: false, reason: "Subtitle unavailable"), sync: nil)
    }
    let r = try await subsync.align(f, subId, vtt, audio: audio)
    let outcome = r.applied ? "applied" : r.inSync ? "in sync" : "not applied"
    logLine(
      "[subsync] \(f.name) \(subId): offset \(r.offset.map(jsNumber) ?? "-") s, scale \(r.scale.map { toFixed($0, 4) } ?? "-"), "
        + "z \(r.z.map(jsNumber) ?? "-"), ratio \(r.ratio.map(jsNumber) ?? "-") -> \(outcome)")
    return SyncReport(result: r, sync: subsync.get(f, subId))
  }

  func syncSubtitle(_ fileId: String, _ subId: String, audio: Int = 0) async throws -> SyncReport {
    let f = try file(fileId)
    guard Engine.subIdRe.test(subId) else { throw EngineError("bad subtitle id", 400) }
    do {
      return try await syncTrack(f, subId, audio: max(0, audio))
    } catch {
      throw EngineError("Could not sync: \(Engine.message(error))", 500)
    }
  }

  /// Drops a track's timing correction.
  func clearSubtitleSync(_ fileId: String, _ subId: String) throws {
    subsync.clear(try file(fileId), subId)
  }

  /// Downloads not made for this exact file are synced to the audio right away.
  private func afterDownload(_ f: LibraryFile, _ track: SubtitleTrack?, audio: Int) async -> SubtitleTrack? {
    guard var track, track.hashMatch != true else { return track }
    do {
      _ = try await syncTrack(f, track.id, audio: audio)
    } catch {
      logLine("[subsync] failed: \(Engine.message(error))")
    }
    track.sync = subsync.get(f, track.id)
    return track
  }

  private static func message(_ error: Error) -> String {
    (error as? MessageError)?.message ?? error.localizedDescription
  }

  // ---- Online subtitles (OpenSubtitles.com) ----------------------------------------------

  /// OpenSubtitles failures answer 502, except bad requests (400) and running out of downloads (429).
  private func online<T>(_ fn: () async throws -> T) async throws -> T {
    do {
      return try await fn()
    } catch let e as OSError {
      throw EngineError(e.message, e.status == 400 || e.status == 429 ? e.status : 502)
    } catch let e as EngineError {
      throw e
    } catch {
      throw EngineError(error.localizedDescription, 500)
    }
  }

  /// The account and download allowance; `refresh` asks OpenSubtitles first.
  func openSubtitlesStatus(refresh: Bool = false) async -> OpenSubtitles.Status {
    refresh ? await onlineSubs.os.refreshUser() : onlineSubs.status()
  }

  func setOpenSubtitlesKey(_ apiKey: String?) async throws -> OpenSubtitles.Status {
    try await online { try await onlineSubs.os.setKey(apiKey) }
    return onlineSubs.status()
  }

  func signInOpenSubtitles(_ username: String?, _ password: String?) async throws -> OpenSubtitles.Status {
    try await online { try await onlineSubs.os.login(username, password) }
  }

  func signOutOpenSubtitles() async -> OpenSubtitles.Status {
    await onlineSubs.os.logout()
    return onlineSubs.status()
  }

  func searchSubtitles(_ fileId: String, language: String? = nil, query: String? = nil) async throws -> SubtitleSearchReply {
    let f = try file(fileId)
    let lang = language.flatMap { $0.isEmpty ? nil : $0 } ?? config.data.settings.subtitleLanguage
    let found = try await online { try await onlineSubs.search(f, language: lang, query: query) }
    return SubtitleSearchReply(query: found.query, results: found.results, language: lang, status: onlineSubs.status())
  }

  func downloadSubtitle(_ fileId: String, _ pick: SubtitleResult, audio: Int = 0) async throws -> (track: SubtitleTrack?, status: OpenSubtitles.Status) {
    let f = try file(fileId)
    let got = try await online { try await onlineSubs.fetch(f, pick) }
    let track = await afterDownload(f, got, audio: max(0, audio))
    return (track, onlineSubs.status())
  }

  /// The best subtitle in `language` (else the settings' one), downloaded
  /// unless the video has one already.
  func autoSubtitle(_ fileId: String, language: String? = nil, audio: Int = 0) async throws -> AutoSubtitleReply {
    let f = try file(fileId)
    let lang = languageCodeRe.test(language ?? "") ? language! : config.data.settings.subtitleLanguage
    let r = try await online { try await onlineSubs.auto(f, language: lang) }
    var track: SubtitleTrack?
    if r.fresh {
      track = await afterDownload(f, r.track, audio: max(0, audio))
    } else if var t = r.track {
      t.sync = subsync.get(f, t.id)
      track = t
    }
    return AutoSubtitleReply(track: track, fresh: r.fresh, status: onlineSubs.status())
  }

  // ---- Subtitles made on this Mac ------------------------------------------------------

  /// Makes English subtitles from the dialogue of audio track `audio` (MadeSubs):
  /// about 30 s for a 45-minute episode. Timed from the audio itself, so never synced.
  /// The names to expect (ShowNames) are looked up while the dialogue is heard.
  func makeSubtitles(_ fileId: String, audio: Int = 0, progress: @escaping @MainActor (MadeSubs.Step) -> Void) async throws -> SubtitleTrack {
    let f = try file(fileId)
    let audio = max(0, audio)
    let (title, episode) = onlineSubs.describe(f)
    let lookup = Task { await names.names(for: f, title: title, episode: episode, known: MadeSubs.dictionaryKnows) }
    do {
      return try await maker.make(f, audio: audio, names: { await lookup.value }, progress: progress) { vtt, found in
        guard let track = try self.onlineSubs.addMade(f, vtt, audio: audio, namesFrom: found.fromTVmaze ? "TVmaze" : nil) else {
          throw EngineError("Could not keep the subtitles", 500)
        }
        return track
      }
    } catch let e as MadeSubs.Failure {
      throw EngineError(e.message, 500)
    } catch let e as EngineError {
      throw e
    } catch {
      logLine("[subs] making failed for \(f.name): \(error)")
      throw EngineError("Could not make subtitles: \(error.localizedDescription)", 500)
    }
  }

  /// A fix to a made line, with what undoing it needs.
  struct FixDone {
    var fix: LineFix
    /// The track's text after the fix, and before it.
    var vtt: String
    var previous: String
  }

  /// Fixes the line of made track `trackId` shown from `start` to `end`, which
  /// read `before`, to `after` (empty: takes it out). Kept in the log; the names
  /// it corrects are learned for the video's title (LineFixes), and the word
  /// they replaced is respelt elsewhere in the track.
  func fixMadeLine(_ fileId: String, _ trackId: String, start: Double, end: Double, before: String, after: String) throws -> FixDone {
    let f = try file(fileId)
    guard Engine.downloadedIdRe.test(trackId), let n = Int(trackId.dropFirst()), onlineSubs.isMade(fileId, n),
      let vtt = onlineSubs.vtt(fileId, n)
    else { throw EngineError("Only subtitles made on this Mac can be fixed", 400) }
    let lines = LineFixes.lines(after)
    guard var out = LineFixes.replace(vtt, start: start, end: end, before: before, with: lines) else {
      throw EngineError("That line is no longer in these subtitles", 409)
    }
    let fixed = lines.joined(separator: "\n")
    let taught = LineFixes.taught(before: before, after: fixed, known: MadeSubs.dictionaryKnows)
    var elsewhere = 0
    for t in taught {
      guard let heard = t.heard else { continue }
      let r = LineFixes.respell(out, heard: heard, as: t.name, except: (start, end), known: MadeSubs.dictionaryKnows)
      out = r.vtt
      elsewhere += r.cues
    }
    try onlineSubs.replaceVtt(fileId, n, out)
    let learned = titles[f.titleId] == nil ? [] : names.learn(taught.map(\.name), for: f.titleId)
    let fix = LineFix(
      file: fileId, video: f.name, track: n, start: start, end: end, before: before, after: fixed, learned: learned,
      elsewhere: elsewhere, at: nowMs())
    fixes.data.fixes.append(fix)
    fixes.save()
    logLine("[subs] fixed a line of \(f.name) (d\(n))\(learned.isEmpty ? "" : ", learned \(learned.joined(separator: ", "))")"
      + "\(elsewhere > 0 ? ", \(elsewhere) more line\(elsewhere == 1 ? "" : "s") respelt" : "")")
    return FixDone(fix: fix, vtt: out, previous: vtt)
  }

  /// Undoes a fix (the last one made to its track): the track as it was, the
  /// names it taught forgotten, the fix out of the log. The track's text now.
  func undoFix(_ done: FixDone) throws -> String {
    try onlineSubs.replaceVtt(done.fix.file, done.fix.track, done.previous)
    if !done.fix.learned.isEmpty, let f = try? file(done.fix.file) { names.forget(done.fix.learned, for: f.titleId) }
    if let i = fixes.data.fixes.lastIndex(of: done.fix) {
      fixes.data.fixes.remove(at: i)
      fixes.save()
    }
    return done.previous
  }

  /// Names learned from fixes for one title.
  struct LearnedNames: Identifiable, Equatable {
    var titleId: String
    /// The title's name (its id when it has left the library).
    var title: String
    var names: [String]
    var id: String { titleId }
  }

  /// The names learned from fixes, by title, titles in name order.
  func learnedNames() -> [LearnedNames] {
    names.store.data.learned.filter { !$0.value.isEmpty }
      .map { LearnedNames(titleId: $0.key, title: titles[$0.key]?.name ?? $0.key, names: $0.value) }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  func forgetName(_ name: String, titleId: String) {
    names.forget([name], for: titleId)
  }

  // ---- Artwork ------------------------------------------------------------------------

  /// The narrowest made width at least `width` wide (480 when not given).
  nonisolated static func pickWidth(_ width: Double?) -> Int {
    let want = width ?? 480
    return artWidths.first { Double($0) >= want } ?? 1280
  }

  private static func existing(_ path: String?) -> String? {
    guard let path, fileExists(path) else { return nil }
    return path
  }

  /// A picture for a title: its own art, else the best still of a few of its
  /// episodes (else a frame from one). `type`: "poster", "backdrop" or "card" (the default).
  func titleArt(_ titleId: String, type: String? = nil, width: Double? = nil) async throws -> String? {
    guard let t = titles[titleId] else { throw EngineError("unknown title", 404) }
    let type = Engine.artTypes.first { $0.jsEquals(type ?? "") } ?? "card"
    if type == "backdrop", let b = t.backdrop { return Engine.existing(b) }
    if type == "poster", let p = t.poster ?? t.backdrop { return Engine.existing(p) }
    if type == "card", let c = t.backdrop ?? t.poster { return Engine.existing(c) }
    guard let season = t.seasons.first(where: { !$0.isExtras && $0.number != 0 }) ?? t.seasons.first, !season.episodes.isEmpty else {
      return nil
    }
    let eps = season.episodes
    // Four episodes spread over the first season.
    let n = min(4, eps.count)
    let sample = (0..<n).compactMap { library.files[eps[$0 * eps.count / n]] }
    let w = Engine.pickWidth(width)
    if let best = await stills.best(sample),
      let pic = await stills.picture(best, shape: StillShape(rawValue: type) ?? .card, width: w)
    {
      return pic
    }
    guard let f = library.files[type == "backdrop" ? eps[eps.count / 2] : eps[0]] else { return nil }
    return Engine.existing(await media.frameThumb(f, at: type == "backdrop" ? 0.42 : 0.3, width: w))
  }

  /// A picture for a video: its own thumbnail, else its still (else a frame 30% in).
  func fileArt(_ fileId: String, width: Double? = nil) async throws -> String? {
    let f = try file(fileId)
    if let thumb = f.thumb { return Engine.existing(thumb) }
    let w = Engine.pickWidth(width)
    if let pic = await stills.picture(f, shape: .card, width: w) { return pic }
    return Engine.existing(await media.frameThumb(f, at: 0.3, width: w))
  }

  /// Chooses missing stills in the background, newest titles first (see `Stills.sweep`).
  private func sweepStills() {
    guard !stopped else { return }
    stills.sweep { [weak self] in
      guard let self else { return [] }
      return self.trickplay.wanted().compactMap { self.library.files[$0] }
    }
  }

  /// The frame of a video at `t` seconds, 16:9.
  func momentArt(_ fileId: String, at t: Double, width: Double? = nil) async throws -> String? {
    let f = try file(fileId)
    guard t.isFinite, t >= 0 else { throw EngineError("bad time", 400) }
    return await stills.moment(f, at: t, width: Engine.pickWidth(width))
  }

  /// Good moments to start a video from, spread over it (empty until its previews are made).
  func sceneTimes(_ fileId: String, count: Int) async throws -> [Double] {
    await stills.moments(try file(fileId), count: count)
  }

  // ---- Intro and credits ----------------------------------------------------------------

  /// Tenths of a second, never negative (Math.max(0, Math.round(x * 10) / 10)).
  private static func tenths(_ x: Double) -> Double {
    let v = jsRound(x * 10) / 10
    return v > 0 ? v : 0
  }

  /// Corrects a video's intro and credits: nil leaves one as it is, `.cleared`
  /// says there is none, `reset` goes back to what detection found.
  func setMarkers(_ fileId: String, intro: Override<Span>? = nil, credits: Override<Mark>? = nil, reset: Bool = false) throws -> Markers {
    let f = try file(fileId)
    var introPatch: Override<Span>?
    switch intro {
    case .set(let s)?:
      // Stores can't hold NaN or Infinity (the server let a credits NaN through as null).
      guard s.start.isFinite, s.end.isFinite else { throw EngineError("Intro must end after it starts", 400) }
      let clean = Span(start: Engine.tenths(s.start), end: Engine.tenths(s.end))
      if !(clean.end > clean.start) { throw EngineError("Intro must end after it starts", 400) }
      introPatch = .set(clean)
    case .cleared?: introPatch = .cleared
    case .unset?, nil: introPatch = nil
    }
    var creditsPatch: Override<Mark>?
    switch credits {
    case .set(let m)?:
      guard m.start.isFinite else { throw EngineError("Credits need a start time", 400) }
      creditsPatch = .set(Mark(start: Engine.tenths(m.start)))
    case .cleared?: creditsPatch = .cleared
    case .unset?, nil: creditsPatch = nil
    }
    analyzer.setManual(f.id, intro: introPatch, credits: creditsPatch, reset: reset)
    return analyzer.markers(f.id)
  }

  /// Detects a title's intros and credits again.
  func reanalyze(_ titleId: String) -> Analyzer.Status {
    analyzer.reanalyze(titleId)
    return analyzer.status()
  }

  /// Detection for this title (this season first) goes next.
  func prioritizeAnalysis(_ titleId: String, seasonId: String? = nil) {
    analyzer.prioritize(titleId, seasonId)
  }

  // ---- Preview thumbnails ---------------------------------------------------------------

  func previews(_ fileId: String) throws -> PreviewInfo {
    let f = try file(fileId)
    if let m = trickplay.manifest(f) { return .ready(m) }
    trickplay.prioritize([f.id])
    return .pending(trickplay.state(f))
  }

  /// The path of preview sheet `n` (a JPEG).
  func previewSheet(_ fileId: String, _ n: Int) throws -> String {
    guard let path = trickplay.sheetPath(try file(fileId), n) else { throw EngineError("no such preview sheet", 404) }
    return path
  }

  /// The episodes someone is looking at get their previews first.
  func prioritizePreviews(_ fileIds: [String]) {
    trickplay.prioritize(Array(fileIds.prefix(100)))
  }
}

/// Node's path.resolve for one path: absolute (from the working directory),
/// with ".", ".." and repeated or trailing slashes worked out by name (links
/// aren't followed).
func resolvePath(_ p: String) -> String {
  let full = p.jsStartsWith("/") ? p : "\(FileManager.default.currentDirectoryPath)/\(p)"
  var parts: [String] = []
  for seg in full.jsSplit("/") {
    if seg.isEmpty || seg.jsEquals(".") { continue }
    if seg.jsEquals("..") {
      if !parts.isEmpty { parts.removeLast() }
      continue
    }
    parts.append(seg)
  }
  return "/" + parts.joined(separator: "/")
}
