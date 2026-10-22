import Foundation
import Observation

// What every window shows: the engine's library, refreshed as it changes, and
// the "what plays next" rules the earlier web pages used (public/lib.js, in
// the git history).

/// Where a video sits in its title.
struct Location {
  let title: Title
  let season: Season
  let seasonIndex: Int
  let index: Int
}

/// What to play for a title: resume the last thing touched, or the episode after it.
struct NextUp {
  var fileId: String
  var start: Double
  /// Nothing watched yet.
  var fresh = false
  var resume = false
  var upNext = false
  /// Everything watched: back to the start.
  var again = false
  var updatedAt: Int64 = 0
}

/// A title on the Watching list, and what plays next in it.
struct Watching: Identifiable {
  let title: Title
  let next: NextUp
  var id: String { title.id }
}

@MainActor
@Observable
final class AppModel {
  @ObservationIgnored let engine: Engine

  private(set) var lib: LibrarySnapshot
  private(set) var status: EngineStatus
  @ObservationIgnored private(set) var titles: [String: Title] = [:]
  @ObservationIgnored private var locations: [String: Location] = [:]

  init() {
    engine = Engine()
    lib = engine.snapshot()
    status = engine.status()
    index()
    engine.onChange = { [weak self] in self?.changed() }
  }

  private func index() {
    titles = Dictionary(lib.titles.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    var loc: [String: Location] = [:]
    for t in lib.titles {
      for (si, s) in t.seasons.enumerated() {
        for (i, fid) in s.episodes.enumerated() {
          loc[fid] = Location(title: t, season: s, seasonIndex: si, index: i)
        }
      }
    }
    locations = loc
  }

  // ---- Keeping up with the engine ------------------------------------------------------

  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var lastRefresh = Date.distantPast

  /// The engine changed something: refresh soon, at most about once a second.
  private func changed() {
    guard refreshTask == nil else { return }
    let wait = max(0.1, 1 - Date().timeIntervalSince(lastRefresh))
    refreshTask = Task { [weak self] in
      await sleep(seconds: wait)
      guard let self else { return }
      self.refreshTask = nil
      self.refresh()
    }
  }

  func refresh() {
    lastRefresh = Date()
    replace(engine.snapshot())
    let st = engine.status()
    if st != status { status = st }
  }

  /// A snapshot the engine just returned (after adding a folder, say).
  func apply(_ snap: LibrarySnapshot) {
    replace(snap)
    let st = engine.status()
    if st != status { status = st }
  }

  private func replace(_ snap: LibrarySnapshot) {
    guard snap != lib else { return }
    let reindex = snap.titles != lib.titles
    lib = snap
    if reindex { index() }
  }

  func setProgress(_ fileId: String, _ entry: ProgressEntry) {
    lib.progress[fileId] = entry
  }

  func setProgress(_ all: [String: ProgressEntry]) {
    if all != lib.progress { lib.progress = all }
  }

  func setHidden(_ hidden: [String: Int64]) {
    lib.hidden = hidden
  }

  func setSettings(_ settings: Settings) {
    if settings != lib.settings { lib.settings = settings }
  }

  func setMarkers(_ fileId: String, _ m: Markers) {
    lib.markers[fileId] = m.intro != nil || m.credits != nil ? MarkerPair(intro: m.intro, credits: m.credits) : nil
  }

  // ---- Lookups ----------------------------------------------------------------------------

  func location(_ fid: String) -> Location? { locations[fid] }
  func file(_ fid: String) -> FileSummary? { lib.files[fid] }
  func progress(_ fid: String) -> ProgressEntry? { lib.progress[fid] }
  func markers(_ fid: String) -> MarkerPair? { lib.markers[fid] }

  private static func isMain(_ s: Season) -> Bool { !s.isExtras && s.number != 0 }

  /// "S1:E4", "Extra", a film's part name, or "".
  func epCode(_ fid: String) -> String {
    guard let w = location(fid), let f = file(fid) else { return "" }
    if !w.title.isShow { return w.season.episodes.count > 1 ? f.name : "" }
    if w.season.isExtras { return "Extra" }
    let ep = f.number.map { "E\($0)" }
    if let n = w.season.number { return ep.map { "S\(n):\($0)" } ?? "S\(n)" }
    return ep.map { "\(w.season.name) · \($0)" } ?? w.season.name
  }

  /// Episodes in viewing order. Specials and extras are not part of the main run.
  func playOrder(_ t: Title) -> [String] {
    let main = t.seasons.filter(AppModel.isMain).flatMap(\.episodes)
    return main.isEmpty ? t.seasons.flatMap(\.episodes) : main
  }

  func nextAfter(_ fid: String) -> String? {
    guard let w = location(fid) else { return nil }
    if !AppModel.isMain(w.season) || !w.title.isShow {
      return w.index + 1 < w.season.episodes.count ? w.season.episodes[w.index + 1] : nil
    }
    let order = playOrder(w.title)
    guard let i = order.firstIndex(of: fid), i + 1 < order.count else { return nil }
    return order[i + 1]
  }

  func nextUp(_ t: Title) -> NextUp {
    let order = playOrder(t)
    let first = order.first ?? ""
    var latest: (id: String, p: ProgressEntry)?
    for s in t.seasons {
      for id in s.episodes {
        if let p = progress(id), latest == nil || p.updatedAt > latest!.p.updatedAt { latest = (id, p) }
      }
    }
    guard let latest else { return NextUp(fileId: first, start: 0, fresh: true) }
    if !latest.p.watched {
      return latest.p.position > 5
        ? NextUp(fileId: latest.id, start: latest.p.position, resume: true, updatedAt: latest.p.updatedAt)
        : NextUp(fileId: latest.id, start: 0, updatedAt: latest.p.updatedAt)
    }
    if let next = nextAfter(latest.id) {
      let np = progress(next)
      let start = np.map { !$0.watched && $0.position > 5 ? $0.position : 0 } ?? 0
      return NextUp(fileId: next, start: start, resume: start > 0, upNext: true, updatedAt: latest.p.updatedAt)
    }
    return NextUp(fileId: first, start: 0, again: true, updatedAt: latest.p.updatedAt)
  }

  func nextUpLabel(_ t: Title, _ nu: NextUp) -> String {
    if !t.isShow { return nu.resume ? "Resume" : nu.again ? "Watch again" : "Play" }
    return "\(nu.resume ? "Resume" : "Play") \(epCode(nu.fileId))"
  }

  /// Titles being watched, the most recent first.
  func continueWatching() -> [Watching] {
    var out: [Watching] = []
    for t in lib.titles {
      let nu = nextUp(t)
      if nu.fresh || nu.again { continue }
      if (lib.hidden[t.id] ?? 0) >= nu.updatedAt { continue }
      out.append(Watching(title: t, next: nu))
    }
    return out.stableSorted { numCompare($1.next.updatedAt, $0.next.updatedAt) }
  }

  /// "2003 · 9 seasons", "1h 52m".
  func titleMeta(_ t: Title) -> String {
    var parts: [String] = []
    if let y = t.year { parts.append(String(y)) }
    if t.isShow {
      let seasons = t.seasons.filter { !$0.isExtras }
      parts.append(seasons.count == 1 ? "\(seasons[0].episodes.count) episodes" : "\(seasons.count) seasons")
    } else if let first = t.seasons.first {
      let d = first.episodes.reduce(0.0) { $0 + (file($1)?.duration ?? 0) }
      if d != 0 { parts.append(fmtDur(d)) }
    }
    return parts.joined(separator: " · ")
  }

  /// Progress along a picture's bottom edge (0...1).
  static func fraction(_ p: ProgressEntry) -> Double {
    p.watched ? 1 : p.duration > 0 ? p.position / p.duration : 0
  }
}

/// Titles by name, as people expect ("Episode 9" before "Episode 10"; case and accents ignored).
func byName(_ a: Title, _ b: Title) -> Int { naturalCompare(a.name, b.name) }

// ---- Snapshots compared, so pages only redraw for real changes --------------------------

extension LibrarySnapshot: Equatable {
  static func == (a: LibrarySnapshot, b: LibrarySnapshot) -> Bool {
    a.scanning == b.scanning && a.ffmpeg == b.ffmpeg && a.settings == b.settings && a.folders == b.folders
      && a.folderStatus == b.folderStatus && a.hidden == b.hidden && a.progress == b.progress && a.markers == b.markers
      && a.fileOrder == b.fileOrder && a.files == b.files && a.titles == b.titles
  }
}

extension EngineStatus: Equatable {
  static func == (a: EngineStatus, b: EngineStatus) -> Bool {
    a.scanning == b.scanning && a.ffmpeg == b.ffmpeg && a.analysis == b.analysis && a.previews == b.previews
      && a.folderStatus == b.folderStatus
  }
}

// ---- Subtitle languages, as OpenSubtitles codes them -------------------------------------

let subLanguageCodes = [
  "en", "es", "fr", "de", "it", "pt-PT", "pt-BR", "nl", "sv", "no", "da", "fi", "is", "pl", "cs", "sk", "hu", "ro", "bg", "el",
  "tr", "ru", "uk", "sr", "hr", "sl", "bs", "mk", "sq", "et", "lv", "lt", "ar", "he", "fa", "hi", "bn", "ta", "te", "ml", "ur",
  "zh-CN", "zh-TW", "ja", "ko", "th", "vi", "id", "ms", "tl",
]

/// The languages to choose from (plus `current` if it isn't one of them), by name.
func subLanguages(_ current: String?) -> [(code: String, name: String)] {
  var codes = subLanguageCodes
  if let current, !current.isEmpty, !codes.contains(where: { $0.jsLowercased == current.jsLowercased }) { codes.append(current) }
  return codes.map { (code: $0, name: languageName($0)) }
    .stableSorted { a, b in
      switch a.name.compare(b.name, locale: Locale(identifier: "en")) {
      case .orderedAscending: return -1
      case .orderedDescending: return 1
      case .orderedSame: return 0
      }
    }
}
