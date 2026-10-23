import CoreText
import Foundation
import Vision

@MainActor func stillsTests(_ t: Tests) {
  /// A mid-grey picture with black bars: `top`/`bottom` rows and `side` columns on each side.
  func barred(_ w: Int, _ h: Int, top: Int = 0, bottom: Int = 0, side: Int = 0) -> Pixels {
    Pixels(width: w, height: h) { x, y in
      if y < top || y >= h - bottom || x < side || x >= w - side { return (0, 0, 0) }
      let v = UInt8(90 + (x * 7 + y * 3) % 80)
      return (v, v, v)
    }
  }
  let whole = { (p: Pixels) in PixelRect(x: 0, y: 0, w: p.width, h: p.height) }

  t.test("finds the picture inside letterbox bars") {
    let p = barred(160, 90, top: 12, bottom: 12)
    try expectEqual(StillMath.contentBox(p, whole(p)), PixelRect(x: 0, y: 12, w: 160, h: 66))
  }

  t.test("finds the picture inside pillarbox bars") {
    let p = barred(160, 90, side: 20)
    try expectEqual(StillMath.contentBox(p, whole(p)), PixelRect(x: 20, y: 0, w: 120, h: 90))
  }

  t.test("a dark row or two at the edge is not a bar") {
    let p = barred(160, 90, top: 1)
    try expectEqual(StillMath.contentBox(p, whole(p)), whole(p))
  }

  t.test("looks for bars only inside the frame asked about (a cell of a sheet)") {
    // Two 80×45 cells side by side, the right one with 5-row bars.
    let p = Pixels(width: 160, height: 45) { x, y in
      if x >= 80 && (y < 5 || y >= 40) { return (0, 0, 0) }
      return (128, 128, 128)
    }
    try expectEqual(StillMath.contentBox(p, PixelRect(x: 80, y: 0, w: 80, h: 45)), PixelRect(x: 80, y: 5, w: 80, h: 35))
    try expectEqual(StillMath.contentBox(p, PixelRect(x: 0, y: 0, w: 80, h: 45)), PixelRect(x: 0, y: 0, w: 80, h: 45))
  }

  t.test("never takes a black frame, and finds a detailed frame sharper than a smooth one") {
    let black = Pixels(width: 64, height: 36) { _, _ in (0, 0, 0) }
    try expect(StillMath.stats(black, whole(black)).unusable, "a black frame was usable")
    let smooth = Pixels(width: 64, height: 36) { x, _ in let v = UInt8(60 + x * 2); return (v, v, v) }
    let detailed = Pixels(width: 64, height: 36) { x, y in (x + y) % 2 == 0 ? (60, 60, 60) : (190, 190, 190) }
    let a = StillMath.stats(smooth, whole(smooth)), b = StillMath.stats(detailed, whole(detailed))
    try expect(!a.unusable && !b.unusable, "an ordinary frame was unusable")
    try expect(b.sharpness > a.sharpness * 10, "sharpness \(b.sharpness) vs \(a.sharpness)")
  }

  t.test("ranks values from 0 to 1") {
    try expectEqual(StillMath.ranks([3, 1, 2]), [1, 0, 0.5])
    try expectEqual(StillMath.ranks([7]), [1])
  }

  t.test("counts large, clear faces more than small or poor ones") {
    try expectEqual(StillMath.faceScore(quality: 0.3, height: 0.3), 1)
    try expectEqual(StillMath.faceScore(quality: 0, height: 0.3), 0.4)
    try expectEqual(StillMath.faceScore(quality: 0.8, height: 0.03), 0.2)
    try expect(StillMath.faceScore(quality: 0.8, height: 0.12) < StillMath.faceScore(quality: 0.8, height: 0.2), "size didn't count")
  }

  t.test("counts the two largest faces when choosing between videos") {
    try expectEqual(StillMath.people([]), 0)
    try expectEqual(StillMath.people([[0.2, 0.2, 0.2, 0.3]]), 1)
    let two = StillMath.people([[0.1, 0.2, 0.1, 0.09], [0.2, 0.2, 0.2, 0.3], [0.7, 0.1, 0.02, 0.03]])
    try expect(abs(two - 1.4) < 1e-9, "two faces: \(two)")
    try expectEqual(StillMath.people([[0, 0, 0.3, 0.3], [0.5, 0, 0.3, 0.3], [0.2, 0.5, 0.3, 0.3]]), 1.5)
  }

  t.test("cuts the middle of a picture without faces") {
    let r = StillMath.crop(width: 640, height: 480, box: [0, 0, 1, 1], faces: [], shape: .card)
    try expectEqual(r, CGRect(x: 0, y: 60, width: 640, height: 360))
  }

  t.test("cuts around a face, kept inside the picture") {
    // A face near the top of a 4:3 picture: the cut goes as high as it can.
    let high = StillMath.crop(width: 640, height: 480, box: [0, 0, 1, 1], faces: [[0.4, 0.05, 0.2, 0.2]], shape: .card)
    try expectEqual(high, CGRect(x: 0, y: 0, width: 640, height: 360))
    // A face lower down sits a little above the middle of the cut.
    let mid = StillMath.crop(width: 640, height: 480, box: [0, 0, 1, 1], faces: [[0.4, 0.3, 0.2, 0.2]], shape: .card)
    try expectEqual(mid, CGRect(x: 0, y: 48, width: 640, height: 360))
    // A face at the right of a wide picture, cut as a poster: as far right as it goes.
    let right = StillMath.crop(width: 1920, height: 1080, box: [0, 0, 1, 1], faces: [[0.8, 0.3, 0.1, 0.2]], shape: .poster)
    try expectEqual(right, CGRect(x: 1200, y: 0, width: 720, height: 1080))
  }

  t.test("leaves the bars out of a cut") {
    let r = StillMath.crop(width: 1920, height: 1080, box: [0, 0.125, 1, 0.75], faces: [], shape: .card)
    try expectEqual(r, CGRect(x: 240, y: 135, width: 1440, height: 810))
    // A box too small to be right is ignored.
    let bad = StillMath.crop(width: 1920, height: 1080, box: [0, 0, 0.1, 0.1], faces: [], shape: .card)
    try expectEqual(bad, CGRect(x: 0, y: 0, width: 1920, height: 1080))
  }

  t.test("finds subtitles as small as a preview frame shows them, but not a sign higher up or an empty frame") {
    /// A 240×132 preview frame, grey, with these lines centred in 8-pixel white
    /// type, the first one's baseline `y` pixels from the bottom.
    func frame(_ lines: [String], y: Int = 16) throws -> CGImage {
      let w = 240, h = 132
      guard
        let ctx = CGContext(
          data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { throw TestFailure(description: "no context") }
      ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
      let font = CTFontCreateWithName("Helvetica" as CFString, 8, nil)
      for (i, s) in lines.enumerated() {
        let text = NSAttributedString(
          string: s,
          attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
          ])
        let line = CTLineCreateWithAttributedString(text)
        ctx.textPosition = CGPoint(x: (Double(w) - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y: Double(y - 10 * i))
        CTLineDraw(line, ctx)
      }
      guard let image = ctx.makeImage() else { throw TestFailure(description: "no image") }
      return image
    }
    let subtitles = Stills.subtitleText(try frame(["Think hard about your future,", "Mr. Pillar of the Community."]))
    try expect(subtitles > 0.01, "read \(subtitles) of the frame as subtitles")
    // The sign is readable, but it isn't where subtitles go.
    let sign = try frame(["PASTRIES AND CAPPUCCINO"], y: 110)
    let anywhere = Stills.textRequest(.accurate)
    try VNImageRequestHandler(cgImage: sign, options: [:]).perform([anywhere])
    try expect(Stills.textArea(anywhere) > 0.005, "the sign wasn't read at all")
    try expectEqual(Stills.subtitleText(sign), 0)
    try expectEqual(Stills.subtitleText(try frame([])), 0)
  }
}
