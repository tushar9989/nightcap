import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// Stills: the pictures of episodes and titles, chosen from the videos' own
// frames. A video's preview frames (Trickplay) between the intro and the end
// credits are scored for exposure, contrast, sharpness and colour; the best
// few are looked at for faces and on-screen text (Vision); the winner is taken
// again from the video at full size. Pictures are cut from it in the shape
// asked for (letterbox bars left out, faces kept in frame) and scaled with a
// little sharpening.
//
// On disk: DATA_DIR/stills/<fileId>-<sigHash>.{jpg,json} (the chosen frame),
// and the pictures cut from it, <fileId>-<sigHash>-<shape>-<width>.jpg.

/// The chosen frame of a video: where it is, how good, and what is in it.
struct StillInfo: Codable, Equatable {
  static let version = 1
  var v: Int
  /// Seconds into the video (where the preview frame was).
  var t: Double
  var score: Double
  /// The picture without letterbox bars: x, y, width, height as fractions of the frame, from the top left.
  var box: [Double]
  /// Faces, the same way.
  var faces: [[Double]]
}

/// The shape of a picture cut from a still.
enum StillShape: String {
  /// 16:9: tiles, episode rows, the Next card.
  case card
  /// 2:1: across the top of a title's page.
  case backdrop
  /// 2:3.
  case poster

  var aspect: Double {
    switch self {
    case .card: 16 / 9
    case .backdrop: 2
    case .poster: 2 / 3
    }
  }

  /// Where a face goes, from the top (a little above the middle, as photographers frame people).
  var faceY: Double {
    switch self {
    case .card: 0.4
    case .backdrop: 0.35
    case .poster: 0.3
    }
  }
}

/// A rectangle in pixels, from the top left.
struct PixelRect: Equatable {
  var x: Int, y: Int, w: Int, h: Int
}

/// An image's pixels, 8-bit RGBX, the top row first.
struct Pixels {
  let width: Int
  let height: Int
  let data: [UInt8]

  init?(_ image: CGImage) {
    let w = image.width, h = image.height
    guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ok = buf.withUnsafeMutableBytes { raw -> Bool in
      guard
        let ctx = CGContext(
          data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard ok else { return nil }
    width = w
    height = h
    data = buf
  }

  /// For tests: a picture from a function of (x, y) giving (r, g, b) in 0...255.
  init(width: Int, height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) {
    self.width = width
    self.height = height
    var buf = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let (r, g, b) = color(x, y)
        let i = (y * width + x) * 4
        buf[i] = r
        buf[i + 1] = g
        buf[i + 2] = b
      }
    }
    data = buf
  }

  /// Brightness 0...1 (Rec. 709 weights on the encoded values).
  @inline(__always) func luma(_ x: Int, _ y: Int) -> Double {
    let i = (y * width + x) * 4
    return (0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])) / 255
  }
}

/// What a frame looks like, measured.
struct FrameStats {
  /// Mean and spread of brightness (0...1).
  var mean = 0.0
  var spread = 0.0
  /// Variance of the Laplacian: higher is sharper (only comparable within one video).
  var sharpness = 0.0
  /// Hasler and Süsstrunk's colourfulness (0...1 scale).
  var colour = 0.0
  /// Share of pixels clipped to black or white.
  var clipped = 0.0

  /// 1 at a mid exposure, falling to 0 for frames too dark or too bright.
  var exposure: Double { max(0, 1 - abs(mean - 0.42) / 0.34) }
  /// Fades, black and white frames: never chosen.
  var unusable: Bool { mean < 0.07 || mean > 0.9 || spread < 0.04 }
}

enum StillMath {
  /// The picture inside `r` without letterbox or pillarbox bars: edge rows and
  /// columns that are all near black (at most 30% from each side).
  static func contentBox(_ p: Pixels, _ r: PixelRect) -> PixelRect {
    func dark(_ xs: StrideTo<Int>, _ ys: StrideTo<Int>) -> Bool {
      var sum = 0.0, n = 0.0, top = 0.0
      for y in ys {
        for x in xs {
          let l = p.luma(x, y)
          sum += l
          n += 1
          if l > top { top = l }
        }
      }
      return n > 0 && sum / n < 0.06 && top < 0.2
    }
    let xs = stride(from: r.x, to: r.x + r.w, by: 1), ys = stride(from: r.y, to: r.y + r.h, by: 1)
    var top = 0, bottom = 0, left = 0, right = 0
    while top < r.h * 3 / 10 && dark(xs, stride(from: r.y + top, to: r.y + top + 1, by: 1)) { top += 1 }
    while bottom < r.h * 3 / 10 && dark(xs, stride(from: r.y + r.h - 1 - bottom, to: r.y + r.h - bottom, by: 1)) { bottom += 1 }
    while left < r.w * 3 / 10 && dark(stride(from: r.x + left, to: r.x + left + 1, by: 1), ys) { left += 1 }
    while right < r.w * 3 / 10 && dark(stride(from: r.x + r.w - 1 - right, to: r.x + r.w - right, by: 1), ys) { right += 1 }
    // A bar of a pixel or two is the edge of the picture, not a bar.
    if top + bottom < 3 { top = 0; bottom = 0 }
    if left + right < 3 { left = 0; right = 0 }
    return PixelRect(x: r.x + left, y: r.y + top, w: r.w - left - right, h: r.h - top - bottom)
  }

