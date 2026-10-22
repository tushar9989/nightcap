import Foundation

// The engine's data, as stored in DATA_DIR. Field names and shapes are those
// the JavaScript engine wrote, so existing data carries over unchanged.

// ---- Library (library.json) ---------------------------------------------------

struct SubRef: Codable, Equatable {
  var path: String
  var label: String
}

struct LibraryFile: Codable, Equatable {
  var id: String
  var titleId: String
  /// Index of the season in its title.
  var season: Int
  var number: Int?
  var name: String
  var path: String
  var size: Int64
  var mtime: Int64
  var thumb: String?
  var subs: [SubRef]
}

struct Season: Codable, Equatable {
  var id: String
  var number: Int?
  var name: String
  var poster: String?
  var episodes: [String]
  var extras: Bool?

  var isExtras: Bool { extras == true }
}

struct Title: Codable, Equatable {
  var id: String
  /// "show" or "movie".
  var kind: String
  var name: String
  var year: Int?
  var folderIds: [String]
  var poster: String?
  var backdrop: String?
  var seasons: [Season]
  var addedAt: Int64

  var isShow: Bool { kind == "show" }
}

struct FolderStatus: Codable, Equatable {
  var online: Bool
  var error: String?
  var titles: Int?
  var videos: Int?
  var scannedAt: Int64?
}

struct Library: Codable {
  var titles: [Title] = []
  var files: [String: LibraryFile] = [:]
  var folderStatus: [String: FolderStatus] = [:]
  var scannedAt: Int64 = 0
  /// File ids in the order the scan found them: the order of `files` in the
  /// JavaScript engine's library.json, which lists of matching episodes kept.
  /// (Dictionaries here have no order.) Empty in that engine's file.
  var fileOrder: [String] = []

  init() {}
  init(titles: [Title], files: [String: LibraryFile], folderStatus: [String: FolderStatus], scannedAt: Int64, fileOrder: [String]) {
    self.titles = titles
    self.files = files
    self.folderStatus = folderStatus
    self.scannedAt = scannedAt
    self.fileOrder = fileOrder
  }

  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    titles = c.lenientArray(.titles)
    files = c.lenientDict(.files)
    folderStatus = c.lenientDict(.folderStatus)
    scannedAt = (try? c.decodeIfPresent(Int64.self, forKey: .scannedAt)) ?? 0
    fileOrder = (try? c.decodeIfPresent([String].self, forKey: .fileOrder)) ?? []
  }

  /// Every file once, in scan order (any the order misses last, by id).
  var orderedFiles: [LibraryFile] {
    var seen = Set<String>()
    var out: [LibraryFile] = []
    out.reserveCapacity(files.count)
    for id in fileOrder where !seen.contains(id) {
      seen.insert(id)
      if let f = files[id] { out.append(f) }
    }
    if out.count < files.count {
      out += files.filter { !seen.contains($0.key) }.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }.map(\.value)
    }
    return out
  }
}

// ---- Settings and folders (config.json) ------------------------------------------

struct Folder: Codable, Equatable {
  var id: String
  var path: String
  /// "auto", "shows" or "movies".
  var kind: String
  var addedAt: Int64
}

struct Settings: Codable, Equatable {
  var autoSkipIntro = false
  var autoplayNext = true
  var analysis = true
  var nextCountdown = 10
  var subtitleLanguage = Settings.systemLanguage
  var autoFetchSubtitles = true
  var previews = true

  init() {}

  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    let base = Settings()
    autoSkipIntro = (try? c.decodeIfPresent(Bool.self, forKey: .autoSkipIntro)) ?? base.autoSkipIntro
    autoplayNext = (try? c.decodeIfPresent(Bool.self, forKey: .autoplayNext)) ?? base.autoplayNext
    analysis = (try? c.decodeIfPresent(Bool.self, forKey: .analysis)) ?? base.analysis
    if let n = try? c.decodeIfPresent(Double.self, forKey: .nextCountdown) {
      nextCountdown = Int(max(0, min(60, jsRound(n))))
    }
    subtitleLanguage = (try? c.decodeIfPresent(String.self, forKey: .subtitleLanguage)) ?? base.subtitleLanguage
    autoFetchSubtitles = (try? c.decodeIfPresent(Bool.self, forKey: .autoFetchSubtitles)) ?? base.autoFetchSubtitles
    previews = (try? c.decodeIfPresent(Bool.self, forKey: .previews)) ?? base.previews
  }

  /// Subtitle language to search for first: the Mac's language (OpenSubtitles codes).
  static let systemLanguage: String = {
    let loc = Locale.current
    let lang = loc.language.languageCode?.identifier ?? "en"
    let region = loc.region?.identifier ?? ""
    if lang == "pt" { return region == "BR" ? "pt-BR" : "pt-PT" }
    if lang == "zh" { return ["TW", "HK", "MO"].contains(region) ? "zh-TW" : "zh-CN" }
    return languageCodeRe.test(lang) ? lang : "en"
  }()
}

