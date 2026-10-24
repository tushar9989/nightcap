import Foundation

// Subtitles found online for library videos: search, download, and keep them
// with the app's data (never written into the media folders). Subtitles made
// on this Mac (MadeSubs) are kept with them, as provider "nightcap".
//
// On disk (DATA_DIR):
//   opensubtitles.json            API key, sign-in token, quota, show ids (owner-only file)
//   subs-downloaded.json          which subtitles were downloaded or made for which video
//   subs-downloaded/<fileId>/<n>.vtt

/// What a subtitle search found, best first, and the query it ran.
struct SubtitleSearch {
  var query: String
  var results: [SubtitleResult]
}

/// What an automatic fetch got: the track (nil when nothing suitable was
/// found), and whether it was downloaded just now.
struct AutoSubtitle {
  var track: SubtitleTrack?
  var fresh = false
}

@MainActor
final class OnlineSubs {
  nonisolated static let searchCacheMs: Int64 = 60 * 60_000
  nonisolated static let noneFoundMs: Int64 = 12 * 60 * 60_000
  nonisolated static let langRe = Re("^[a-z]{2,3}(?:-[a-z]{2})?$", "i")

  let getTitle: (String) -> Title?
  let media: Media
  let os = OpenSubtitles(store: JsonStore(Paths.data("opensubtitles.json"), defaults: OSStoreData(), mode: 0o600))
  let index = JsonStore(Paths.data("subs-downloaded.json"), defaults: DownloadedIndex())
  private let dir = ensureDir(Paths.data("subs-downloaded"))
  /// sigHash -> moviehash (nil when the file couldn't be read).
  private var hashes: [String: String?] = [:]
  private var fps: [String: Double?] = [:]
  private var searches: [JSKey: (at: Int64, value: SubtitleSearch)] = [:]
  /// fileId|lang -> when a search found nothing to fetch.
  private var noneFound: [JSKey: Int64] = [:]
  private var inflight: [JSKey: Task<AutoSubtitle, Error>] = [:]

  init(getTitle: @escaping (String) -> Title?, media: Media) {
    self.getTitle = getTitle
    self.media = media
  }

  func flush() {
    os.store.flush()
    index.flush()
  }

  func status() -> OpenSubtitles.Status { os.status() }

  // ---- Downloaded tracks ----------------------------------------------------------

  func entries(_ fileId: String) -> [DownloadedSub] { index.data.files[fileId] ?? [] }

  func list(_ fileId: String) -> [SubtitleTrack] {
    var seen: [JSKey: Int] = [:]
    return entries(fileId).map { e in
      let made = e.provider == OnlineSubs.madeHere
      let name = "\(languageName(e.lang)) · \(made ? "Made on this Mac" : "OpenSubtitles")"
      let count = (seen[JSKey(name)] ?? 0) + 1
      seen[JSKey(name)] = count
      return SubtitleTrack(
        id: "d\(e.n)", label: "\(name)\(count > 1 ? " \(count)" : "")", source: made ? "made" : "online", lang: e.lang,
        release: e.release, hashMatch: e.hashMatch)
    }
  }

  /// The provider of subtitles made on this Mac.
  nonisolated static let madeHere = "nightcap"

  func isMade(_ fileId: String, _ n: Int) -> Bool {
    entries(fileId).contains { $0.n == n && $0.provider == OnlineSubs.madeHere }
  }

