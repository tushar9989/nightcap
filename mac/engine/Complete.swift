import Foundation

// Whether a video has finished arriving. A video still downloading (in order
// while it is watched, or in pieces) gets no previews, pictures or intro and
// credits detection until it is complete: made from part of a file they would
// be wrong (credits found where the download stopped), and made again each
// time it grew. Playing it is not affected.
//
// Complete means: unchanged for `quietMs`, packets near the end of its
// duration (a file cut short has none: it is still growing, or its end was
// never written), and no stretch of zeros in its body (the parts of a file a
// download set aside but hasn't filled). The result is kept for that version
// of the file (its path, size and modification time) in the cache.

struct CompleteEntry: Codable, Equatable {
  var ok: Bool
  var at: Int64
}

struct CompleteData: Codable {
  var files: [String: CompleteEntry] = [:]

  init() {}
  init(from d: Decoder) throws {
    files = try d.container(keyedBy: CodingKeys.self).lenientDict(.files)
  }
}

@MainActor
final class Completeness {
  static let quietMs: Int64 = 5 * 60_000
  /// Places in the body looked at for zeros (fractions of the size), and how much at each.
  nonisolated static let windows = (2...9).map { Double($0) / 10 }
  nonisolated static let windowBytes = 16_384

  let store: JsonStore<CompleteData>
  private var checking: Set<String> = []
  /// Two files looked at a time (the first run looks at the whole library).
  private let limit = Limiter(2)
  private var wake: Task<Void, Never>?
  private var wakeAt: Int64 = .max
  /// Called when a file is found complete or not, or when a file's quiet time is up.
  var onChange: (() -> Void)?
  /// Called when a file changed since the library was scanned: a scan brings its size and time up to date.
  var onStale: (() -> Void)?

  init(store: JsonStore<CompleteData> = JsonStore(Paths.cache("complete.json"), defaults: CompleteData())) {
    self.store = store
  }

  func flush() { store.flush() }

  enum State {
    case complete
    /// Changing, changed lately, not complete, or not there.
    case arriving
    /// Quiet, and being looked at (`onChange` follows): the first time the
    /// library is seen, every video is, for a few seconds each.
    case checking
  }

  func state(_ f: LibraryFile) -> State {
    var st = stat()
    guard stat(f.path, &st) == 0 else { return .arriving }
    let mtime = Scanner.mtimeMs(st)
    if Int64(st.st_size) != f.size || mtime != f.mtime {
      onStale?()
      return .arriving
    }
    let now = nowMs()
    // (A time ahead of the clock is taken as quiet.)
    if mtime <= now && now - mtime < Completeness.quietMs {
      wakeUp(at: mtime + Completeness.quietMs)
      return .arriving
    }
    let key = sigHash(f)
    if let e = store.data.files[key] { return e.ok ? .complete : .arriving }
    check(f, key)
    return .checking
  }

  /// True when `f` has finished arriving.
  func isComplete(_ f: LibraryFile) -> Bool { state(f) == .complete }

  /// Keeps the results of these file versions (sigHash) only.
  func prune(keeping keys: Set<String>) {
    let before = store.data.files.count
    store.data.files = store.data.files.filter { keys.contains($0.key) }
    if store.data.files.count != before { store.save() }
  }

  private func wakeUp(at t: Int64) {
    guard t < wakeAt else { return }
    wakeAt = t
    wake?.cancel()
    wake = Task { [weak self] in
      await sleep(seconds: Double(max(0, t - nowMs())) / 1000 + 1)
      guard !Task.isCancelled, let self else { return }
      self.wakeAt = .max
      self.wake = nil
      self.onChange?()
    }
  }

  private func check(_ f: LibraryFile, _ key: String) {
    guard !checking.contains(key) else { return }
    checking.insert(key)
    let path = f.path, size = f.size
    let ffprobe = Tools.ffprobe
    Task {
      let ok = await limit.run {
        await Task.detached(priority: .utility) { await Completeness.looksComplete(path, size: size, ffprobe: ffprobe) }.value
      }
      checking.remove(key)
      store.data.files[key] = CompleteEntry(ok: ok, at: nowMs())
      store.save()
      if !ok { logLine("[complete] not complete yet: \(path)") }
      onChange?()
    }
  }

  // ---- The checks -----------------------------------------------------------------------------

  /// No zeros in the body, and packets near the end.
  nonisolated static func looksComplete(_ path: String, size: Int64, ffprobe: String?) async -> Bool {
    guard size > 0, let zeros = zeroWindows(path, size: size), zeros == 0 else { return false }
    guard let ffprobe else { return true }  // nothing more to tell by (nothing is made without ffmpeg anyway)
    return await reachesEnd(path, ffprobe: ffprobe)
  }

  /// How many of the places looked at are all zeros (nil when the file can't be read).
  nonisolated static func zeroWindows(_ path: String, size: Int64) -> Int? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    var zeros = 0
    for w in windows {
      let at = UInt64(Double(size) * w)
      guard (try? h.seek(toOffset: at)) != nil, let data = try? h.read(upToCount: windowBytes) else { return nil }
      if !data.isEmpty && !data.contains(where: { $0 != 0 }) { zeros += 1 }
    }
    return zeros
  }

  /// Whether reading from 97 % of the way in finds packets there (the seek
  /// lands on a keyframe before it: up to 30 s, or a fifth of a short video).
  nonisolated static func reachesEnd(_ path: String, ffprobe: String) async -> Bool {
    guard let r = try? await runTool(ffprobe, ["-v", "error", "-show_entries", "format=duration,start_time", "-of", "json", path], timeout: 60, background: true),
      r.code == 0, let j = JSON.parse(String(decoding: r.stdout, as: UTF8.self)) as? [String: Any],
      let format = j["format"] as? [String: Any],
      let duration = (format["duration"] as? String).flatMap(Double.init), duration > 0
    else { return false }
    let start = (format["start_time"] as? String).flatMap(Double.init) ?? 0
    let from = start + duration * 0.97
    guard let p = try? await runTool(ffprobe, [
      "-v", "error", "-read_intervals", "\(toFixed(from, 3))%+#20", "-show_entries", "packet=pts_time", "-of", "csv=p=0", path,
    ], timeout: 60, background: true), p.code == 0
    else { return false }
    let times = String(decoding: p.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
      .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) }
    guard let last = times.max() else { return false }
    return last >= from - min(30, duration * 0.2)
  }
}
