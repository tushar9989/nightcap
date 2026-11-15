import CoreImage
import CoreVideo
import Foundation

// Tune Picture: how much colour a title's picture gets, chosen from frames of
// its own episodes rather than by eye.
//
// Frames are taken across the series (up to `maxEpisodes` episodes, `framesPerEpisode`
// each) and looked at as the player shows them: full-range R'G'B' shown with the
// display gamma (VideoGamma, below). For each saturation step the player could use
// (CIColorControls on the picture: a mix with each pixel's luminance, in linear
// light), three things are measured on every frame:
//   - colourfulness, Hasler & Süsstrunk's metric (2003), whose scale reads
//     15 "slightly", 33 "moderately", 45 "averagely" colourful;
//   - clipping: pixels with a channel at or past full brightness, or pushed more
//     than a few levels below black outside the deepest shadows (detail or hue lost
//     there; in the deepest shadows any trace of colour dips below zero, unseen);
//   - the chroma (CIELAB C*) of skin-like tones: the colour people judge most
//     closely, and the first to look wrong (orange) when pushed.
// The step chosen is the strongest that keeps clipping where it was (the mean
// over frames up by at most `maxMeanClipRise` points, the 95th percentile frame by
// at most `maxP95ClipRise`), keeps the median skin-like tone within natural skin
// (C* at most `maxSkinChroma`: measured skin has b* up to about 25 and a* about
// 15, Chardon et al.), and does not push the series past "moderately colourful".
// A series already at least moderately colourful is left alone.
// Black level, peak white and the tint of near-neutral areas are measured too and
// reported, not changed: the player shows them as the source has them.

enum PictureTune {
  static let maxEpisodes = 6
  static let framesPerEpisode = 8
  static let frameWidth = 480
  static let steps: [Double] = [1.0, 1.05, 1.1, 1.15, 1.2, 1.25, 1.3, 1.35, 1.4]
  static let moderatelyColourful = 33.0
  static let maxMeanClipRise = 0.25
  static let maxP95ClipRise = 1.5
  /// Below-black clipping counts past this many levels (0...255), above this luminance level.
  static let belowBlackLevels = 4.0
  static let deepShadow = 24.0
  /// Natural skin's chroma, at most (CIELAB C*).
  static let maxSkinChroma = 30.0
  /// Skin-like tones are looked at when at least this share of the pixels (percent).
  static let minSkinShare = 0.5

  /// One frame as shown: full-range R'G'B', 3 bytes a pixel.
  struct Frame {
    let width: Int
    let height: Int
    let rgb: [UInt8]
  }

  struct Step: Codable, Equatable {
    var saturation: Double
    /// Median colourfulness over the frames.
    var colourfulness: Double
    /// Percent of pixels clipped: mean over the frames, and the 95th percentile frame.
    var meanClip: Double
    var p95Clip: Double
    /// Median CIELAB chroma of the skin-like tones, and their share of the pixels (percent).
    var skinChroma: Double = 0
    var skinShare: Double = 0
  }

  struct Result: Codable, Equatable {
    /// What the player uses: 1 leaves the picture as it is.
    var saturation: Double
    var reason: String
    var steps: [Step]
    var episodes: Int
    var frames: Int
    /// Medians over the frames, 0...255: the darkest 1% and the brightest 0.5% of each.
    var blackLevel: Double
    var peakWhite: Double
    /// Tint of near-neutral areas (R−G and B−G, 0...255 levels; 0 is neutral).
    var tintRG: Double
    var tintBG: Double
    var tunedAt: Int64
  }

  // ---- Measuring ---------------------------------------------------------------------------

  /// Light (0...1) of each source level as the player shows it (VideoGamma), and back to
  /// screen levels (sRGB), where colourfulness and clipping are measured.
  private static let toLinear: [Double] = (0..<256).map { VideoGamma.light(Double($0) / 255) }
  private static let lutSize = 4096
  private static let toCode: [UInt8] = (0..<4096).map { i in
    UInt8(max(0, min(255, (255 * VideoGamma.srgbEncode(Double(i) / 4095)).rounded())))
  }

  /// What one frame measures at one saturation.
  struct Measure {
    var colourfulness: Double
    var clip: Double
    /// Skin-like tones (picked by their colour as decoded) by CIELAB chroma, in half units.
    var skin: [Int]
  }

  static let skinBins = 200

  /// CIELAB of linear light in BT.709/sRGB primaries, white 1 (D65).
  static func lab(_ r: Double, _ g: Double, _ b: Double) -> (l: Double, a: Double, b: Double) {
    let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
    let fy = f(y)
    return (116 * fy - 16, 500 * (f(x) - fy), 200 * (fy - f(z)))
  }

