import Foundation

// The cache (Cache): what a video's version made goes together, and goes when
// unused; the move out of the data folder. Videos still arriving
// (Completeness): files cut short, set aside but not filled, or with a hole,
// are told from complete ones; nothing waits on them in detection or previews.

private let day: Int64 = 86_400_000

/// Sets a file's modification time to `ms` (since 1970).
private func setTime(_ path: String, _ ms: Int64) {
  var times = [
    timeval(tv_sec: Int(ms / 1000), tv_usec: Int32((ms % 1000) * 1000)),
    timeval(tv_sec: Int(ms / 1000), tv_usec: Int32((ms % 1000) * 1000)),
  ]
  utimes(path, &times)
}

private func mtime(_ path: String) -> Int64 {
  var st = stat()
  return stat(path, &st) == 0 ? Scanner.mtimeMs(st) : -1
}

private func write(_ path: String, _ text: String = "x") {
  FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
}

private func libraryFile(_ id: String, _ path: String, titleId: String = "t", season: Int = 0) -> LibraryFile {
  var st = stat()
  stat(path, &st)
  return LibraryFile(
    id: id, titleId: titleId, season: season, number: nil, name: id, path: path, size: Int64(st.st_size), mtime: Scanner.mtimeMs(st),
    thumb: nil, subs: [])
}

/// Copies of `data` as a download in progress leaves them.
private enum Partial: String, CaseIterable {
  /// The first half only (a file that grows as it arrives).
  case cut
  /// Full size, the second half never written (set aside, a hole).
  case unfilled
  /// Full size, the first 40 % and the last 5 % written (first and last pieces first).
  case hole

  func write(_ data: Data, to path: String) throws {
    let n = data.count
    FileManager.default.createFile(atPath: path, contents: nil)
    let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? h.close() }
    switch self {
    case .cut:
      try h.write(contentsOf: data.prefix(n / 2))
    case .unfilled:
      try h.write(contentsOf: data.prefix(n / 2))
      try h.truncate(atOffset: UInt64(n))
    case .hole:
      try h.write(contentsOf: data.prefix(n * 40 / 100))
      try h.truncate(atOffset: UInt64(n))
      try h.seek(toOffset: UInt64(n - n * 5 / 100))
      try h.write(contentsOf: data.suffix(n * 5 / 100))
    }
  }
}