  static func stats(_ p: Pixels, _ r: PixelRect) -> FrameStats {
    var s = FrameStats()
    guard r.w > 2, r.h > 2 else { return s }
    var sum = 0.0, sum2 = 0.0, clipped = 0.0
    var rg = 0.0, rg2 = 0.0, yb = 0.0, yb2 = 0.0
    var lap = 0.0, lap2 = 0.0, nLap = 0.0
    let n = Double(r.w * r.h)
    for y in r.y..<(r.y + r.h) {
      for x in r.x..<(r.x + r.w) {
        let i = (y * p.width + x) * 4
        let R = Double(p.data[i]) / 255, G = Double(p.data[i + 1]) / 255, B = Double(p.data[i + 2]) / 255
        let l = 0.2126 * R + 0.7152 * G + 0.0722 * B
        sum += l
        sum2 += l * l
        if l < 0.02 || l > 0.98 { clipped += 1 }
        let a = R - G, b = 0.5 * (R + G) - B
        rg += a
        rg2 += a * a
        yb += b
        yb2 += b * b
        if x > r.x && x < r.x + r.w - 1 && y > r.y && y < r.y + r.h - 1 {
          let v = 4 * l - p.luma(x - 1, y) - p.luma(x + 1, y) - p.luma(x, y - 1) - p.luma(x, y + 1)
          lap += v
          lap2 += v * v
          nLap += 1
        }
      }
    }
    s.mean = sum / n
    s.spread = sqrt(max(0, sum2 / n - s.mean * s.mean))
    s.clipped = clipped / n
    let mrg = rg / n, myb = yb / n
    let srg = sqrt(max(0, rg2 / n - mrg * mrg)), syb = sqrt(max(0, yb2 / n - myb * myb))
    s.colour = sqrt(srg * srg + syb * syb) + 0.3 * sqrt(mrg * mrg + myb * myb)
    if nLap > 0 {
      let m = lap / nLap
      s.sharpness = max(0, lap2 / nLap - m * m)
    }
    return s
  }

  /// Each value's rank among all of them, 0 (lowest) to 1 (highest).
  static func ranks(_ xs: [Double]) -> [Double] {
    guard xs.count > 1 else { return xs.map { _ in 1 } }
    let order = xs.indices.sorted { xs[$0] < xs[$1] }
    var out = [Double](repeating: 0, count: xs.count)
    for (rank, i) in order.enumerated() { out[i] = Double(rank) / Double(xs.count - 1) }
    return out
  }

  /// How much a face adds: its size (best when it is a fifth to a half of the
  /// frame's height; small faces in a crowd count for little), less for a poor
  /// picture of it (Vision's capture quality; around 0.3 is already a good face
  /// in a small or standard-definition frame).
  static func faceScore(quality: Double, height: Double) -> Double {
    let size = height < 0.06 ? 0.2 : height < 0.18 ? 0.2 + 0.8 * (height - 0.06) / 0.12 : height <= 0.55 ? 1 : max(0.4, 1 - (height - 0.55))
    return size * (0.4 + 0.6 * max(0, min(1, quality / 0.3)))
  }

  /// How much the people in a still count when choosing between videos' stills:
  /// the two largest faces, by size.
  static func people(_ faces: [[Double]]) -> Double {
    let sizes = faces.filter { $0.count == 4 }.map { faceScore(quality: 1, height: $0[3]) }.sorted(by: >)
    return min(1.5, sizes.prefix(2).reduce(0, +))
  }

