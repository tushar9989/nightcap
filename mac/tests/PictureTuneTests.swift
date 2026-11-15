import CoreVideo
import Foundation

// Tune Picture (PictureTune): the measurements, and the step chosen for muted,
// colourful and clipping-prone pictures.

private func unwrap<T>(_ v: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
  guard let v else { throw TestFailure(description: "nil at \(file):\(line)") }
  return v
}

/// A frame of `w`×`h` filled by `pixel(x, y)`.
private func frame(_ w: Int = 64, _ h: Int = 36, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> PictureTune.Frame {
  var rgb: [UInt8] = []
  rgb.reserveCapacity(w * h * 3)
  for y in 0..<h {
    for x in 0..<w {
      let p = pixel(x, y)
      rgb += [p.0, p.1, p.2]
    }
  }
  return PictureTune.Frame(width: w, height: h, rgb: rgb)
}

/// Patches of the given colours, side by side.
private func patches(_ colours: [(UInt8, UInt8, UInt8)]) -> PictureTune.Frame {
  frame { x, _ in colours[x * colours.count / 64] }
}

@MainActor
func pictureTuneTests(_ t: Tests) {
  t.test("picture: gray has no colourfulness, at any saturation") {
    let gray = patches([(20, 20, 20), (90, 90, 90), (160, 160, 160), (230, 230, 230)])
    try expect(PictureTune.measure(gray, saturation: 1).colourfulness < 0.01)
    try expect(PictureTune.measure(gray, saturation: 1.4).colourfulness < 0.01)
    try expectEqual(PictureTune.measure(gray, saturation: 1.4).clip, 0)
  }

  t.test("picture: more saturation, more colourfulness") {
    let muted = patches([(120, 100, 90), (80, 95, 110), (100, 110, 80), (60, 60, 70)])
    let a = PictureTune.measure(muted, saturation: 1).colourfulness
    let b = PictureTune.measure(muted, saturation: 1.2).colourfulness
    try expect(b > a * 1.1, "\(a) -> \(b)")
  }

  t.test("picture: white highlights count as clipped; a saturated colour pushed out of range too") {
    let white = patches([(255, 255, 255), (100, 100, 100)])
    try expect(abs(PictureTune.measure(white, saturation: 1).clip - 50) < 0.01)
    let red = patches([(250, 40, 40)])
    try expectEqual(PictureTune.measure(red, saturation: 1).clip, 0)
    try expectEqual(PictureTune.measure(red, saturation: 1.4).clip, 100, "red past full, or green and blue below zero")
  }

  t.test("picture: a muted series gets more colour, a colourful one is left alone") {
    let muted = (0..<6).map { i in
      patches([(110 + UInt8(i), 100, 92), (78, 92, 108), (98, 106, 82), (50, 50, 56), (150, 140, 132)])
    }
    let r = PictureTune.choose(muted, episodes: 2)
    try expect(r.saturation > 1, r.reason)
    try expect(r.steps.first!.colourfulness < r.steps.first(where: { $0.saturation == r.saturation })!.colourfulness)

    let vivid = (0..<6).map { _ in patches([(220, 30, 30), (30, 200, 40), (40, 60, 220), (230, 210, 20)]) }
    let v = PictureTune.choose(vivid, episodes: 2)
    try expectEqual(v.saturation, 1, v.reason)
    try expect(matches(v.reason, "Already colourful"), v.reason)
  }

  t.test("picture: stops before the step where colours start to clip") {
    // Mostly muted, with a strong orange that clips once saturated a little.
    let frames = (0..<10).map { _ in
      frame { x, _ in x < 16 ? (245, 140, 40) : x < 40 ? (100, 96, 92) : (80, 88, 96) }
    }
    let r = PictureTune.choose(frames, episodes: 1)
    let base = r.steps[0]
    let chosen = r.steps.first { $0.saturation == r.saturation }!
    try expect(chosen.meanClip - base.meanClip <= PictureTune.maxMeanClipRise, "\(chosen)")
    try expect(r.saturation < PictureTune.steps.last!, r.reason)
  }

  t.test("picture: levels and the tint of near-neutral areas") {
    let f = frame { x, _ in x == 0 ? (0, 0, 0) : x == 63 ? (255, 255, 255) : (130, 120, 140) }
    let l = PictureTune.levels(f)
    try expect(l.rg == 10 && l.bg == 20, "\(l)")
  }

  t.test("picture: episodes are picked across the series") {
    try expectEqual(PictureTune.pick(Array(0..<3)), [0, 1, 2])
    try expectEqual(PictureTune.pick(Array(0..<22)), [0, 4, 8, 12, 16, 21])
  }

  t.test("picture: frames are read from a video and tuned") {
    let dir = tempDir("tune")
    let video = join(dir, "v.mkv")
    // A muted moving picture, two minutes long.
    try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=5:duration=120", "-vf", "hue=s=0.25",
                      "-c:v", "libx264", "-pix_fmt", "yuv420p", video])
    let r = try await PictureTune.tune([video])
    try expectEqual(r.frames, PictureTune.framesPerEpisode)
    try expectEqual(r.episodes, 1)
    try expect(r.saturation >= 1 && !r.reason.isEmpty, r.reason)
  }

  t.test("picture: the display gamma curve takes sRGB to a pure power law") {
    try expectEqual(VideoGamma.defaultTarget, 2.4)
    try expect(abs(VideoGamma.light(0.5, target: 2.4, contrast: 0) - pow(0.5, 2.4)) < 1e-12, "true black: a power law")
    try expect(abs(VideoGamma.light(0.5, target: 0) - VideoGamma.srgbDecode(0.5)) < 1e-12, "0: as sRGB")
    try expect(VideoGamma.curveFilter(target: 0) == nil)
    let f = try unwrap(VideoGamma.curveFilter(target: 2.4, contrast: 0, points: 5))
    let data = try unwrap(f.value(forKey: "inputCurvesData") as? Data)
    let table = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    try expectEqual(table.count, 15)
    try expectEqual(table[0], 0)
    try expect(abs(table[14] - 1) < 1e-6)
    // An sRGB level of 0.5 in, the level whose light is 0.5^2.4 out.
    try expect(abs(Double(table[6]) - VideoGamma.srgbEncode(pow(0.5, 2.4))) < 1e-6, "\(table[6])")
  }

  t.test("picture: frames tagged with a plain gamma get the curve, others not") {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
    let b = try unwrap(pb)
    try expect(!VideoGamma.isGammaTagged(b), "untagged")
    CVBufferSetAttachment(b, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
    try expect(!VideoGamma.isGammaTagged(b), "HDR")
    CVBufferSetAttachment(b, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_UseGamma, .shouldPropagate)
    try expect(VideoGamma.isGammaTagged(b))
  }

  t.test("picture: BT.1886 on a display with a black level lifts the shadows, not the ends") {
    try expect(abs(VideoGamma.light(0, target: 2.4, contrast: 1000)) < 1e-12, "black is the display's black")
    try expect(abs(VideoGamma.light(1, target: 2.4, contrast: 1000) - 1) < 1e-12)
    let shadow = VideoGamma.light(0.064, target: 2.4, contrast: 1000), pure = pow(0.064, 2.4)
    try expect(shadow > 3 * pure, "\(shadow) vs \(pure)")
    let mid = VideoGamma.light(0.5, target: 2.4, contrast: 1000)
    try expect(mid > pow(0.5, 2.4) && mid < pow(0.5, 2.0), "\(mid)")
    VideoGamma.setDisplay(hdrHeadroom: 16)
    try expectEqual(VideoGamma.detectedContrast, 0)
    VideoGamma.setDisplay(hdrHeadroom: 2)
    try expectEqual(VideoGamma.detectedContrast, VideoGamma.lcdContrast)
  }

  t.test("picture: skin tones are found, and stop the boost before they go orange") {
    try expect(PictureTune.isSkinLike(PictureTune.lab(0.55, 0.38, 0.30)), "a light skin")
    try expect(!PictureTune.isSkinLike(PictureTune.lab(0.1, 0.3, 0.6)), "blue")
    try expect(!PictureTune.isSkinLike(PictureTune.lab(0.4, 0.4, 0.4)), "gray")
    // Faces fill most of every frame, already near the top of skin's chroma; the rest muted.
    let frames = (0..<8).map { _ in frame { x, _ in x < 40 ? (205, 140, 105) : (90, 92, 98) } }
    let r = PictureTune.choose(frames, episodes: 1)
    try expect(r.steps[0].skinShare > 30, "\(r.steps[0])")
    let chosen = try unwrap(r.steps.first { $0.saturation == r.saturation })
    try expect(chosen.skinChroma <= PictureTune.maxSkinChroma || r.saturation == 1, "\(chosen)")
    try expect(r.saturation < PictureTune.steps.last!, r.reason)
  }
}