  /// Skin-like: CIELAB hue between red-orange and yellow-orange, neither near-black nor
  /// near-white, some colour but not vivid (skin's range, wide).
  static func isSkinLike(_ c: (l: Double, a: Double, b: Double)) -> Bool {
    guard c.l >= 20 && c.l <= 90, c.a > 0, c.b > 0 else { return false }
    let chroma = hypot(c.a, c.b), hue = atan2(c.b, c.a) * 180 / .pi
    return chroma >= 6 && chroma <= 50 && hue >= 25 && hue <= 75
  }

  /// Colourfulness, clipping and skin-like chroma of `f` with saturation `s`.
  static func measure(_ f: Frame, saturation s: Double) -> Measure {
    let n = f.width * f.height
    var skin = [Int](repeating: 0, count: skinBins)
    guard n > 0 else { return Measure(colourfulness: 0, clip: 0, skin: skin) }
    var srg = 0.0, syb = 0.0, srg2 = 0.0, syb2 = 0.0
    var clipped = 0
    func code(_ v: Double) -> Double { Double(toCode[Int(max(0, min(1, v)) * Double(lutSize - 1))]) }
    f.rgb.withUnsafeBufferPointer { p in
      for i in 0..<n {
        let r0 = toLinear[Int(p[3 * i])], g0 = toLinear[Int(p[3 * i + 1])], b0 = toLinear[Int(p[3 * i + 2])]
        var r = r0, g = g0, b = b0
        if s != 1 {
          let y = 0.2126 * r0 + 0.7152 * g0 + 0.0722 * b0
          r = y + s * (r0 - y); g = y + s * (g0 - y); b = y + s * (b0 - y)
        }
        // Clipped where it shows: at or past white, or a channel pushed more than a few levels
        // below black outside the deepest shadows (there a trace of colour always dips below
        // zero, unseen).
        let R = code(r), G = code(g), B = code(b)
        let lowest = min(r, g, b)
        let below = lowest < 0 && code(-lowest) > belowBlackLevels && code(0.2126 * r + 0.7152 * g + 0.0722 * b) >= deepShadow
        if below || R >= 254 || G >= 254 || B >= 254 || max(r, g, b) > 1 { clipped += 1 }
        let rg = R - G, yb = 0.5 * (R + G) - B
        srg += rg; syb += yb; srg2 += rg * rg; syb2 += yb * yb
        // Every 4th pixel is enough for the skin-like tones.
        if i % 4 == 0, p[3 * i] > p[3 * i + 2], isSkinLike(lab(r0, g0, b0)) {
          let c = lab(max(0, min(1, r)), max(0, min(1, g)), max(0, min(1, b)))
          skin[min(skinBins - 1, Int(2 * hypot(c.a, c.b)))] += 1
        }
      }
    }
    let N = Double(n)
    let mrg = srg / N, myb = syb / N
    let sd = (max(0, srg2 / N - mrg * mrg) + max(0, syb2 / N - myb * myb)).squareRoot()
    return Measure(colourfulness: sd + 0.3 * (mrg * mrg + myb * myb).squareRoot(), clip: 100 * Double(clipped) / N, skin: skin)
  }

  /// Levels and tint of `f`, as shown.
  static func levels(_ f: Frame) -> (black: Double, white: Double, rg: Double, bg: Double, neutral: Int) {
    var hist = [Int](repeating: 0, count: 256)
    var rg = 0.0, bg = 0.0, neutral = 0
    let n = f.width * f.height
    for i in 0..<n {
      let r = Int(f.rgb[3 * i]), g = Int(f.rgb[3 * i + 1]), b = Int(f.rgb[3 * i + 2])
      let y = (2126 * r + 7152 * g + 722 * b) / 10000
      hist[y] += 1
      if y >= 60 && y <= 235 && max(r, g, b) - min(r, g, b) < 24 {
        rg += Double(r - g); bg += Double(b - g); neutral += 1
      }
    }
    func pct(_ q: Double) -> Double {
      let want = Int(Double(n) * q)
      var sum = 0
      for (v, c) in hist.enumerated() {
        sum += c
        if sum > want { return Double(v) }
      }
      return 255
    }
    return (pct(0.01), pct(0.995), neutral > 0 ? rg / Double(neutral) : 0, neutral > 0 ? bg / Double(neutral) : 0, neutral)
  }

  static func median(_ a: [Double]) -> Double {
    guard !a.isEmpty else { return 0 }
    let s = a.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
  }

  static func percentile(_ a: [Double], _ q: Double) -> Double {
    guard !a.isEmpty else { return 0 }
    let s = a.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
  }