  /// The part of a still to show in `shape`: as large as fits in the picture
  /// (`box`, without bars), around the faces if there are any.
  static func crop(width: Int, height: Int, box: [Double], faces: [[Double]], shape: StillShape) -> CGRect {
    let fw = Double(width), fh = Double(height)
    var bx = box.count == 4 ? box : [0, 0, 1, 1]
    if !(bx[2] > 0.2 && bx[3] > 0.2) { bx = [0, 0, 1, 1] }
    let b = CGRect(x: bx[0] * fw, y: bx[1] * fh, width: bx[2] * fw, height: bx[3] * fh)
    let a = shape.aspect
    var w = b.width, h = b.height
    if w / h > a { w = h * a } else { h = w / a }
    // The faces' middle, weighted by their size; else the middle of the picture.
    var fx = b.midX, fy = b.midY, total = 0.0
    if !faces.isEmpty {
      var sx = 0.0, sy = 0.0
      for f in faces where f.count == 4 {
        let weight = f[2] * f[3]
        sx += (f[0] + f[2] / 2) * fw * weight
        sy += (f[1] + f[3] / 2) * fh * weight
        total += weight
      }
      if total > 0 {
        fx = sx / total
        fy = sy / total
      }
    }
    let x = total > 0 ? fx - w / 2 : b.midX - w / 2
    let y = total > 0 ? fy - h * shape.faceY : b.midY - h / 2
    return CGRect(
      x: (min(max(x, b.minX), b.maxX - w)).rounded(), y: (min(max(y, b.minY), b.maxY - h)).rounded(),
      width: w.rounded(), height: h.rounded())
  }
}

// ---- Choosing and cutting ---------------------------------------------------------------------------

@MainActor
final class Stills {
  let dir = ensureDir(Paths.data("stills"))
  private let trickplay: () -> Trickplay?
  private let markers: (String) -> Markers?
  private let limit = Limiter(2)
  /// Moments are asked for by the page on screen: they don't wait behind the stills.
  private let momentLimit = Limiter(2)
  private var picks: [String: Task<StillInfo?, Never>] = [:]
  private var renders: [String: Task<String?, Never>] = [:]
  /// Stills read or chosen, by `base`.
  private var known: [String: StillInfo] = [:]
  /// Videos with no still to be had (no usable frame, the file not there):
  /// not tried again until the app is next started.
  private var failed: Set<String> = []
  private var sweeping = false
  private var sweepAgain = false
  private var stopped = false

  init(trickplay: @escaping () -> Trickplay?, markers: @escaping (String) -> Markers?) {
    self.trickplay = trickplay
    self.markers = markers
  }

  private func base(_ f: LibraryFile) -> String { join(dir, "\(f.id)-\(sigHash(f))") }

  private func saved(_ base: String) -> StillInfo? {
    if let info = known[base] { return info }
    guard let raw = FileManager.default.contents(atPath: "\(base).json"), let info = try? JSONDecoder().decode(StillInfo.self, from: raw),
      info.v == StillInfo.version, fileExists("\(base).jpg")
    else { return nil }
    known[base] = info
    return info
  }

  /// A video's preview frames, if they have been made.
  private func previews(_ f: LibraryFile) -> (manifest: TrickplayManifest, sheets: [String])? {
    guard let tp = trickplay(), let m = tp.manifest(f) else { return nil }
    let sheets = (0..<m.sheets).compactMap { tp.sheetPath(f, $0) }
    return sheets.count == m.sheets ? (m, sheets) : nil
  }

  /// The chosen frame of a video, choosing it if it hasn't been yet (nil without previews or ffmpeg).
  func still(_ f: LibraryFile) async -> StillInfo? {
    let base = base(f)
    if let info = saved(base) { return info }
    if let running = picks[f.id] { return await running.value }
    guard !failed.contains(base), let ffmpeg = Tools.ffmpeg, let (m, sheets) = previews(f) else { return nil }
    let mk = markers(f.id)
    let task = Task { () -> StillInfo? in
      let info = await limit.run { await choose(f, base: base, manifest: m, sheets: sheets, markers: mk, ffmpeg: ffmpeg) }
      picks[f.id] = nil
      if let info {
        known[base] = info
      } else {
        failed.insert(base)
        logLine("[stills] no still for \(f.path)")
      }
      return info
    }
    picks[f.id] = task
    return await task.value
  }

  /// Chooses the stills still missing, one video at a time in the background,
  /// so that pages have them before they are opened (a page asks for its own
  /// first: they take the other place in the queue). `files` lists the videos
  /// in the order to do them; asked again while running, it goes round once
  /// more at the end, for videos whose previews have been made since.
  func sweep(_ files: @escaping () -> [LibraryFile]) {
    if sweeping {
      sweepAgain = true
      return
    }
    sweeping = true
    Task {
      repeat {
        sweepAgain = false
        for f in files() {
          if stopped { break }
          let base = base(f)
          if failed.contains(base) || saved(base) != nil || previews(f) == nil { continue }
          _ = await still(f)
        }
      } while sweepAgain && !stopped
      sweeping = false
    }
  }

