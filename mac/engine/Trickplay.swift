import Foundation

// Preview thumbnails ("trickplay"): a frame every few seconds, tiled into JPEG
// sheets, for the seek bar and the episode previews. Only keyframes are
// decoded, so a 45-minute episode takes about a second.
//
// On disk: DATA_DIR/trickplay/<fileId>-<sigHash>/{index.json, sheet-<n>.jpg}

@MainActor
final class Trickplay {
  static let version = 1
  static let width = 240
  static let cols = 10
  static let rows = 10
  static let retryFailedMs: Int64 = 6 * 3600 * 1000

  let dir = ensureDir(Paths.data("trickplay"))
  private let getLibrary: () -> Library
  private let media: Media
  private let isEnabled: () -> Bool
  /// Called when previews are made or the queue changes.
  var onChange: (() -> Void)?

  private var ready: [String: TrickplayManifest] = [:]  // fileId -> manifest
  private var failed: [String: Int64] = [:]  // "<id>-<sig>" -> time
  private(set) var queue: [String] = []  // fileIds, next first
  private(set) var current: String?

  init(getLibrary: @escaping () -> Library, media: Media, isEnabled: @escaping () -> Bool) {
    self.getLibrary = getLibrary
    self.media = media
    self.isEnabled = isEnabled
    loadIndex()
  }

  /// Seconds between thumbnails: finer for short videos.
  static func interval(for duration: Double) -> Double { duration <= 600 ? 2 : duration <= 3600 ? 5 : 10 }