  /// Measures every step on `frames` and chooses one.
  static func choose(_ frames: [Frame], episodes: Int, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Result {
    let pixels = frames.reduce(0) { $0 + $1.width * $1.height }
    let measured = steps.map { s in
      let m = frames.map { measure($0, saturation: s) }
      var skin = [Int](repeating: 0, count: skinBins)
      for f in m { for (i, c) in f.skin.enumerated() { skin[i] += c } }
      let count = skin.reduce(0, +)
      var sum = 0, med = 0.0
      for (i, c) in skin.enumerated() {
        sum += c
        if 2 * sum >= count && count > 0 { med = (Double(i) + 0.5) / 2; break }
      }
      return Step(
        saturation: s, colourfulness: median(m.map(\.colourfulness)),
        meanClip: m.isEmpty ? 0 : m.map(\.clip).reduce(0, +) / Double(m.count), p95Clip: percentile(m.map(\.clip), 0.95),
        skinChroma: med, skinShare: pixels > 0 ? 100 * 4 * Double(count) / Double(pixels) : 0)
    }
    let base = measured[0]
    var chosen = base
    var reason: String
    if frames.isEmpty {
      reason = "No frames could be read"
    } else if base.colourfulness >= moderatelyColourful {
      reason = String(format: "Already colourful (%.0f, \"moderately\" is 33): left as it is", base.colourfulness)
    } else {
      var stop = ""
      for s in measured.dropFirst() {
        if s.meanClip - base.meanClip > maxMeanClipRise || s.p95Clip - base.p95Clip > maxP95ClipRise {
          stop = String(format: "more would clip highlights or colours (×%.2f: %.1f%% of pixels, was %.1f%%)", s.saturation, s.p95Clip, base.p95Clip)
          break
        }
        if base.skinShare >= minSkinShare && s.skinChroma > max(maxSkinChroma, base.skinChroma) {
          stop = String(format: "more would push skin tones past natural skin (chroma %.0f; skin reaches about %.0f)", s.skinChroma, maxSkinChroma)
          break
        }
        if s.colourfulness > moderatelyColourful {
          stop = "more would go past \"moderately colourful\""
          break
        }
        chosen = s
      }
      if stop.isEmpty { stop = "the strongest step tried" }
      reason = chosen.saturation == 1
        ? "Left as it is: \(stop)"
        : String(format: "Colourfulness %.0f → %.0f; %@", base.colourfulness, chosen.colourfulness, stop)
    }
    let lv = frames.map(levels)
    let tinted = lv.filter { $0.neutral > 200 }
    return Result(
      saturation: chosen.saturation, reason: reason, steps: measured, episodes: episodes, frames: frames.count,
      blackLevel: median(lv.map(\.black)), peakWhite: median(lv.map(\.white)),
      tintRG: median(tinted.map(\.rg)), tintBG: median(tinted.map(\.bg)), tunedAt: now)
  }

  // ---- Reading frames ----------------------------------------------------------------------

  /// The episodes looked at: up to `maxEpisodes`, spread over the list.
  static func pick<T>(_ all: [T]) -> [T] {
    guard all.count > maxEpisodes else { return all }
    return (0..<maxEpisodes).map { all[$0 * (all.count - 1) / (maxEpisodes - 1)] }
  }

  private struct Probe: Decodable {
    struct Stream: Decodable {
      var height: Int?
      var color_space: String?
      var color_range: String?
    }
    struct Format: Decodable { var duration: String? }
    var streams: [Stream]?
    var format: Format?
  }

  /// Frames of one video, spread through it (past the opening, before the credits).
  static func frames(_ path: String) async throws -> [Frame] {
    guard let ffmpeg = Tools.ffmpeg, let ffprobe = Tools.ffprobe else { throw EngineError("ffmpeg is not installed", 500) }
    let pr = try await runTool(
      ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=height,color_space,color_range:format=duration",
                "-of", "json", path], timeout: 30, background: true, pausable: true)
    guard pr.code == 0, let probe = try? JSONDecoder().decode(Probe.self, from: pr.stdout),
      let dur = probe.format?.duration.flatMap(Double.init), dur > 30, let st = probe.streams?.first
    else { return [] }
    // The matrix and range the player uses (ncdecoder.c): untagged HD is BT.709, SD BT.601.
    let space = st.color_space ?? "unknown"
    let matrix = space == "bt709" ? "bt709" : ["bt470bg", "smpte170m"].contains(space) ? "bt601" : (st.height ?? 1080) >= 720 ? "bt709" : "bt601"
    let range = st.color_range == "pc" ? "pc" : "tv"
    var out: [Frame] = []
    for i in 0..<framesPerEpisode {
      let t = dur * (0.06 + 0.84 * (Double(i) + 0.5) / Double(framesPerEpisode))
      let r = try await runTool(
        ffmpeg, ["-nostdin", "-v", "error", "-ss", String(format: "%.2f", t), "-i", path, "-frames:v", "1", "-an", "-sn",
                 "-vf", "scale=\(frameWidth):-2:in_color_matrix=\(matrix):in_range=\(range):out_range=pc,format=rgb24",
                 "-f", "rawvideo", "pipe:1"], timeout: 60, background: true, pausable: true)
      let bytes = r.stdout.count
      guard r.code == 0, bytes >= frameWidth * 3, bytes % (frameWidth * 3) == 0 else { continue }
      out.append(Frame(width: frameWidth, height: bytes / (frameWidth * 3), rgb: [UInt8](r.stdout)))
    }
    return out
  }