@MainActor
func cacheTests(_ t: Tests) {
  let tmp = tempDir("nightcap-cache-")
  let needs = Tools.ffmpeg == nil || Tools.ffprobe == nil ? "needs ffmpeg" : nil

  t.test("cache: the entries made for one version of a video are one item") {
    try expectEqual(Cache.item("abc123-9f8e7d"), "abc123-9f8e7d", "previews folder")
    try expectEqual(Cache.item("abc123-9f8e7d.json"), "abc123-9f8e7d", "still")
    try expectEqual(Cache.item("abc123-9f8e7d-card-480.jpg"), "abc123-9f8e7d", "picture cut from it")
    try expectEqual(Cache.item("abc123-9f8e7d-head.fp"), "abc123-9f8e7d", "fingerprint")
    try expectEqual(Cache.item("abc123-9f8e7d.tmp"), "abc123-9f8e7d", "being made")
    try expectEqual(Cache.item("convert-12-345.txt"), "convert-12", "anything else by its own name")
    try expectEqual(Cache.item("index.json"), "index.json")
    try expectEqual(Cache.item("-x"), "-x")
  }

  t.test("cache: an item goes when none of its entries was used in 30 days") {
    let dir = ensureDir(join(tmp, "sweep"))
    let now = nowMs()
    // a: its still old, a picture cut from it used yesterday: stays, whole.
    write(join(dir, "aaa-111.json"))
    write(join(dir, "aaa-111.jpg"))
    write(join(dir, "aaa-111-card-480.jpg"))
    setTime(join(dir, "aaa-111.json"), now - 40 * day)
    setTime(join(dir, "aaa-111.jpg"), now - 40 * day)
    setTime(join(dir, "aaa-111-card-480.jpg"), now - day)
    // b: all old: goes.
    write(join(dir, "bbb-222.json"))
    write(join(dir, "bbb-222-card-480.jpg"))
    setTime(join(dir, "bbb-222.json"), now - 31 * day)
    setTime(join(dir, "bbb-222-card-480.jpg"), now - 45 * day)
    // c: a previews folder used 29 days ago: stays; d: 31 days ago: goes, with what is inside.
    ensureDir(join(dir, "ccc-333"))
    write(join(dir, "ccc-333", "sheet-0.jpg"))
    setTime(join(dir, "ccc-333"), now - 29 * day)
    ensureDir(join(dir, "ddd-444"))
    write(join(dir, "ddd-444", "sheet-0.jpg"))
    setTime(join(dir, "ddd-444"), now - 31 * day)
    write(join(dir, "convert-1-2.txt"))
    setTime(join(dir, "convert-1-2.txt"), now - 40 * day)
    let removed = Cache.sweep(dir, now: now)
    try expectEqual(removed, ["bbb-222", "ddd-444", "convert-1"])
    let left = Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
    try expectEqual(left, ["aaa-111.json", "aaa-111.jpg", "aaa-111-card-480.jpg", "ccc-333"])
    try expectEqual(Cache.sweep(dir, now: now), [], "nothing more")
  }

  t.test("cache: using an entry marks it, at most once a day") {
    let a = join(tmp, "touch-a"), b = join(tmp, "touch-b")
    write(a)
    write(b)
    let now = nowMs()
    setTime(a, now - 2 * day)
    setTime(b, now - 3_600_000)
    Cache.touch(a)
    Cache.touch(b)
    try expect(abs(mtime(a) - nowMs()) < 5000, "used 2 days ago: marked now")
    try expect(abs(mtime(b) - (now - 3_600_000)) < 1000, "used an hour ago: left as it is")
    Cache.touch(join(tmp, "no-such-file"))
  }

  t.test("cache: what the data folder kept moves to the cache once") {
    let from = ensureDir(join(tmp, "old-data")), to = ensureDir(join(tmp, "new-cache"))
    ensureDir(join(from, "trickplay", "aaa-111"))
    write(join(from, "trickplay", "aaa-111", "index.json"), "{}")
    write(join(from, "probe.json"), "old")
    write(join(to, "probe.json"), "new")
    write(join(from, "progress.json"), "mine")
    Cache.moveOld(["trickplay", "probe.json", "stills"], from: from, to: to)
    try expect(fileExists(join(to, "trickplay", "aaa-111", "index.json")), "moved with what is inside")
    try expect(!fileExists(join(from, "trickplay")), "not left behind")
    try expectEqual(String(decoding: FileManager.default.contents(atPath: join(to, "probe.json")) ?? Data(), as: UTF8.self), "new", "the cache's own kept")
    try expect(!fileExists(join(from, "probe.json")), "the older copy removed")
    try expect(fileExists(join(from, "progress.json")), "the user's data stays")
  }

  // ---- Videos still arriving -----------------------------------------------------------------

  let videos = ensureDir(join(tmp, "arriving"))

  t.test("arriving: complete videos are told from ones cut short, unfilled or with a hole", skip: needs) {
    // 60 s with a changing picture and sound, a keyframe every 2 s; as MKV and AVI.
    let mkv = join(videos, "full.mkv"), avi = join(videos, "full.avi")
    try await ffmpeg([
      "-f", "lavfi", "-i", "testsrc2=s=320x180:r=25:d=60", "-f", "lavfi", "-i", "sine=f=440:d=60", "-c:v", "libx264", "-preset",
      "veryfast", "-g", "50", "-c:a", "aac", "-y", mkv,
    ])
    try await ffmpeg(["-i", mkv, "-c:v", "mpeg4", "-q:v", "5", "-g", "50", "-c:a", "libmp3lame", "-y", avi])
    let ffprobe = Tools.ffprobe
    for full in [mkv, avi] {
      let data = FileManager.default.contents(atPath: full)!
      let ok = await Completeness.looksComplete(full, size: Int64(data.count), ffprobe: ffprobe)
      try expect(ok, "\(basename(full)) is complete")
      try expectEqual(Completeness.zeroWindows(full, size: Int64(data.count)), 0)
      for kind in Partial.allCases {
        let path = join(videos, "\(kind.rawValue)-\(basename(full))")
        try kind.write(data, to: path)
        var st = stat()
        stat(path, &st)
        let partial = await Completeness.looksComplete(path, size: Int64(st.st_size), ffprobe: ffprobe)
        try expect(!partial, "\(basename(path)) is not complete")
      }
    }
    try expect(!(await Completeness.looksComplete(join(videos, "none.mkv"), size: 10, ffprobe: ffprobe)), "a missing file is not")
  }

  t.test("arriving: a video is looked at once it has been quiet for 5 minutes, and the answer kept", skip: needs) {
    let full = join(videos, "full.mkv"), part = join(videos, "unfilled-full.mkv")
    let store = JsonStore(join(tmp, "complete.json"), defaults: CompleteData())
    let c = Completeness(store: store)
    var changes = 0, stale = 0
    c.onChange = { changes += 1 }
    c.onStale = { stale += 1 }
    // Just written: not yet.
    let fresh = join(videos, "fresh.mkv")
    try FileManager.default.copyItem(atPath: full, toPath: fresh)
    try expect(!c.isComplete(libraryFile("fresh", fresh)), "changed a moment ago")
    // Changed since the scan: not complete, and a scan is asked for.
    var old = libraryFile("fresh", fresh)
    old.size -= 1
    try expect(!c.isComplete(old), "changed since the scan")
    try expectEqual(stale, 1)
    // Quiet for 10 minutes: looked at, then known.
    let quiet = nowMs() - 10 * 60_000
    setTime(full, quiet)
    setTime(part, quiet)
    let a = libraryFile("full", full), b = libraryFile("part", part)
    try expect(!c.isComplete(a) && !c.isComplete(b), "being looked at")
    for _ in 0..<200 where changes < 2 { await sleep(seconds: 0.05) }
    try expectEqual(changes, 2, "told when each is known")
    try expect(c.isComplete(a), "the complete one")
    try expect(!c.isComplete(b), "the unfilled one")
    try expectEqual(store.data.files[sigHash(a)]?.ok, true)
    try expectEqual(store.data.files[sigHash(b)]?.ok, false)
    c.prune(keeping: [sigHash(a)])
    try expectEqual(Array(store.data.files.keys), [sigHash(a)])
  }

  t.test("arriving: detection leaves out episodes still arriving, and hides what it found in them") {
    let paths = (1...4).map { join(videos, "ep\($0).mkv") }
    for p in paths { write(p) }
    let files = paths.enumerated().map { libraryFile("cachetestep\($0.offset + 1)", $0.element, titleId: "cacheshow") }
    let season = Season(id: "s1", number: 1, name: "Season 1", poster: nil, episodes: files.map(\.id), extras: nil)
    let title = Title(
      id: "cacheshow", kind: "show", name: "Show", year: nil, folderIds: [], poster: nil, backdrop: nil, seasons: [season], addedAt: 1)
    let lib = Library(
      titles: [title], files: Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) }), folderStatus: [:], scannedAt: 0,
      fileOrder: files.map(\.id))
    var arriving: Set<String> = ["cachetestep4"]
    var checking: Set<String> = []
    let an = Analyzer(
      getLibrary: { lib }, media: Media(), isEnabled: { false },
      arrival: { arriving.contains($0.id) ? .arriving : checking.contains($0.id) ? .checking : .complete })
    try expectEqual(an.groups(title).map(\.fileIds), [["cachetestep1", "cachetestep2", "cachetestep3"]])
    let intro = Span(start: 10, end: 60)
    an.store.data.files["cachetestep4"] = AnalysisEntry(v: Analyzer.version, basis: "x", at: 0, intro: intro, credits: nil, method: [:], error: nil)
    try expectEqual(an.markers("cachetestep4").intro, nil, "found in part of it: not shown")
    arriving = []
    checking = ["cachetestep4"]
    try expectEqual(an.markers("cachetestep4").intro, intro, "being looked at: what was found before stays")
    an.sync()
    try expect(!an.queue.contains { $0.titleId == "cacheshow" }, "being looked at: the show waits")
    checking = []
    try expectEqual(an.markers("cachetestep4").intro, intro, "complete: shown")
    try expectEqual(an.groups(title).map(\.fileIds), [files.map(\.id)])
    arriving = Set(files.map(\.id))
    try expectEqual(an.groups(title).map(\.fileIds), [[]], "none complete: nothing to do")
    an.store.data.files["cachetestep4"] = nil
  }

  t.test("arriving: previews skip videos still arriving; in the background only titles in use") {
    let a = join(videos, "pa.mkv"), b = join(videos, "pb.mkv"), c = join(videos, "pc.mkv")
    for p in [a, b, c] { write(p) }
    let fa = libraryFile("cachetestpa", a, titleId: "used"), fb = libraryFile("cachetestpb", b, titleId: "used")
    let fc = libraryFile("cachetestpc", c, titleId: "old")
    func title(_ id: String, _ eps: [String]) -> Title {
      Title(
        id: id, kind: "show", name: id, year: nil, folderIds: [], poster: nil, backdrop: nil,
        seasons: [Season(id: "s", number: 1, name: "Season 1", poster: nil, episodes: eps, extras: nil)], addedAt: 1)
    }
    let lib = Library(
      titles: [title("used", [fa.id, fb.id]), title("old", [fc.id])], files: [fa.id: fa, fb.id: fb, fc.id: fc], folderStatus: [:],
      scannedAt: 0, fileOrder: [fa.id, fb.id, fc.id])
    let tp = Trickplay(
      getLibrary: { lib }, media: Media(), isEnabled: { true }, isComplete: { $0.id != "cachetestpb" }, isActive: { $0.id == "used" })
    try expectEqual(tp.wanted(), [fa.id, fb.id], "only the title in use")
    tp.sync()
    let taken = tp.queue + (tp.current.map { [$0] } ?? [])
    try expectEqual(taken, [fa.id], "the complete one only")
    tp.prioritize([fb.id, fc.id])
    let after = tp.queue + (tp.current.map { [$0] } ?? [])
    try expect(!after.contains(fb.id), "asked for, but still arriving")
    try expect(after.contains(fc.id), "asked for: made though its title isn't in use")
  }
}
