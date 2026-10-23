import Foundation

@MainActor func trickplayTests(_ t: Tests) {
  let tmp = tempDir("nightcap-tp-")
  let needs = Tools.ffmpeg == nil ? "needs ffmpeg" : nil

  t.test("reads the size of a JPEG", skip: needs) {
    let out = join(tmp, "one.jpg")
    try await ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=96x54", "-frames:v", "1", "-y", out])
    let size = Trickplay.jpegSize(FileManager.default.contents(atPath: out) ?? Data())
    try expectEqual(size?.width, 96)
    try expectEqual(size?.height, 54)
  }

  t.test("makes thumbnail sheets for a video, in the frame shape of the video", skip: needs) {
    // 70 s, 4:3, a keyframe every second.
    let video = join(tmp, "clip.mp4")
    try await ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=70", "-g", "10", "-pix_fmt", "yuv420p", "-y", video])
    var st = stat()
    try expect(stat(video, &st) == 0, "no clip")
    let file = LibraryFile(
      id: "clip0000test", titleId: "t", season: 0, number: nil, name: "Clip", path: video, size: Int64(st.st_size),
      mtime: Scanner.mtimeMs(st), thumb: nil, subs: [])
    let season = Season(id: "s", number: nil, name: "", poster: nil, episodes: [file.id], extras: nil)
    let title = Title(
      id: "t", kind: "movie", name: "Clip", year: nil, folderIds: [], poster: nil, backdrop: nil, seasons: [season], addedAt: 1)
    let lib = Library(titles: [title], files: [file.id: file], folderStatus: [:], scannedAt: 0, fileOrder: [file.id])
    // The real probe (ffprobe) stands in for the JavaScript test's fake one.
    let tp = Trickplay(getLibrary: { lib }, media: Media(), isEnabled: { true })
    let m = try await tp.generate(file)
    try expectEqual(m.interval, 2, "short videos get a frame every 2 s")
    try expectEqual(m.width, 240)
    try expectEqual(m.height, 180)
    try expectEqual(m.sheets, 1)
    try expectEqual(m.count, 36)
    try expect(tp.sheetPath(file, 0).map { FileManager.default.fileExists(atPath: $0) } ?? false, "no sheet 0")
    try expectEqual(tp.sheetPath(file, 1), nil)
    try expectEqual(tp.state(file), "ready")
    try expectEqual(tp.status().done, 1)
  }

  t.test("counts thumbnails from 0:00 when the first keyframe is later", skip: needs) {
    // Red, then blue from 0:20; keyframes at 0:08, 0:16, 0:20 (the cut) and on (the one at 0:00 dropped).
    let video = join(tmp, "late.avi")
    try await ffmpeg([
      "-f", "lavfi", "-i", "color=c=red:s=320x240:r=10:d=20", "-f", "lavfi", "-i", "color=c=blue:s=320x240:r=10:d=20",
      "-filter_complex", "[0][1]concat=n=2", "-c:v", "mpeg4", "-g", "80", "-bf", "0", "-bsf:v", "noise=drop=eq(n\\,0)", "-y", video,
    ])
    var st = stat()
    try expect(stat(video, &st) == 0, "no clip")
    let file = LibraryFile(
      id: "late0000test", titleId: "t", season: 0, number: nil, name: "Late", path: video, size: Int64(st.st_size),
      mtime: Scanner.mtimeMs(st), thumb: nil, subs: [])
    let season = Season(id: "s", number: nil, name: "", poster: nil, episodes: [file.id], extras: nil)
    let title = Title(
      id: "t", kind: "movie", name: "Late", year: nil, folderIds: [], poster: nil, backdrop: nil, seasons: [season], addedAt: 1)
    let lib = Library(titles: [title], files: [file.id: file], folderStatus: [:], scannedAt: 0, fileOrder: [file.id])
    let tp = Trickplay(getLibrary: { lib }, media: Media(), isEnabled: { true })
    let m = try await tp.generate(file)
    try expectEqual(m.interval, 2)
    guard let path = tp.sheetPath(file, 0), let sheet = Stills.load(path), let px = Pixels(sheet) else {
      throw TestFailure(description: "no sheet 0")
    }
    // Thumbnail n, at n × 2 s: red or blue in its middle.
    func blue(_ n: Int) -> Bool {
      let x = (n % m.cols) * Int(m.width) + Int(m.width) / 2, y = (n / m.cols) * Int(m.height) + Int(m.height) / 2
      let i = (y * px.width + x) * 4
      return px.data[i + 2] > px.data[i]
    }
    try expect(!blue(0), "0:00 shows the first keyframe")
    try expect(!blue(9), "0:18 is red")
    try expect(blue(11), "0:22 is blue")
  }
}
