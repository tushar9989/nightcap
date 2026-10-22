import Foundation

// Keeps the intro/credits index: decides what needs analysing, works through
// one season (or movie) at a time in the background, and stores the results.
//
// On disk (DATA_DIR):
//   analysis.json      markers per file, plus manual corrections
//   fingerprints/*.fp  audio fingerprints of each episode's first and last
//                      minutes, so adding an episode only fingerprints that
//                      episode and re-runs the (fast) matching for its season

@MainActor
final class Analyzer {
  static let version = 2  // bump to re-run matching (fingerprints are reused)
  let fpDir = ensureDir(Paths.data("fingerprints"))
  let store = JsonStore(Paths.data("analysis.json"), defaults: AnalysisData(version: Analyzer.version))
  private let getLibrary: () -> Library
  private let media: Media
  private let isEnabled: () -> Bool
  /// Called when results or progress change.
  var onChange: (() -> Void)?

  struct Group {
    var key: String
    var titleId: String
    var seasonId: String?
    var kind: String  // "show" or "movie"
    var label: String
    var fileIds: [String]
    var refs: [String]
    var priority: Double = 0
  }

  private(set) var queue: [Group] = []
  private(set) var current: (group: Group, done: Int, total: Int)?

  init(getLibrary: @escaping () -> Library, media: Media, isEnabled: @escaping () -> Bool) {
    self.getLibrary = getLibrary
    self.media = media
    self.isEnabled = isEnabled
  }

  func flush() { store.flush() }

  /// Each season of a show (and each movie) is analysed as one group, because
  /// episodes are compared with their neighbours in the same season.
  func groups(_ title: Title) -> [Group] {
    let lib = getLibrary()
    if title.kind == "movie" {
      return [Group(key: title.id, titleId: title.id, kind: "movie", label: title.name, fileIds: title.seasons.flatMap(\.episodes), refs: [])]
    }
    let regular = title.seasons.filter { !$0.isExtras }
    return regular.enumerated().map { i, s in
      var refs: [String] = []
      if s.episodes.count < 3 {
        // Too few episodes to compare within the season: borrow neighbours.
        let others = (i + 1 < regular.count ? regular[i + 1].episodes : []) + (i > 0 ? regular[i - 1].episodes : [])
        refs = Array(others.prefix(max(0, 4 - s.episodes.count))).filter { lib.files[$0] != nil }
      }
      return Group(
        key: "\(title.id):\(s.id)", titleId: title.id, seasonId: s.id, kind: "show", label: "\(title.name) · \(s.name)",
        fileIds: s.episodes, refs: refs)
    }
  }

  func basis(_ g: Group) -> String {
    let files = getLibrary().files
    return hashId((g.fileIds + ["|"] + g.refs).map { id in files[id].map { "\(id):\(fileSig($0))" } ?? id }.joined(separator: ","))
  }

  private func needsWork(_ g: Group) -> Bool {
    let b = basis(g)
    return g.fileIds.contains { id in
      guard let e = store.data.files[id] else { return true }
      return e.v != Analyzer.version || e.basis != b
    }
  }

  /// Queue everything that is new or changed. Recently added titles go first.
  func sync() {
    let lib = getLibrary()
    var wanted: [Group] = []
    for t in lib.titles.stableSorted(by: { numCompare($1.addedAt, $0.addedAt) }) {
      for g in groups(t) where needsWork(g) { wanted.append(g) }
    }
    var queued: [String: Group] = [:]
    for g in queue { queued[g.key] = g }
    queue = wanted.filter { $0.key != current?.group.key }.map { g in
      var g = g
      if let q = queued[g.key] { g.priority = q.priority }
      return g
    }
    queue.stableSort { numCompare($1.priority, $0.priority) }
    // An unplugged drive must not cost its index; only tidy up when every folder is reachable.
    if lib.folderStatus.values.allSatisfy(\.online) { cleanup(Set(lib.files.keys)) }
    kick()
  }

  /// Move a title (or one season of it) to the front of the queue.
  func prioritize(_ titleId: String, _ seasonId: String? = nil) {
    let now = Double(nowMs())
    for i in queue.indices where queue[i].titleId == titleId {
      queue[i].priority = now + (seasonId != nil && queue[i].seasonId == seasonId ? 1 : 0)
    }
    queue.stableSort { numCompare($1.priority, $0.priority) }
    kick()
  }

  func reanalyze(_ titleId: String) {
    guard let t = getLibrary().titles.first(where: { $0.id == titleId }) else { return }
    for g in groups(t) { for id in g.fileIds { store.data.files[id] = nil } }
    store.save()
    sync()
    prioritize(titleId)
  }