  /// The app is quitting: no more stills are started.
  func stop() { stopped = true }

  /// The best preview frame, then that frame at full size. Previews are made
  /// from keyframes only, so it is a keyframe near its time (as far as a few
  /// seconds before it where keyframes are far apart): the keyframes there,
  /// a little way back first, then further, and the one that looks like it.
  private func choose(
    _ f: LibraryFile, base: String, manifest m: TrickplayManifest, sheets: [String], markers mk: Markers?, ffmpeg: String
  ) async -> StillInfo? {
    guard let pick = await Task.detached(priority: .utility, operation: { Stills.bestPreview(manifest: m, sheets: sheets, markers: mk) }).value
    else { return nil }
    let tmp = ensureDir("\(base).tmp")
    defer { removeItem(tmp) }
    let end = pick.time + m.interval / 2 + 0.5
    for back in [3.0, 15.0] {
      let start = max(0, pick.time - back)
      _ = try? await runTool(
        ffmpeg,
        [
          "-nostdin", "-hide_banner", "-loglevel", "error", "-skip_frame", "nokey", "-ss", toFixed(start, 2), "-i", f.path, "-t",
          toFixed(end - start, 2), "-map", "0:v:0", "-vf", Stills.squarePixels, "-fps_mode", "passthrough", "-y", join(tmp, "k%03d.png"),
        ], timeout: 60, background: true)
      let shots = ((try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        .map { join(tmp, $0) }
      if let info = await Task.detached(priority: .utility, operation: { Stills.keep(shots, pick: pick, base: base, exact: false) }).value {
        return info
      }
      shots.forEach(removeItem)
    }
    // No keyframe looked like it: the frame at that moment.
    let one = join(tmp, "one.png")
    _ = try? await runTool(
      ffmpeg,
      [
        "-nostdin", "-hide_banner", "-loglevel", "error", "-ss", toFixed(pick.time, 2), "-i", f.path, "-map", "0:v:0", "-vf",
        Stills.squarePixels, "-frames:v", "1", "-y", one,
      ], timeout: 60, background: true)
    return await Task.detached(priority: .utility) { Stills.keep([one], pick: pick, base: base, exact: true) }.value
  }

  /// A picture of a video in `shape`, `width` wide (a JPEG path), cut from its still.
  func picture(_ f: LibraryFile, shape: StillShape, width: Int) async -> String? {
    guard await still(f) != nil else { return nil }
    let base = base(f)
    let out = "\(base)-\(shape.rawValue)-\(width).jpg"
    return await once(out) {
      guard let info = Stills.read("\(base).json"), let image = Stills.load("\(base).jpg") else { return nil }
      return Stills.cut(image, info: info, shape: shape, width: width, out: out) ? out : nil
    }
  }

  /// The best still among some videos, in order (for a title's picture:
  /// people, if any, count for a lot, and the first video, which brings in
  /// the main characters, a little more). Ties go to the earlier video, so the
  /// choice is the same every time.
  func best(_ files: [LibraryFile]) async -> LibraryFile? {
    let tasks = files.map { f in Task { await self.still(f) } }
    var best: (file: LibraryFile, score: Double)?
    for (i, t) in tasks.enumerated() {
      guard let info = await t.value else { continue }
      let score = info.score + 0.3 * StillMath.people(info.faces) + (i == 0 ? 0.15 : 0)
      if best == nil || score > best!.score { best = (files[i], score) }
    }
    return best?.file
  }

  /// The frame at `t` seconds, `width` wide, 16:9 (a JPEG path).
  func moment(_ f: LibraryFile, at t: Double, width: Int) async -> String? {
    let tenths = Int(jsRound(t * 10))
    let out = join(dir, "\(f.id)-\(sigHash(f))-m\(tenths)-\(width).jpg")
    if fileExists(out) { return out }
    if let running = renders[out] { return await running.value }
    guard let ffmpeg = Tools.ffmpeg else { return nil }
    // The video's bars, as its still found them (one frame alone can be too dark to tell).
    let known = saved(base(f))?.box
    let task = Task { () -> String? in
      let made = await momentLimit.run { () -> String? in
        let tmp = ensureDir("\(out).tmp")
        defer { removeItem(tmp) }
        let png = join(tmp, "f.png")
        _ = try? await runTool(
          ffmpeg,
          [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-ss", toFixed(Double(tenths) / 10, 1), "-i", f.path, "-map", "0:v:0", "-vf",
            Stills.squarePixels, "-frames:v", "1", "-y", png,
          ], timeout: 60)
        return await Task.detached(priority: .userInitiated) { () -> String? in
          guard let image = Stills.load(png), let px = Pixels(image) else { return nil }
          let box = known ?? Stills.fractions(StillMath.contentBox(px, PixelRect(x: 0, y: 0, w: px.width, h: px.height)), px)
          let faces = Stills.vision(image, box: Stills.pixels(box, px)).faces.map(\.rect)
          let info = StillInfo(v: StillInfo.version, t: t, score: 0, box: box, faces: faces)
          return Stills.cut(image, info: info, shape: .card, width: width, out: out) ? out : nil
        }.value
      }
      renders[out] = nil
      return made
    }
    renders[out] = task
    return await task.value
  }

  /// Good moments of a video to start from (`count` at most), spread over it,
  /// between the intro and the end credits. Empty until its previews are made.
  func moments(_ f: LibraryFile, count: Int) async -> [Double] {
    guard let (m, sheets) = previews(f) else { return [] }
    let mk = markers(f.id)
    return await Task.detached(priority: .userInitiated) { Stills.spread(manifest: m, sheets: sheets, markers: mk, count: count) }.value
  }

  /// Makes `out` once (off the main thread), however many ask for it at the same time.
  private func once(_ out: String, _ make: @escaping @Sendable () -> String?) async -> String? {
    if fileExists(out) { return out }
    if let running = renders[out] { return await running.value }
    let task = Task { () -> String? in
      let made = await Task.detached(priority: .userInitiated, operation: make).value
      renders[out] = nil
      return made
    }
    renders[out] = task
    return await task.value
  }

  // ---- The work (off the main thread) ------------------------------------------------------------

  /// ffmpeg's filter that makes non-square pixels square (DVD video is often stored squeezed).
  nonisolated static let squarePixels = "scale=trunc(iw*sar/2)*2:ih,setsar=1"

  /// The preview frame chosen: when, how good, and where the picture is (without bars).
  struct PreviewPick: Sendable {
    let time: Double
    let score: Double
    let box: [Double]
    /// The frame in brief (see `look`), to find it again at full size.
    let look: [Double]
  }

  /// A preview frame and where it came from.
  private struct Candidate {
    let index: Int
    let time: Double
    let image: CGImage
    let rect: PixelRect
    var stats = FrameStats()
    var score = 0.0
    /// The best face in it (see `faceScore`).
    var face = 0.0

    /// Its part of the preview sheet, without the bars (`box`).
    func cell(_ box: [Double]) -> CGImage? {
      let b = Stills.pixels(box, width: rect.w, height: rect.h)
      return image.cropping(to: CGRect(x: rect.x + b.x, y: rect.y + b.y, width: b.w, height: b.h))
    }
  }

  /// The preview frames between the intro and the end credits (`limit` at most, evenly spread), measured.
  nonisolated private static func candidates(manifest m: TrickplayManifest, sheets: [String], markers mk: Markers?, limit: Int)
    -> (frames: [Candidate], box: [Double])
  {
    let dur = Double(max(0, m.count - 1)) * m.interval
    let from = max((mk?.intro?.end ?? 0) + 5, dur * 0.05)
    let to = min((mk?.credits?.start ?? dur) - 5, dur * 0.93)
    var first = Int((from / m.interval).rounded(.up)), last = Int((to / m.interval).rounded(.down))
    if last < first {
      first = 0
      last = m.count - 1
    }
    let total = last - first + 1
    let pick = min(limit, max(1, total))
    var indices: [Int] = []
    for k in 0..<pick {
      let i = first + Int((Double(k) + 0.5) * Double(total) / Double(pick))
      if indices.last != i && i <= last { indices.append(i) }
    }
    let per = m.cols * m.rows
    let cw = Int(m.width), ch = Int(m.height)
    var decoded: [Int: (image: CGImage, pixels: Pixels)] = [:]
    var frames: [Candidate] = []
    for i in indices {
      let n = i / per, k = i % per
      if decoded[n] == nil, n < sheets.count, let img = load(sheets[n]), let px = Pixels(img) { decoded[n] = (img, px) }
      guard let sheet = decoded[n] else { continue }
      let rect = PixelRect(x: (k % m.cols) * cw, y: (k / m.cols) * ch, w: cw, h: ch)
      guard rect.x + rect.w <= sheet.image.width, rect.y + rect.h <= sheet.image.height else { continue }
      frames.append(Candidate(index: i, time: Double(i) * m.interval, image: sheet.image, rect: rect))
    }
    // The bars are the same all through a video: the middle value of each edge
    // over all the frames (a dark scene alone would look like one big bar).
    var tops: [Int] = [], bottoms: [Int] = [], lefts: [Int] = [], rights: [Int] = []
    for c in frames {
      guard let px = decoded[c.index / per]?.pixels else { continue }
      let b = StillMath.contentBox(px, c.rect)
      tops.append(b.y - c.rect.y)
      bottoms.append(c.rect.y + c.rect.h - b.y - b.h)
      lefts.append(b.x - c.rect.x)
      rights.append(c.rect.x + c.rect.w - b.x - b.w)
    }
    func median(_ xs: [Int]) -> Int { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }
    let t = median(tops), bt = median(bottoms), l = median(lefts), r = median(rights)
    let box = [Double(l) / Double(cw), Double(t) / Double(ch), Double(cw - l - r) / Double(cw), Double(ch - t - bt) / Double(ch)]
    for j in frames.indices {
      guard let px = decoded[frames[j].index / per]?.pixels else { continue }
      let c = frames[j].rect
      frames[j].stats = StillMath.stats(px, PixelRect(x: c.x + l, y: c.y + t, w: c.w - l - r, h: c.h - t - bt))
    }
    // Sharpness and colour count by rank: their scale differs from video to video.
    let sharp = StillMath.ranks(frames.map(\.stats.sharpness))
    let colour = StillMath.ranks(frames.map(\.stats.colour))
    for j in frames.indices {
      let s = frames[j].stats
      frames[j].score =
        s.unusable
        ? -1 : 0.15 * sharp[j] + 0.25 * s.exposure + 0.2 * min(1, s.spread / 0.25) + 0.15 * colour[j] + 0.1 * (1 - min(1, s.clipped * 4))
    }
    return (frames, box)
  }

  /// The best preview frame, looking at what is in the best 24.
  nonisolated static func bestPreview(manifest m: TrickplayManifest, sheets: [String], markers mk: Markers?) -> PreviewPick? {
    let (frames, box) = candidates(manifest: m, sheets: sheets, markers: mk, limit: 48)
    let looked = rescore(Array(frames.filter { $0.score >= 0 }.sorted { $0.score > $1.score }.prefix(24)), box: box)
    guard let best = looked.first, let cell = best.cell([0, 0, 1, 1]), let look = look(cell) else { return nil }
    return PreviewPick(time: best.time, score: best.score, box: box, look: look)
  }

  /// A picture in brief: its brightness on a 32×18 grid, 0...1 (whether two
  /// pictures are the same frame, whatever their size and compression).
  nonisolated static func look(_ image: CGImage) -> [Double]? {
    let w = 32, h = 18
    var buf = [UInt8](repeating: 0, count: w * h)
    let ok = buf.withUnsafeMutableBytes { raw -> Bool in
      guard
        let ctx = CGContext(
          data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      ctx.interpolationQuality = .medium
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    return ok ? buf.map { Double($0) / 255 } : nil
  }

  /// How different two pictures are in brief (mean difference, 0...1).
  nonisolated static func difference(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 1 }
    return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
  }

  /// Candidates scored again for what is in them, best first. Faces add and
  /// readable text takes away; then, for the best six, a face counts only as
  /// much as Vision sees people in the picture (not a photo on a document, a
  /// face on a screen), documents and screens take away, and so do subtitles
  /// burnt into the video (a line of them about 0.3).
  nonisolated private static func rescore(_ frames: [Candidate], box: [Double]) -> [Candidate] {
    var out = frames
    for j in out.indices {
      guard let cell = out[j].cell(box) else { continue }
      let seen = vision(cell, box: PixelRect(x: 0, y: 0, w: cell.width, h: cell.height))
      out[j].face = seen.faces.map(faceScore).max() ?? 0
      out[j].score += 0.5 * out[j].face - 0.4 * min(1, seen.text * 10)
    }
    out.sort { $0.score > $1.score }
    let few = min(6, out.count)
    for j in 0..<few {
      guard let cell = out[j].cell(box) else { continue }
      let kind = scene(cell)
      out[j].score -=
        0.5 * out[j].face * (1 - min(1, kind.people / 0.7)) + 0.5 * kind.flat + 0.3 * min(1, subtitleText(cell) / 0.02)
    }
    out[0..<few].sort { $0.score > $1.score }
    return out
  }

  /// Vision's labels for flat things: documents, screens, maps.
  nonisolated static let flatLabels: Set<String> = [
    "document", "screenshot", "newspaper", "handwriting", "receipt", "map", "credit_card", "gift_card", "checkbook", "play_card",
  ]

  /// What a picture is of, as Vision sees it: people (0...1), and flat things
  /// (documents, screens; 0...1). A television counts only when Vision is
  /// fairly sure of it (a face on a TV scores 0.5 or more): rooms often have
  /// one at the back, which scores up to 0.07.
  nonisolated static func scene(_ image: CGImage) -> (people: Double, flat: Double) {
    let request = VNClassifyImageRequest()
    do {
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
      return (1, 0)
    }
    var people = 0.0, flat = 0.0
    for o in request.results ?? [] {
      if o.identifier == "people" {
        people = Double(o.confidence)
      } else if flatLabels.contains(o.identifier) || (o.identifier == "television" && o.confidence >= 0.2) {
        flat += Double(o.confidence)
      }
    }
    return (people, min(1, flat))
  }

  /// Of the full-size frames, the one that looks like the preview frame
  /// chosen (nil if none does, unless `exact`: the frame at its time), saved
  /// as the video's still with the faces in it.
  nonisolated static func keep(_ paths: [String], pick: PreviewPick, base: String, exact: Bool) -> StillInfo? {
    var chosen: (image: CGImage, difference: Double)?
    for path in paths {
      guard let image = load(path), let l = look(image) else { continue }
      let d = difference(l, pick.look)
      if chosen == nil || d < chosen!.difference { chosen = (image, d) }
    }
    // Compression and scaling differ by about 0.02; another shot by 0.08 or more.
    guard let chosen, exact || chosen.difference < 0.05, let px = Pixels(chosen.image) else { return nil }
    let faces = vision(chosen.image, box: pixels(pick.box, px)).faces.map(\.rect)
    let info = StillInfo(v: StillInfo.version, t: pick.time, score: pick.score, box: pick.box, faces: faces)
    guard writeJPEG(chosen.image, to: "\(base).jpg", quality: 0.92), let json = try? JSONEncoder().encode(info) else { return nil }
    return FileManager.default.createFile(atPath: "\(base).json", contents: json) ? info : nil
  }

  /// `count` moments spread over a video: the best preview frame in each part of it.
  nonisolated static func spread(manifest m: TrickplayManifest, sheets: [String], markers mk: Markers?, count: Int) -> [Double] {
    let (frames, _) = candidates(manifest: m, sheets: sheets, markers: mk, limit: 240)
    guard !frames.isEmpty, count > 0 else { return [] }
    var out: [Double] = []
    let per = Double(frames.count) / Double(count)
    for k in 0..<count {
      let lo = Int(Double(k) * per), hi = max(lo + 1, Int(Double(k + 1) * per))
      guard lo < frames.count else { break }
      if let best = frames[lo..<min(frames.count, hi)].max(by: { $0.score < $1.score }), best.score >= 0, out.last != best.time {
        out.append(best.time)
      }
    }
    return out
  }

  struct Face {
    /// x, y, width, height as fractions of the picture, from the top left.
    let rect: [Double]
    let quality: Double
  }

  nonisolated static func faceScore(_ f: Face) -> Double { StillMath.faceScore(quality: f.quality, height: f.rect[3]) }

  /// Faces (with how good a picture of each one it is) and how much of the
  /// picture is readable text (captions, signs), looking only inside `box`.
  nonisolated static func vision(_ image: CGImage, box: PixelRect) -> (faces: [Face], text: Double) {
    guard box.w > 8, box.h > 8, let inner = image.cropping(to: CGRect(x: box.x, y: box.y, width: box.w, height: box.h)) else { return ([], 0) }
    let faces = VNDetectFaceCaptureQualityRequest()
    let text = textRequest(.fast)
    do {
      try VNImageRequestHandler(cgImage: inner, options: [:]).perform([faces, text])
    } catch {
      return ([], 0)
    }
    // Vision counts from the bottom left, in fractions of the part it looked at.
    let W = Double(image.width), H = Double(image.height)
    let found = (faces.results ?? []).map { o -> Face in
      let b = o.boundingBox
      let x = Double(box.x) + b.minX * Double(box.w), y = Double(box.y) + (1 - b.maxY) * Double(box.h)
      return Face(rect: [x / W, y / H, b.width * Double(box.w) / W, b.height * Double(box.h) / H], quality: o.faceCaptureQuality.map(Double.init) ?? 0.3)
    }
    return (found, textArea(text))
  }

  /// How much of a picture (0...1) is subtitles burnt into the video: lines
  /// centred in its lower part. They are small, so this reads with care
  /// (slower than the quick reading, which misses them). Text elsewhere, on
  /// signs and posters, belongs to the scene.
  nonisolated static func subtitleText(_ image: CGImage) -> Double {
    let text = textRequest(.accurate)
    do {
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([text])
    } catch {
      return 0
    }
    // Vision counts from the bottom left.
    return textArea(text) { b in b.midY < 0.3 && abs(b.midX - 0.5) < 0.15 }
  }

  nonisolated static func textRequest(_ level: VNRequestTextRecognitionLevel) -> VNRecognizeTextRequest {
    let text = VNRecognizeTextRequest()
    text.recognitionLevel = level
    text.usesLanguageCorrection = false
    return text
  }

  /// The part of the picture (0...1) covered by the lines read with some
  /// confidence that hold at least three letters or digits (and lie `where`).
  nonisolated static func textArea(_ text: VNRecognizeTextRequest, where place: (CGRect) -> Bool = { _ in true }) -> Double {
    let words = (text.results ?? []).filter { o in
      guard place(o.boundingBox), let best = o.topCandidates(1).first, best.confidence >= 0.5 else { return false }
      return best.string.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count >= 3
    }
    return words.reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
  }

  nonisolated static func fractions(_ r: PixelRect, _ p: Pixels) -> [Double] {
    [Double(r.x) / Double(p.width), Double(r.y) / Double(p.height), Double(r.w) / Double(p.width), Double(r.h) / Double(p.height)]
  }

  nonisolated static func pixels(_ box: [Double], width: Int, height: Int) -> PixelRect {
    guard box.count == 4 else { return PixelRect(x: 0, y: 0, w: width, h: height) }
    let x = Int((box[0] * Double(width)).rounded()), y = Int((box[1] * Double(height)).rounded())
    return PixelRect(
      x: x, y: y, w: min(width - x, Int((box[2] * Double(width)).rounded())), h: min(height - y, Int((box[3] * Double(height)).rounded())))
  }

  nonisolated static func pixels(_ box: [Double], _ p: Pixels) -> PixelRect { pixels(box, width: p.width, height: p.height) }

  nonisolated static func read(_ path: String) -> StillInfo? {
    guard let raw = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(StillInfo.self, from: raw)
  }

  /// Cuts `shape` from a still and scales it to `width` (Lanczos, then a little sharpening when enlarged).
  nonisolated static func cut(_ image: CGImage, info: StillInfo, shape: StillShape, width: Int, out: String) -> Bool {
    let r = StillMath.crop(width: image.width, height: image.height, box: info.box, faces: info.faces, shape: shape)
    guard r.width >= 8, r.height >= 8 else { return false }
    // Beyond twice its size a picture only gets bigger, not better.
    let w = min(Double(width), (r.width * 2).rounded())
    let scale = w / r.width
    let h = (w / shape.aspect).rounded()
    // CoreImage counts from the bottom left.
    var img = CIImage(cgImage: image).cropped(to: CGRect(x: r.minX, y: Double(image.height) - r.maxY, width: r.width, height: r.height))
    img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { return false }
    lanczos.setValue(img, forKey: kCIInputImageKey)
    lanczos.setValue(scale, forKey: kCIInputScaleKey)
    lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
    guard var scaled = lanczos.outputImage else { return false }
    if scale > 1.05, let sharpen = CIFilter(name: "CIUnsharpMask") {
      sharpen.setValue(scaled, forKey: kCIInputImageKey)
      sharpen.setValue(min(2.5, 0.8 * scale), forKey: kCIInputRadiusKey)
      sharpen.setValue(0.35, forKey: kCIInputIntensityKey)
      scaled = sharpen.outputImage ?? scaled
    }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
    let ctx = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
    guard let cg = ctx.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: space) else {
      return false
    }
    return writeJPEG(cg, to: out, quality: 0.88)
  }

  nonisolated static func load(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
  }

  /// Writes a JPEG beside `path`, then moves it into place.
  nonisolated static func writeJPEG(_ image: CGImage, to path: String, quality: Double) -> Bool {
    let tmp = "\(path).\(getpid()).part"
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: tmp) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
      return false
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
      removeItem(tmp)
      return false
    }
    return rename(tmp, path) == 0
  }
}