  /// Width and height from a JPEG's start-of-frame marker.
  static func jpegSize(_ data: Data) -> (width: Int, height: Int)? {
    let b = [UInt8](data)
    func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    var i = 2
    while i + 9 < b.count {
      if b[i] != 0xff { return nil }
      let marker = b[i + 1]
      let len = u16(i + 2)
      if marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].contains(marker) {
        return (u16(i + 7), u16(i + 5))
      }
      i += 2 + len
    }
    return nil
  }

  private func loadIndex() {
    // Names in the order Node listed them, so a later duplicate wins as it did.
    for (name, _) in Scanner.readdir(dir) ?? [] {
      guard let raw = FileManager.default.contents(atPath: join(dir, name, "index.json")),
        let m = decodeJSONFile(TrickplayManifest.self, from: raw), m.v == Trickplay.version
      else { continue }
      ready[m.fileId] = m
    }
  }

  func manifest(_ f: LibraryFile) -> TrickplayManifest? {
    guard let m = ready[f.id], m.key == sigHash(f) else { return nil }
    return m
  }

  func sheetPath(_ f: LibraryFile, _ n: Int) -> String? {
    guard let m = manifest(f), n >= 0, n < m.sheets else { return nil }
    return join(dir, "\(f.id)-\(m.key)", "sheet-\(n).jpg")
  }

  /// "ready", "working", "queued", "failed" or "none".
  func state(_ f: LibraryFile) -> String {
    if manifest(f) != nil { return "ready" }
    if current == f.id { return "working" }
    if queue.contains(f.id) { return "queued" }
    return failed["\(f.id)-\(sigHash(f))"] != nil ? "failed" : "none"
  }

  /// Every episode and movie (not extras), recently added titles first.
  func wanted() -> [String] {
    let lib = getLibrary()
    var ids: [String] = []
    for t in lib.titles.stableSorted(by: { numCompare($1.addedAt, $0.addedAt) }) {
      for s in t.seasons where !s.isExtras { ids += s.episodes }
    }
    return ids.filter { lib.files[$0] != nil }
  }

  func sync() {
    let lib = getLibrary()
    if isEnabled() {
      let queued = Set(queue)
      for id in wanted() {
        let f = lib.files[id]!
        if !queued.contains(id) && current != id && manifest(f) == nil && !recentlyFailed(f) { queue.append(id) }
      }
    }
    if lib.folderStatus.values.allSatisfy(\.online) { cleanup() }
    kick()
  }

  private func recentlyFailed(_ f: LibraryFile) -> Bool {
    guard let at = failed["\(f.id)-\(sigHash(f))"] else { return false }
    return nowMs() - at < Trickplay.retryFailedMs
  }

  /// Put these files at the front of the queue, in this order.
  func prioritize(_ fileIds: [String]) {
    guard isEnabled() else { return }
    let files = getLibrary().files
    let ids = fileIds.filter { id in
      guard let f = files[id] else { return false }
      return manifest(f) == nil && current != id && !recentlyFailed(f)
    }
    queue = ids + queue.filter { !ids.contains($0) }
    kick()
  }

  func kick() {
    guard current == nil, Tools.ffmpeg != nil, isEnabled() else { return }
    let files = getLibrary().files
    var next: String?
    while !queue.isEmpty {
      let id = queue.removeFirst()
      if let f = files[id], manifest(f) == nil {
        next = id
        break
      }
    }
    guard let id = next, let f = files[id] else { return }
    current = id
    onChange?()
    Task {
      do {
        _ = try await generate(f)
      } catch {
        failed["\(id)-\(sigHash(f))"] = nowMs()
        logLine("[previews] \(f.name): \((error as? Failure)?.message ?? error.localizedDescription)")
      }
      current = nil
      onChange?()
      DispatchQueue.main.async { [weak self] in self?.kick() }
    }
  }

  struct Failure: Error { let message: String }

  nonisolated private static let sheetName = Re(#"^sheet-\d+\.jpg$"#)

  func generate(_ f: LibraryFile) async throws -> TrickplayManifest {
    guard let ffmpeg = Tools.ffmpeg else { throw Failure(message: "ffmpeg is not installed") }
    let info = await media.probe(f)
    guard let info, info.video != nil, info.duration != 0 else { throw Failure(message: "no video to preview") }
    let key = sigHash(f)
    let interval = Trickplay.interval(for: info.duration)
    let final = join(dir, "\(f.id)-\(key)")
    let tmp = "\(final).tmp"
    let W = Trickplay.width, C = Trickplay.cols, R = Trickplay.rows
    let vf = "fps=1/\(jsNumber(interval)):round=near,scale=\(W):trunc(\(W)/dar/2)*2,setsar=1,tile=\(C)x\(R)"
    // The file work happens off the main thread.
    let (r, names) = try await Task.detached(priority: .utility) { () throws -> (RunResult, [String]) in
      removeItem(tmp)
      try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
      let r = try await runTool(ffmpeg, [
        "-nostdin", "-hide_banner", "-loglevel", "error", "-skip_frame", "nokey", "-i", f.path, "-map", "0:v:0", "-an", "-sn", "-dn",
        "-vf", vf, "-q:v", "6", "-start_number", "0", join(tmp, "sheet-%d.jpg"),
      ], timeout: 15 * 60, background: true)
      let names = (Scanner.readdir(tmp) ?? []).map(\.name).filter { Trickplay.sheetName.test($0) }
      return (r, names)
    }.value
    if r.code != 0 || names.isEmpty {
      removeItem(tmp)
      let last = r.lastErrorLine
      throw Failure(message: last.isEmpty ? "ffmpeg failed" : last)
    }
    guard let first = FileManager.default.contents(atPath: join(tmp, "sheet-0.jpg")), let size = Trickplay.jpegSize(first) else {
      throw Failure(message: "unreadable preview sheet")
    }
    var bytes: Int64 = 0
    for n in names {
      let attrs = try? FileManager.default.attributesOfItem(atPath: join(tmp, n))
      bytes += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
    let m = TrickplayManifest(
      v: Trickplay.version, fileId: f.id, key: key, interval: interval, width: Double(size.width) / Double(C),
      height: Double(size.height) / Double(R), cols: C, rows: R, sheets: names.count,
      count: min(names.count * C * R, Int((info.duration / interval).rounded(.down)) + 1), bytes: bytes)
    guard FileManager.default.createFile(atPath: join(tmp, "index.json"), contents: try jsonEncoder.encode(m)) else {
      throw Failure(message: "could not write the preview index")
    }
    removeItem(final)
    try FileManager.default.moveItem(atPath: tmp, toPath: final)
    ready[f.id] = m
    return m
  }

  struct Status: Equatable {
    var enabled: Bool
    var available: Bool
    var total: Int
    var done: Int
    var queued: Int
    var current: String?
    var bytes: Int64
  }

  func status() -> Status {
    let files = getLibrary().files
    let want = wanted()
    return Status(
      enabled: isEnabled(), available: Tools.ffmpeg != nil, total: want.count,
      done: want.filter { manifest(files[$0]!) != nil }.count, queued: queue.count,
      current: current.flatMap { files[$0]?.name }, bytes: ready.values.reduce(0) { $0 + $1.bytes })
  }

  /// Remove previews of videos that left the library or changed on disk.
  func cleanup() {
    let keep = Set(getLibrary().files.values.map { "\($0.id)-\(sigHash($0))" })
    for (name, _) in Scanner.readdir(dir) ?? [] {
      if keep.contains(name) || (current.map { name.jsStartsWith("\($0)-") } ?? false) { continue }
      removeItem(join(dir, name))
      let id = name.jsSplit("-")[0]
      if let m = ready[id], "\(id)-\(m.key)".jsEquals(name) { ready[id] = nil }
    }
  }
}