  func markers(_ fileId: String) -> Markers {
    let auto = store.data.files[fileId]
    let manual = store.data.manual[fileId] ?? ManualEntry()
    var intro = auto?.intro, credits = auto?.credits
    switch manual.intro {
    case .unset: break
    case .cleared: intro = nil
    case .set(let v): intro = v
    }
    switch manual.credits {
    case .unset: break
    case .cleared: credits = nil
    case .set(let v): credits = v
    }
    return Markers(
      intro: intro, credits: credits, manual: manual.intro.isSet || manual.credits.isSet, method: auto?.method ?? [:],
      state: auto != nil ? "done" : isQueued(fileId) ? "queued" : "none")
  }

  func isQueued(_ fileId: String) -> Bool {
    (current?.group.fileIds.contains(fileId) ?? false) || queue.contains { $0.fileIds.contains(fileId) }
  }

  /// Manual corrections win over detection and survive re-analysis.
  func setManual(_ fileId: String, intro: Override<Span>? = nil, credits: Override<Mark>? = nil, reset: Bool = false) {
    if reset {
      store.data.manual[fileId] = nil
    } else {
      var m = store.data.manual[fileId] ?? ManualEntry()
      if let intro { m.intro = intro }
      if let credits { m.credits = credits }
      store.data.manual[fileId] = m
    }
    store.save()
    onChange?()
  }

  struct Status: Equatable {
    var available: Bool
    var enabled: Bool
    var totalFiles: Int
    var analyzedFiles: Int
    var queuedGroups: Int
    var current: (label: String, done: Int, total: Int)?

    static func == (a: Status, b: Status) -> Bool {
      a.available == b.available && a.enabled == b.enabled && a.totalFiles == b.totalFiles && a.analyzedFiles == b.analyzedFiles
        && a.queuedGroups == b.queuedGroups && a.current?.label == b.current?.label && a.current?.done == b.current?.done
        && a.current?.total == b.current?.total
    }
  }

  func status() -> Status {
    var total = 0, done = 0
    for t in getLibrary().titles {
      for g in groups(t) {
        total += g.fileIds.count
        done += g.fileIds.filter { store.data.files[$0]?.v == Analyzer.version }.count
      }
    }
    return Status(
      available: Tools.ffmpeg != nil, enabled: isEnabled(), totalFiles: total, analyzedFiles: done, queuedGroups: queue.count,
      current: current.map { ($0.group.label, $0.done, $0.total) })
  }

  func kick() {
    guard current == nil, let ffmpeg = Tools.ffmpeg, isEnabled(), !queue.isEmpty else { return }
    let group = queue.removeFirst()
    current = (group, 0, group.fileIds.count)
    onChange?()
    Task { await work(group, ffmpeg) }
  }

  private func work(_ group: Group, _ ffmpeg: String) async {
    let lib = getLibrary()
    func describe(_ id: String) async -> AnalysisJob.File? {
      guard let f = lib.files[id] else { return nil }
      let info = await media.probe(f)
      return AnalysisJob.File(id: id, path: f.path, sig: sigHash(f), duration: info?.duration ?? 0)
    }
    var files: [AnalysisJob.File] = []
    for id in group.fileIds { if let d = await describe(id) { files.append(d) } }
    var refs: [AnalysisJob.File] = []
    for id in group.refs { if let d = await describe(id) { refs.append(d) } }
    let job = AnalysisJob(kind: group.kind, files: files, refs: refs, fpDir: fpDir, ffmpeg: ffmpeg)
    let key = group.key
    let results = await Task.detached(priority: .utility) {
      await job.run { done, total in
        Task { @MainActor [weak self] in
          guard let self, self.current?.group.key == key, done >= self.current?.done ?? 0 else { return }
          self.current?.done = done
          self.current?.total = total
          self.onChange?()
        }
      }
    }.value
    let b = basis(group)
    let at = nowMs()
    for (fid, r) in results {
      store.data.files[fid] = AnalysisEntry(v: Analyzer.version, basis: b, at: at, intro: r.intro, credits: r.credits, method: r.method, error: r.error)
    }
    store.save()
    let found = results.map(\.1)
    logLine("[analysis] \(group.label): intro in \(found.filter { $0.intro != nil }.count)/\(found.count), credits in \(found.filter { $0.credits != nil }.count)/\(found.count)")
    current = nil
    onChange?()
    DispatchQueue.main.async { [weak self] in self?.kick() }
  }