/// A subtitle language code as OpenSubtitles writes them: "en", "pt-BR".
let languageCodeRe = Re("^[a-z]{2,3}(?:-[a-z]{2})?$", "i")

struct Config: Codable {
  var folders: [Folder] = []
  var settings = Settings()

  init() {}
  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    folders = c.lenientArray(.folders)
    settings = (try? c.decodeIfPresent(Settings.self, forKey: .settings)) ?? Settings()
  }
}

// ---- Watch progress (progress.json) ----------------------------------------------

struct ProgressEntry: Codable, Equatable {
  var position: Double
  var duration: Double
  var updatedAt: Int64
  var watched: Bool
}

struct ProgressData: Codable {
  var files: [String: ProgressEntry] = [:]
  /// Titles taken off the Watching list, with the time.
  var hidden: [String: Int64] = [:]

  init() {}
  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    files = c.lenientDict(.files)
    hidden = c.lenientDict(.hidden)
  }
}

// ---- Probe cache (probe.json) ------------------------------------------------------

struct ProbeInfo: Codable, Equatable {
  struct Video: Codable, Equatable {
    var codec: String?
    var profile: String
    var pixFmt: String
    var width: Int?
    var height: Int?
  }
  struct Audio: Codable, Equatable {
    var index: Int
    var codec: String?
    var channels: Int?
    var lang: String
    var title: String
    var `default`: Bool
  }
  struct Sub: Codable, Equatable {
    var index: Int
    var codec: String?
    var lang: String
    var title: String
    var forced: Bool
  }
  var duration: Double
  var format: String
  var video: Video?
  var audio: [Audio]
  var subs: [Sub]
}

struct ProbeEntry: Codable {
  var sig: String
  var v: Int
  var info: ProbeInfo
}

struct ProbeData: Codable {
  var files: [String: ProbeEntry] = [:]

  init() {}
  init(from d: Decoder) throws {
    files = try d.container(keyedBy: CodingKeys.self).lenientDict(.files)
  }
}

// ---- Intro and credits (analysis.json) ----------------------------------------------

struct Span: Codable, Equatable {
  var start: Double
  var end: Double
}

struct Mark: Codable, Equatable {
  var start: Double
}

struct AnalysisEntry: Codable, Equatable {
  var v: Int
  var basis: String
  var at: Int64
  var intro: Span?
  var credits: Mark?
  var method: [String: String]?
  var error: String?
}

/// A manual correction: not set, set to "none", or set to a value.
enum Override<T: Codable & Equatable>: Equatable {
  case unset
  case cleared
  case set(T)

  var isSet: Bool { self != .unset }
}

struct ManualEntry: Codable, Equatable {
  var intro: Override<Span> = .unset
  var credits: Override<Mark> = .unset

  init() {}

  private enum K: String, CodingKey { case intro, credits }

  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: K.self)
    func read<T: Codable>(_ key: K) throws -> Override<T> {
      guard c.contains(key) else { return .unset }
      return try c.decodeNil(forKey: key) ? .cleared : .set(try c.decode(T.self, forKey: key))
    }
    intro = try read(.intro)
    credits = try read(.credits)
  }

  func encode(to e: Encoder) throws {
    var c = e.container(keyedBy: K.self)
    func write<T: Codable>(_ v: Override<T>, _ key: K) throws {
      switch v {
      case .unset: break
      case .cleared: try c.encodeNil(forKey: key)
      case .set(let x): try c.encode(x, forKey: key)
      }
    }
    try write(intro, .intro)
    try write(credits, .credits)
  }
}

struct AnalysisData: Codable {
  var version: Int
  var files: [String: AnalysisEntry] = [:]
  var manual: [String: ManualEntry] = [:]