  /// Tunes a title from its episodes' files (in play order). `progress` gets episodes done of all.
  static func tune(_ paths: [String], progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> Result {
    let chosen = pick(paths)
    var frames: [Frame] = []
    var episodes = 0
    for (i, p) in chosen.enumerated() {
      let f = try await self.frames(p)
      if !f.isEmpty { episodes += 1 }
      frames += f
      await progress(i + 1, chosen.count)
    }
    let all = frames, n = episodes
    return await Task.detached(priority: .utility) { choose(all, episodes: n) }.value
  }
}

// ---- The display gamma ---------------------------------------------------------------------------

/// How SDR video's brightness is shown: ITU-R BT.1886, the display curve for HD video,
/// with gamma `target` (2.4) for a display whose black is `1/contrast` of its white. With
/// true black (mini-LED, OLED) that is a pure power law; on an LCD, around 1000:1, the
/// standard lifts the deepest shadows so they are not lost in the panel's own black.
///
/// macOS shows SDR video as sRGB once ncdecoder.c tags it with a plain gamma (measured on
/// screen: each level shown at its own value as sRGB); the player's curve re-maps it from
/// there. `defaults write local.nightcap.app videoGamma -float 2.2` for a lighter picture
/// (0: leave it as sRGB); `videoContrast` sets the display's contrast (0: true black).
enum VideoGamma {
  static let defaultTarget = 2.4
  /// An LCD's contrast: what the Mac's IPS panels manage, about 1000:1.
  static let lcdContrast = 1000.0

  /// The display's contrast, from its HDR headroom (setDisplay); 0: true black.
  nonisolated(unsafe) static var detectedContrast = lcdContrast

  /// A screen with HDR headroom of 8 or more (mini-LED with local dimming, OLED) has black
  /// near zero; others (LCD, whose backlight gives at most about 2) are taken as 1000:1.
  static func setDisplay(hdrHeadroom: Double) {
    detectedContrast = hdrHeadroom >= 8 ? 0 : lcdContrast
  }

  /// The gamma wanted, 1.8...2.8; 0: no curve.
  static var target: Double {
    let d = UserDefaults.standard
    if d.bool(forKey: "appleVideoGamma") { return 0 }
    guard d.object(forKey: "videoGamma") != nil else { return defaultTarget }
    let g = d.double(forKey: "videoGamma")
    return g == 0 ? 0 : min(2.8, max(1.8, g))
  }

  static var contrast: Double {
    let d = UserDefaults.standard
    guard d.object(forKey: "videoContrast") != nil else { return detectedContrast }
    let c = d.double(forKey: "videoContrast")
    return c <= 0 ? 0 : max(50, c)
  }

  static func srgbDecode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
  static func srgbEncode(_ l: Double) -> Double { l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055 }

  /// What a source level `e` (0...1) is shown as: light from the display's black (0) to
  /// its white (1). BT.1886: L = a(V + b)^γ, with a and b set by the display's black and white.
  static func light(_ e: Double, target g: Double = target, contrast cr: Double = contrast) -> Double {
    let v = max(0, min(1, e))
    guard g > 0 else { return srgbDecode(v) }
    guard cr > 0 else { return pow(v, g) }
    let k = 1 / cr
    let kr = pow(k, 1 / g)
    let a = pow(1 - kr, g), b = kr / (1 - kr)
    return max(0, (a * pow(v + b, g) - k) / (1 - k))
  }

  /// The curve: sRGB level in, the sRGB level that shows it as `light`; nil for no curve.
  static func curveFilter(target g: Double = target, contrast cr: Double = contrast, points: Int = 1024) -> CIFilter? {
    guard g > 0, let f = CIFilter(name: "CIColorCurves"), let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var table: [Float] = []
    for i in 0..<points {
      let v = Float(srgbEncode(light(Double(i) / Double(points - 1), target: g, contrast: cr)))
      table += [v, v, v]
    }
    f.setValue(table.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCurvesData")
    f.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
    f.setValue(srgb, forKey: "inputColorSpace")
    return f
  }

  /// Whether a frame is SDR tagged with a plain gamma (what the curve is for).
  static func isGammaTagged(_ pb: CVPixelBuffer) -> Bool {
    guard let tf = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil) as? String else { return false }
    return tf == (kCVImageBufferTransferFunction_UseGamma as String)
  }
}