  /// Drop index entries and fingerprints for files that are no longer in the library.
  private func cleanup(_ valid: Set<String>) {
    var changed = false
    for id in store.data.files.keys where !valid.contains(id) {
      store.data.files[id] = nil
      changed = true
    }
    if changed { store.save() }
    let keep = Set(getLibrary().files.values.map { "\($0.id)-\(sigHash($0))" })
    let tail = Re(#"-(head|tail)\.fp$"#)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: fpDir)) ?? [] {
      let stem = tail.replace(name, "", global: false)
      if !keep.contains(stem) { removeItem(join(fpDir, name)) }
    }
  }
}

/// One season (or movie) to analyse, run off the main thread: fingerprints
/// the start and end of each episode, finds what repeats, and looks at the
/// picture for end credits.
struct AnalysisJob: Sendable {
  struct File: Sendable {
    var id: String
    var path: String
    var sig: String
    var duration: Double
  }

  struct Result {
    var intro: Span?
    var credits: Mark?
    var method: [String: String] = [:]
    var error: String?
  }

  var kind: String
  var files: [File]
  var refs: [File]
  var fpDir: String
  var ffmpeg: String

  static let intro: FP.MatchOptions = {
    var o = FP.MatchOptions()
    o.minFrames = FP.secToFrames(15)
    o.maxFrames = FP.secToFrames(150)
    return o
  }()
  static let credits: FP.MatchOptions = {
    var o = FP.MatchOptions()
    o.minFrames = FP.secToFrames(15)
    o.maxFrames = FP.secToFrames(600)
    return o
  }()

  struct Failure: Error { let message: String }

  /// Results in the order of `files`.
  func run(progress: @escaping @Sendable (Int, Int) -> Void) async -> [(String, Result)] {
    kind == "movie" ? await movieJob(progress) : await showJob(progress)
  }

  static func headWindow(_ dur: Double) -> (start: Double, len: Double) {
    (0, dur > 0 ? min(dur, max(120, min(dur * 0.25, 600))) : 600)
  }

  static func tailWindow(_ dur: Double, movie: Bool = false) -> (start: Double, len: Double)? {
    if !(dur > 0) { return nil }
    let len = movie ? min(dur, max(300, min(dur * 0.2, 1200))) : min(dur, max(120, min(dur * 0.25, 420)))
    return (max(0, dur - len), len)
  }

  private static let noStreams = Re("matches no streams|does not contain any stream", "i")

  private func decodeAudio(_ f: File, _ start: Double, _ len: Double) async throws -> [Float] {
    var args = ["-nostdin", "-hide_banner", "-loglevel", "error"]
    if start > 0 { args += ["-ss", toFixed(start, 3)] }
    args += ["-t", toFixed(len, 3), "-i", f.path, "-map", "0:a:0", "-vn", "-sn", "-dn", "-ac", "1", "-ar", String(FP.sampleRate), "-f", "f32le", "pipe:1"]
    let r = try await runTool(ffmpeg, args, background: true, maxErr: 20000, errHead: true)
    if r.code != 0 {
      if AnalysisJob.noStreams.test(r.stderr) { return [] }
      throw Failure(message: "audio decode failed: \(r.lastErrorLine)")
    }
    let n = r.stdout.count >> 2
    return r.stdout.withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
  }

  /// Loads the fingerprint for a part of a file from the index on disk, or
  /// computes and stores it.
  private func fingerprint(_ f: File, _ part: String) async throws -> (fp: [UInt32], offset: Double) {
    guard let win = part == "head" ? AnalysisJob.headWindow(f.duration) : AnalysisJob.tailWindow(f.duration) else { return ([], 0) }
    let cache = join(fpDir, "\(f.id)-\(f.sig)-\(part).fp")
    if let data = FileManager.default.contents(atPath: cache), let hit = FP.decode(data), abs(hit.offset - win.start) < 0.01 {
      return (hit.fp, hit.offset)
    }
    let pcm = try await decodeAudio(f, win.start, win.len)
    let fp = FP.compute(pcm)
    FileManager.default.createFile(atPath: cache, contents: FP.encode(fp, offset: win.start, length: win.len))
    return (fp, win.start)
  }

  struct Gray {
    var W: Int, H: Int, n: Int
    var times: [Double]
    var frames: Data
  }