  func vtt(_ fileId: String, _ n: Int) -> String? {
    guard entries(fileId).contains(where: { $0.n == n }),
      let data = FileManager.default.contents(atPath: join(dir, fileId, "\(n).vtt"))
    else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// Writes a kept track's text anew (a line fixed in a made track).
  func replaceVtt(_ fileId: String, _ n: Int, _ vtt: String) throws {
    guard entries(fileId).contains(where: { $0.n == n }) else { throw EngineError("No such subtitle track", 404) }
    do {
      try Data(vtt.utf8).write(to: URL(fileURLWithPath: join(dir, fileId, "\(n).vtt")), options: .atomic)
    } catch {
      throw EngineError("Could not save the subtitle in \(join(dir, fileId))", 500)
    }
  }

  @discardableResult
  func remove(_ fileId: String, _ n: Int) -> Bool {
    var list = entries(fileId)
    guard let i = list.firstIndex(where: { $0.n == n }) else { return false }
    list.remove(at: i)
    index.data.files[fileId] = list.isEmpty ? nil : list
    index.save()
    removeItem(join(dir, fileId, "\(n).vtt"))
    return true
  }

  // ---- Search ---------------------------------------------------------------------

  func hashOf(_ file: LibraryFile) async -> String? {
    let key = sigHash(file)
    if let hit = hashes[key] { return hit }
    let (path, size) = (file.path, file.size)
    let hash = await Task.detached { try? OpenSubtitles.movieHash(path, size: size) }.value
    hashes[key] = .some(hash)
    return hash
  }

  func fpsOf(_ file: LibraryFile) async -> Double? {
    if let hit = fps[file.id] { return hit }
    guard let ffprobe = Tools.ffprobe else { return nil }
    let r = try? await runTool(
      ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=avg_frame_rate,r_frame_rate", "-of", "json", file.path],
      timeout: 20)
    let rate = r.flatMap { OnlineSubs.frameRate(JSON.parse(String(decoding: $0.stdout, as: UTF8.self))) }
    fps[file.id] = .some(rate)
    return rate
  }

  /// The first video stream's frames per second (to 3 places) in ffprobe's
  /// answer; nil where JavaScript threw or found no denominator.
  nonisolated static func frameRate(_ probe: Any?) -> Double? {
    // JSON.parse(...).streams[0]: a missing or empty list threw.
    guard let streams = JSON.get(probe, "streams") as? [Any], let s = streams.first, !(s is NSNull) else { return nil }
    // A non-object first stream has no rates: String(undefined) gives no fraction.
    let avg = JSON.get(s, "avg_frame_rate")
    let chosen = (avg as? String).map { $0.jsEquals("0/0") } == true ? JSON.get(s, "r_frame_rate") : avg
    let parts = (JSON.string(chosen) ?? "undefined").jsSplit("/")
    let a = jsNumberValue(parts[0])
    guard parts.count > 1 else { return nil }
    let b = jsNumberValue(parts[1])
    guard b != 0, !b.isNaN else { return nil }
    return jsRound((a / b) * 1000) / 1000
  }

  func describe(_ file: LibraryFile) -> (title: Title?, episode: (season: Int, episode: Int)?) {
    let title = getTitle(file.titleId)
    let season = title.flatMap { file.season >= 0 && file.season < $0.seasons.count ? $0.seasons[file.season] : nil }
    if title?.kind == "show", let season, !season.isExtras, let s = season.number, let e = file.number {
      return (title, (s, e))
    }
    return (title, nil)
  }

  private static func stem(_ file: LibraryFile) -> String { Scanner.stemOf(basename(file.path)) }
  private static func pad(_ n: Int) -> String { String(n).padStart(2, "0") }

  /// What the search box starts with.
  func defaultQuery(_ file: LibraryFile) -> String {
    let (title, episode) = describe(file)
    guard let title else { return OnlineSubs.stem(file) }
    if let episode { return "\(title.name) S\(OnlineSubs.pad(episode.season))E\(OnlineSubs.pad(episode.episode))" }
    if title.kind == "movie" { return "\(title.name)\(title.year.map { $0 != 0 ? " \($0)" : "" } ?? "")" }
    return OnlineSubs.stem(file)
  }

  func search(_ file: LibraryFile, language: String?, query: String? = nil) async throws -> SubtitleSearch {
    guard let language, OnlineSubs.langRe.test(language) else { throw OSError("Pick a subtitle language", 400) }
    let lang = language.jsLowercased
    let q = (query ?? "").jsTrimmed.jsSlice(0, 200)
    let custom = !q.isEmpty && !q.jsEquals(defaultQuery(file))
    let cacheKey = JSKey("\(file.id)|\(lang)|\(custom ? q : "")")
    if let hit = searches[cacheKey], nowMs() - hit.at < OnlineSubs.searchCacheMs { return hit.value }

    async let hashed = hashOf(file)
    async let rate = fpsOf(file)
    let (hash, fps) = await (hashed, rate)
    let (title, episode) = describe(file)
    let base: [String: String?] = ["languages": lang, "moviehash": hash]
    func with(_ extra: [String: String?]) -> [String: String?] { base.merging(extra) { $1 } }
    var attempts: [[String: String?]] = []
    if custom {
      attempts.append(with(["query": q]))
    } else if let title, let episode {
      let show = try? await os.findShow(title.name, year: title.year)
      if let show {
        attempts.append(with([
          "parent_feature_id": String(show.id), "season_number": String(episode.season), "episode_number": String(episode.episode),
        ]))
      } else {
        attempts.append(with([
          "query": title.name, "season_number": String(episode.season), "episode_number": String(episode.episode), "type": "episode",
        ]))
      }
    } else if let title, title.kind == "movie" {
      attempts.append(with(["query": title.name, "year": title.year.map { String($0) }, "type": "movie"]))
    }
    // Fall back to the exact file alone, then to what the file name says.
    if let hash, !hash.isEmpty { attempts.append(["moviehash": hash, "languages": lang]) }
    attempts.append(with(["query": OnlineSubs.stem(file)]))

    var results: [SubtitleResult] = []
    for params in attempts {
      results = try await os.search(params)
      if !results.isEmpty { break }
    }
    let value = SubtitleSearch(
      query: custom ? q : defaultQuery(file),
      results: OpenSubtitles.rankResults(results.filter { $0.language.jsLowercased.jsEquals(lang) || $0.language.isEmpty }, fps: fps))
    searches[cacheKey] = (nowMs(), value)
    return value
  }

  // ---- Download -------------------------------------------------------------------

  func fetch(_ file: LibraryFile, _ pick: SubtitleResult) async throws -> SubtitleTrack? {
    guard let id = Int(exactly: pick.id), id > 0 else { throw OSError("Unknown subtitle", 400) }
    if let existing = entries(file.id).first(where: { $0.osFileId == id }) {
      return list(file.id).first { $0.id == "d\(existing.n)" }
    }

    let got = try await os.download(id)
    guard let vtt = await media.textToVtt(got.text, ext: extname(got.fileName).jsLowercased), vtt.jsIncludes("-->") else {
      throw OSError("The downloaded subtitle could not be read", 502)
    }
    let lang = OnlineSubs.langRe.test(pick.language) ? pick.language : "und"
    let n = try store(file, vtt, DownloadedSub(
      n: 0, provider: "opensubtitles", osFileId: id, subtitleId: pick.subtitleId.jsSlice(0, 40), lang: lang,
      release: (pick.release.isEmpty ? got.fileName : pick.release).jsSlice(0, 300), hashMatch: pick.hashMatch,
      hearingImpaired: pick.hearingImpaired, at: nowMs()))
    noneFound[JSKey("\(file.id)|\(lang.jsLowercased)")] = nil
    return self.list(file.id).first { $0.id == "d\(n)" }
  }

  /// Keeps English subtitles made on this Mac from audio track `audio`;
  /// `namesFrom` names where its expected names came from (credited).
  func addMade(_ file: LibraryFile, _ vtt: String, audio: Int, namesFrom: String? = nil) throws -> SubtitleTrack? {
    let n = try store(file, vtt, DownloadedSub(
      n: 0, provider: OnlineSubs.madeHere, osFileId: 0, subtitleId: "", lang: "en",
      release: "Made on this Mac from audio track \(audio + 1)\(namesFrom.map { ", names from \($0)" } ?? "")", hashMatch: true,
      hearingImpaired: false, at: nowMs()))
    return list(file.id).first { $0.id == "d\(n)" }
  }

  /// Saves a track for `file` under the next number (set in `entry` here); the number.
  private func store(_ file: LibraryFile, _ vtt: String, _ entry: DownloadedSub) throws -> Int {
    let list = entries(file.id)
    // Never reused, so timing fixes and remembered delays can't attach to another file.
    let n = max(index.data.seq ?? 0, list.map(\.n).max() ?? .min) + 1
    index.data.seq = n
    let folder = ensureDir(join(dir, file.id))
    guard FileManager.default.createFile(atPath: join(folder, "\(n).vtt"), contents: Data(vtt.utf8)) else {
      // Not an OpenSubtitles failure (those answer 502).
      throw EngineError("Could not save the subtitle in \(folder)", 500)
    }
    var entry = entry
    entry.n = n
    index.data.files[file.id, default: []].append(entry)
    index.save()
    return n
  }

  /// Fetches the best subtitle in `language` unless the video already has one.
  /// Used when someone watches with subtitles on and the episode has none.
  func auto(_ file: LibraryFile, language: String) async throws -> AutoSubtitle {
    let lang = language.jsLowercased
    let key = JSKey("\(file.id)|\(lang)")
    if let running = inflight[key] { return try await running.value }
    let task = Task { () throws -> AutoSubtitle in
      defer { inflight[key] = nil }
      if let have = list(file.id).first(where: { ($0.lang ?? "").jsLowercased.jsEquals(lang) }) { return AutoSubtitle(track: have) }
      if let missed = noneFound[key], nowMs() - missed < OnlineSubs.noneFoundMs { return AutoSubtitle(track: nil) }
      // Out of downloads until the allowance resets: don't search for nothing.
      if os.status().remaining == 0 {
        throw OSError("No subtitle downloads left today. Sign in to OpenSubtitles in Settings for more.", 429)
      }
      let results = try await search(file, language: language).results
      guard let pick = results.first(where: { !$0.foreignOnly && !$0.machineTranslated }) else {
        noneFound[key] = nowMs()
        return AutoSubtitle(track: nil)
      }
      return AutoSubtitle(track: try await fetch(file, pick), fresh: true)
    }
    inflight[key] = task
    return try await task.value
  }
}