  init(version: Int) { self.version = version }
  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
    files = c.lenientDict(.files)
    manual = c.lenientDict(.manual)
  }
}

/// What the player and pages show for one file.
struct Markers: Equatable {
  var intro: Span?
  var credits: Mark?
  var manual: Bool
  var method: [String: String]
  /// "done", "queued" or "none".
  var state: String
}

// ---- OpenSubtitles (opensubtitles.json, owner-only) -----------------------------------

struct OSUser: Codable, Equatable {
  var level: String
  var allowedDownloads: Double?
  var vip: Bool
}

struct OSQuota: Codable, Equatable {
  var remaining: Double?
  var resetAt: String?
}

struct OSShow: Codable, Equatable {
  var id: Int
  var title: String
  var year: Int?
  var count: Int
  var type: String
}

struct OSShowCache: Codable {
  var at: Int64
  var show: OSShow?
}

struct OSStoreData: Codable {
  var apiKey: String?
  var token: String?
  var tokenExp: Double?
  var username: String?
  var baseUrl: String?
  var user: OSUser?
  var quota: OSQuota?
  var shows: [String: OSShowCache] = [:]

  init() {}
  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    apiKey = try? c.decodeIfPresent(String.self, forKey: .apiKey)
    token = try? c.decodeIfPresent(String.self, forKey: .token)
    tokenExp = try? c.decodeIfPresent(Double.self, forKey: .tokenExp)
    username = try? c.decodeIfPresent(String.self, forKey: .username)
    baseUrl = try? c.decodeIfPresent(String.self, forKey: .baseUrl)
    user = try? c.decodeIfPresent(OSUser.self, forKey: .user)
    quota = try? c.decodeIfPresent(OSQuota.self, forKey: .quota)
    shows = c.lenientDict(.shows)
  }
}

// ---- Downloaded subtitles (subs-downloaded.json) ----------------------------------------

struct DownloadedSub: Codable, Equatable {
  var n: Int
  var provider: String
  var osFileId: Int
  var subtitleId: String
  var lang: String
  var release: String
  var hashMatch: Bool
  var hearingImpaired: Bool
  var at: Int64
}

struct DownloadedIndex: Codable {
  var files: [String: [DownloadedSub]] = [:]
  /// The last number given out; never reused.
  var seq: Int?

  init() {}
  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    files = c.lenientDict(.files)
    seq = try? c.decodeIfPresent(Int.self, forKey: .seq)
  }
}

// ---- Subtitle timing fixes (subsync.json) -------------------------------------------------

struct SyncEntry: Codable, Equatable {
  var offset: Double
  var scale: Double
  var z: Double?
  /// Infinity (no other offset came close) is stored as null, as JSON has no Infinity.
  var ratio: Double?
  var sig: String
  var at: Int64
}

struct SyncData: Codable {
  var tracks: [String: SyncEntry] = [:]

  init() {}
  init(from d: Decoder) throws {
    tracks = try d.container(keyedBy: CodingKeys.self).lenientDict(.tracks)
  }
}

/// A timing correction: cue time t belongs at t * scale + offset.
struct SubTiming: Equatable {
  var offset: Double
  var scale: Double
}

// ---- Preview sheets (trickplay/<id>-<sig>/index.json) ----------------------------------------

struct TrickplayManifest: Codable, Equatable {
  var v: Int
  var fileId: String
  var key: String
  var interval: Double
  var width: Double
  var height: Double
  var cols: Int
  var rows: Int
  var sheets: Int
  var count: Int
  var bytes: Int64
}

// ---- Lenient decoding -----------------------------------------------------------------------

/// Decodes a value, or nil if this one entry is unreadable (the rest still load).
private struct Lenient<T: Decodable>: Decodable {
  let value: T?
  init(from d: Decoder) throws { value = try? T(from: d) }
}

extension KeyedDecodingContainer {
  func lenientDict<V: Decodable>(_ key: Key) -> [String: V] {
    guard let raw = try? decodeIfPresent([String: Lenient<V>].self, forKey: key) else { return [:] }
    return raw.compactMapValues { $0.value }
  }

  func lenientArray<V: Decodable>(_ key: Key) -> [V] {
    guard let raw = try? decodeIfPresent([Lenient<V>].self, forKey: key) else { return [] }
    return raw.compactMap { $0.value }
  }
}