  private static let showinfoRe = Re(#"\bn:\s*\d+\s+pts:\s*-?\d+\s+pts_time:\s*(-?[\d.]+)"#)

  /// Small grayscale frames plus their timestamps (from ffmpeg's showinfo).
  ///   keyOnly: decode keyframes only (fast scan of a long window)
  ///   fps: sample at a fixed rate (precise look at a short window)
  private func grayFrames(_ f: File, _ start: Double, _ len: Double, keyOnly: Bool = false, fps: Int = 0) async throws -> Gray? {
    let W = 160, H = 90
    var args = ["-nostdin", "-hide_banner", "-loglevel", "info"]
    if keyOnly { args += ["-skip_frame", "nokey"] }
    args += [
      "-ss", toFixed(start, 3), "-t", toFixed(len, 3), "-i", f.path, "-map", "0:v:0", "-an", "-sn", "-dn",
      "-vf", "\(fps > 0 ? "fps=\(fps)," : "")scale=\(W):\(H):flags=area,format=gray,showinfo", "-fps_mode", "passthrough", "-f", "rawvideo", "pipe:1",
    ]
    let r = try await runTool(ffmpeg, args, background: true, maxErr: 8_000_000, errHead: true)
    if r.code != 0 { return nil }
    let times = AnalysisJob.showinfoRe.matches(r.stderr).map { start + jsNumberValue($0[1]!) }
    let n = min(times.count, r.stdout.count / (W * H))
    return Gray(W: W, H: H, n: n, times: times, frames: r.stdout)
  }

  struct Flag {
    var t: Double
    var credits: Bool
    var text: Bool
  }

  /// Marks frames that look like end credits: black background with a little
  /// crisp bright text. Letterbox/pillarbox bars (black in nearly every frame) are
  /// left out so a dark widescreen scene is not mistaken for credits.
  static func creditFrames(_ g: Gray) -> [Flag] {
    let W = g.W, H = g.H, n = g.n
    let px = W * H
    var rowDark = [Int](repeating: 0, count: H)
    var colDark = [Int](repeating: 0, count: W)
    return g.frames.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Flag] in
      let frames = raw.bindMemory(to: UInt8.self)
      for f in 0..<n {
        let o = f * px
        for y in 0..<H {
          var s = 0
          for x in 0..<W { s += Int(frames[o + y * W + x]) }
          if Double(s) / Double(W) < 24 { rowDark[y] += 1 }
        }
        for x in 0..<W {
          var s = 0
          for y in 0..<H { s += Int(frames[o + y * W + x]) }
          if Double(s) / Double(H) < 24 { colDark[x] += 1 }
        }
      }
      func bar(_ count: Int) -> Bool { n >= 20 && Double(count) >= Double(n) * 0.97 }
      var top = 0, bottom = H, left = 0, right = W
      while top < H && bar(rowDark[top]) { top += 1 }
      while bottom > top && bar(rowDark[bottom - 1]) { bottom -= 1 }
      while left < W && bar(colDark[left]) { left += 1 }
      while right > left && bar(colDark[right - 1]) { right -= 1 }
      if Double((bottom - top) * (right - left)) < Double(px) * 0.2 { (top, bottom, left, right) = (0, H, 0, W) }
      let area = Double((bottom - top) * (right - left))

      var flags: [Flag] = []
      for f in 0..<n {
        let o = f * px
        var black = 0, dim = 0, bright = 0
        for y in top..<bottom {
          for x in left..<right {
            let v = frames[o + y * W + x]
            if v <= 24 {
              black += 1
            } else if v <= 48 {
              dim += 1
            } else if v >= 110 {
              bright += 1
            }
          }
        }
        // Credits are crisp text on pure black: few of the visible pixels are dim.
        // A dark scene keeps shadow detail, so most of its visible pixels are dim.
        let visible = area - Double(black)
        let crisp = visible < area * 0.01 || Double(dim) / visible <= 0.4
        flags.append(Flag(
          t: g.times[f], credits: Double(black) / area >= 0.8 && Double(bright) / area <= 0.18 && crisp,
          text: Double(bright) / area >= 0.002))
      }
      return flags
    }
  }

  /// End credits on screen: a sustained stretch of credit-like frames near the
  /// end. Only keyframes are decoded, so even the last 20 minutes of a film take
  /// a few seconds.
  private func videoCredits(_ f: File, movie: Bool) async throws -> Double? {
    guard let win = AnalysisJob.tailWindow(f.duration, movie: movie) else { return nil }
    guard let g = try await grayFrames(f, win.start, win.len, keyOnly: true), g.n >= 5 else { return nil }
    let flags = AnalysisJob.creditFrames(g)
    let minRun = movie ? 30.0 : 20.0
    let gap = 12.0
    struct Run { var start: Double; var end: Double; var flagged: Int; var text: Int }
    var best: Run?
    var run: Run?
    func close() {
      guard let r = run else { return }
      let span = r.end - r.start
      let total = flags.filter { $0.t >= r.start && $0.t <= r.end }.count
      if span >= minRun && Double(r.text) >= Double(r.flagged) * 0.25 && Double(r.flagged) >= Double(total) * 0.6
        && (best == nil || span > best!.end - best!.start)
      {
        best = r
      }
      run = nil
    }
    for fr in flags where fr.credits {
      if let r = run, fr.t - r.end > gap { close() }
      if run == nil { run = Run(start: fr.t, end: fr.t, flagged: 0, text: 0) }
      run!.end = fr.t
      run!.flagged += 1
      if fr.text { run!.text += 1 }
    }
    close()
    guard let best else { return nil }
    return try await refineStart(f, best.start) ?? best.start
  }

  /// Credits often appear on screen a few seconds before the end theme (or the
  /// first keyframe) we anchored on. Look at the 20 s before `t` at 5 fps and
  /// walk back through the unbroken run of credit-like frames.
  private func refineStart(_ f: File, _ t: Double) async throws -> Double? {
    let from = max(0, t - 20)
    guard let g = try await grayFrames(f, from, t - from + 1.5, fps: 5), g.n >= 3 else { return nil }
    let flags = AnalysisJob.creditFrames(g)
    var i = flags.firstIndex { $0.t >= t - 0.2 } ?? flags.count - 1
    if !flags[i].credits { return nil }
    while i > 0 && flags[i - 1].credits { i -= 1 }
    return flags[i].t < t - 0.5 ? flags[i].t : nil
  }

  private static func round1(_ x: Double) -> Double { jsRound(x * 10) / 10 }

  private func showJob(_ progress: @Sendable (Int, Int) -> Void) async -> [(String, Result)] {
    let all = files + refs
    var heads: [FP.Member] = []
    var tails: [FP.Member] = []
    var errors: [String: String] = [:]
    var step = 0
    let total = all.count + files.count
    for f in all {
      do {
        let h = try await fingerprint(f, "head")
        heads.append(FP.Member(id: f.id, fp: h.fp, offset: h.offset))
        let t = try await fingerprint(f, "tail")
        tails.append(FP.Member(id: f.id, fp: t.fp, offset: t.offset))
      } catch {
        // (A head that worked stays in the list as a reference for the others.)
        errors[f.id] = (error as? Failure)?.message ?? error.localizedDescription
        heads.append(FP.Member(id: f.id, fp: [], offset: 0))
        tails.append(FP.Member(id: f.id, fp: [], offset: 0))
      }
      step += 1
      progress(step, total)
    }
    let targets = files.map(\.id)
    var intros: [String: FP.Repeated] = [:]
    for (id, r) in FP.detectRepeatedSegments(heads, targets, AnalysisJob.intro) { intros[id] = r }
    var credits: [String: FP.Repeated] = [:]
    for (id, r) in FP.detectRepeatedSegments(tails, targets, AnalysisJob.credits) { credits[id] = r }

    var results: [(String, Result)] = []
    for f in files {
      var res = Result()
      if let i = intros[f.id] {
        res.intro = Span(start: i.start < 3 ? 0 : AnalysisJob.round1(i.start), end: AnalysisJob.round1(i.end))
        res.method["intro"] = "audio (\(i.support)/\(i.compared) episodes agree)"
      }
      if let c = credits[f.id], f.duration == 0 || c.start > f.duration * 0.5 {
        var start = c.start
        if let refined = try? await refineStart(f, c.start) { start = refined }
        res.credits = Mark(start: AnalysisJob.round1(start))
        res.method["credits"] = "audio (\(c.support)/\(c.compared) episodes agree)"
      } else if let v = try? await videoCredits(f, movie: false) {
        res.credits = Mark(start: AnalysisJob.round1(v))
        res.method["credits"] = "video (text on black)"
      }
      if let e = errors[f.id] { res.error = e }
      results.append((f.id, res))
      step += 1
      progress(step, total)
    }
    return results
  }

  private func movieJob(_ progress: @Sendable (Int, Int) -> Void) async -> [(String, Result)] {
    var results: [(String, Result)] = []
    for (i, f) in files.enumerated() {
      var res = Result()
      if i == files.count - 1 {
        do {
          if let v = try await videoCredits(f, movie: true) {
            res.credits = Mark(start: AnalysisJob.round1(v))
            res.method["credits"] = "video (text on black)"
          }
        } catch {
          res.error = (error as? Failure)?.message ?? error.localizedDescription
        }
      }
      results.append((f.id, res))
    }
    progress(1, 1)
    return results
  }
}
