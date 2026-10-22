import AppKit
import ImageIO
import SwiftUI

// Pictures: title and episode art (the engine finds or makes them), and the
// preview frames made in the background (sheets of thumbnails, see Trickplay).

enum ArtSource: Hashable {
  /// A title's picture; type "card", "poster" or "backdrop".
  case title(String, type: String = "card", width: Int)
  /// A video's own picture, else a frame from it.
  case file(String, width: Int)

  var key: String {
    switch self {
    case .title(let id, let type, let w): "t:\(id):\(type):\(w)"
    case .file(let id, let w): "f:\(id):\(w)"
    }
  }

  var width: Int {
    switch self {
    case .title(_, _, let w), .file(_, let w): w
    }
  }
}

final class ImageBox {
  let image: CGImage
  init(_ image: CGImage) { self.image = image }
}

/// Decodes a picture, at most `maxPixel` on its longer side.
func decodeImage(_ path: String, maxPixel: Int) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
  else { return nil }
  let opts: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceShouldCacheImmediately: true,
  ]
  return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

/// Decodes a whole picture (preview sheets are cut into frames by pixel).
func decodeFullImage(_ path: String) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
}

@MainActor
final class ArtCache {
  static let shared = ArtCache()
  var engine: Engine?

  private let images: NSCache<NSString, ImageBox> = {
    let c = NSCache<NSString, ImageBox>()
    c.totalCostLimit = 160 << 20
    return c
  }()
  private var inflight: [String: Task<CGImage?, Never>] = [:]
  /// Pictures that couldn't be had (a drive unplugged, ffmpeg busy): asked again after a while.
  private var failed: [String: Date] = [:]

  func cached(_ src: ArtSource) -> CGImage? { images.object(forKey: src.key as NSString)?.image }

  func load(_ src: ArtSource) async -> CGImage? {
    let key = src.key
    if let hit = cached(src) { return hit }
    if let running = inflight[key] { return await running.value }
    if let at = failed[key], Date().timeIntervalSince(at) < 30 { return nil }
    guard let engine else { return nil }
    let task = Task<CGImage?, Never> { @MainActor in
      let path: String?
      switch src {
      case .title(let id, let type, let w): path = try? await engine.titleArt(id, type: type, width: Double(w))
      case .file(let id, let w): path = try? await engine.fileArt(id, width: Double(w))
      }
      guard let path else { return nil }
      let maxPixel = max(src.width, 160)
      return await Task.detached(priority: .userInitiated) { decodeImage(path, maxPixel: maxPixel) }.value
    }
    inflight[key] = task
    let image = await task.value
    inflight[key] = nil
    if let image {
      images.setObject(ImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
      failed[key] = nil
    } else {
      failed[key] = Date()
    }
    return image
  }
}

// ---- Preview frames ------------------------------------------------------------------------

@MainActor
enum Previews {
  private static var manifests: [String: (at: Date, value: TrickplayManifest?)] = [:]
  private static let sheets: NSCache<NSString, ImageBox> = {
    let c = NSCache<NSString, ImageBox>()
    c.totalCostLimit = 96 << 20
    return c
  }()
  private static var inflight: [String: Task<CGImage?, Never>] = [:]

  /// A video's preview index, or nil while it is being made (asked again after 2.5 s).
  static func manifest(_ fid: String) -> TrickplayManifest? {
    if let c = manifests[fid] {
      let age = Date().timeIntervalSince(c.at)
      if c.value != nil && age < 300 { return c.value }
      if c.value == nil && age < 2.5 { return nil }
    }
    var value: TrickplayManifest?
    if let engine = ArtCache.shared.engine, case .ready(let m)? = try? engine.previews(fid) { value = m }
    manifests[fid] = (Date(), value)
    return value
  }

  /// The frame nearest to `t`: its sheet, and where in the sheet (pixels).
  private static func place(_ m: TrickplayManifest, _ t: Double) -> (sheet: Int, rect: CGRect) {
    let i = Int(max(0, min(Double(m.count - 1), jsRound(t / m.interval))))
    let per = m.cols * m.rows
    let k = i % per
    return (i / per, CGRect(x: Double(k % m.cols) * m.width, y: Double(k / m.cols) * m.height, width: m.width, height: m.height))
  }

  private static func sheetKey(_ fid: String, _ m: TrickplayManifest, _ n: Int) -> String { "\(fid)-\(m.key)-\(n)" }

  private static func sheet(_ fid: String, _ m: TrickplayManifest, _ n: Int) async -> CGImage? {
    let key = sheetKey(fid, m, n)
    if let hit = sheets.object(forKey: key as NSString) { return hit.image }
    if let running = inflight[key] { return await running.value }
    guard let engine = ArtCache.shared.engine, let path = try? engine.previewSheet(fid, n) else { return nil }
    let task = Task.detached(priority: .userInitiated) { decodeFullImage(path) }
    inflight[key] = task
    let image = await task.value
    inflight[key] = nil
    if let image { sheets.setObject(ImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height) }
    return image
  }

  /// The frame nearest to `t`, if its sheet is already decoded.
  static func cachedFrame(_ fid: String, _ m: TrickplayManifest, _ t: Double) -> CGImage? {
    let p = place(m, t)
    return sheets.object(forKey: sheetKey(fid, m, p.sheet) as NSString)?.image.cropping(to: p.rect)
  }

  static func frame(_ fid: String, _ m: TrickplayManifest, _ t: Double) async -> CGImage? {
    let p = place(m, t)
    return await sheet(fid, m, p.sheet)?.cropping(to: p.rect)
  }

  /// Decodes every sheet ahead of time (the seek bar's thumbnails), one after another.
  static func preload(_ fid: String, _ m: TrickplayManifest) async {
    for n in 0..<m.sheets {
      if Task.isCancelled { return }
      _ = await sheet(fid, m, n)
    }
  }

  /// Moments worth showing: spread over the video, after the intro and before the credits.
  static func times(_ fid: String, _ m: TrickplayManifest, markers: MarkerPair?, count n: Int = 12) -> [Double] {
    let dur = Double(m.count - 1) * m.interval
    let from = max(markers?.intro?.end ?? 0, dur * 0.04)
    let to = min(markers?.credits?.start ?? dur, dur * 0.94)
    return (0..<n).map { from + (to - from) * (Double($0) + 0.5) / Double(n) }
  }
}

/// A slideshow of a video's preview frames, cropped to fill the space.
struct PreviewSlideshow: View {
  let fileId: String
  var every: Double = 1.1
  @Environment(AppModel.self) private var app
  @State private var frames: [CGImage] = []
  @State private var i = 0

  var body: some View {
    GeometryReader { g in
      ZStack {
        if !frames.isEmpty {
          Image(decorative: frames[i % frames.count], scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
            .id(i)
            .transition(.opacity)
        }
      }
    }
    .allowsHitTesting(false)
    .task(id: fileId) {
      guard let m = Previews.manifest(fileId) else { return }
      var out: [CGImage] = []
      for t in Previews.times(fileId, m, markers: app.markers(fileId)) {
        if let f = await Previews.frame(fileId, m, t) { out.append(f) }
        if Task.isCancelled { return }
      }
      guard !out.isEmpty else { return }
      withAnimation(.easeInOut(duration: 0.45)) { frames = out }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(every * 1e9))
        if Task.isCancelled { return }
        withAnimation(.easeInOut(duration: 0.45)) { i += 1 }
      }
    }
  }
}

// ---- The 16:9 picture box ---------------------------------------------------------------------

/// A 16:9 picture with a tinted placeholder; portrait art is shown whole over
/// a blurred copy of itself. `previewing` plays the video's preview frames over it.
struct ArtBox<Overlay: View>: View {
  let source: ArtSource?
  let seed: String
  var radius: CGFloat = Theme.radius
  var previewing: String? = nil
  var previewEvery = 1.1
  @ViewBuilder var overlay: Overlay
  @State private var image: CGImage?

  init(
    _ source: ArtSource?, seed: String, radius: CGFloat = Theme.radius, previewing: String? = nil, previewEvery: Double = 1.1,
    @ViewBuilder overlay: () -> Overlay = { EmptyView() }
  ) {
    self.source = source
    self.seed = seed
    self.radius = radius
    self.previewing = previewing
    self.previewEvery = previewEvery
    self.overlay = overlay()
    _image = State(initialValue: source.flatMap { ArtCache.shared.cached($0) })
  }

  var body: some View {
    Color.clear
      .aspectRatio(16 / 9, contentMode: .fit)
      .background(placeholder)
      .overlay { picture.allowsHitTesting(false) }
      .overlay {
        if let fid = previewing { PreviewSlideshow(fileId: fid, every: previewEvery) }
      }
      .overlay { overlay }
      .clipShape(RoundedRectangle(cornerRadius: radius))
      .contentShape(RoundedRectangle(cornerRadius: radius))
      .task(id: source) {
        guard let source else { return }
        if let hit = ArtCache.shared.cached(source) {
          image = hit
          return
        }
        let loaded = await ArtCache.shared.load(source)
        if Task.isCancelled { return }
        withAnimation(.easeOut(duration: 0.35)) { image = loaded }
      }
  }

  private var placeholder: some View {
    let hue = hashHue(seed)
    return LinearGradient(
      colors: [
        Color(hue: hue, saturation: 0.42, lightness: 0.26),
        Color(hue: (hue + 50).truncatingRemainder(dividingBy: 360), saturation: 0.45, lightness: 0.11),
      ],
      startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  @ViewBuilder private var picture: some View {
    if let image {
      Group {
        if Double(image.height) > Double(image.width) * 0.9 {
          ZStack {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
              .blur(radius: 18)
              .colorMultiply(Color(white: 0.55))
              .scaleEffect(1.2)
            Image(decorative: image, scale: 1).resizable().scaledToFit()
          }
        } else {
          Image(decorative: image, scale: 1).resizable().scaledToFill()
        }
      }
      .transition(.opacity)
    }
  }
}

/// Progress along the bottom edge of a picture.
struct ProgressEdge: View {
  var fraction: Double

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      GeometryReader { g in
        ZStack(alignment: .leading) {
          Color.black.opacity(0.45)
          Theme.accent.frame(width: g.size.width * max(0, min(1, fraction.isFinite ? fraction : 0)))
        }
      }
      .frame(height: 4)
    }
    .allowsHitTesting(false)
  }
}

/// The round play sign shown over a picture while the pointer is on it.
struct PlayHint: View {
  var visible: Bool
  var size: CGFloat = 40

  var body: some View {
    ZStack {
      LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
      Circle()
        .fill(Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255).opacity(0.7))
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        .overlay {
          Image(systemName: "play.fill").font(.system(size: size * 0.42)).foregroundStyle(.white).offset(x: size * 0.04)
        }
    }
    .opacity(visible ? 1 : 0)
    .animation(.easeOut(duration: 0.2), value: visible)
    .allowsHitTesting(false)
  }
}

/// Starts a preview once the pointer has rested on a view for 300 ms, and stops it when it leaves.
struct HoverPreview: ViewModifier {
  @Binding var hovering: Bool
  @Binding var previewing: Bool

  func body(content: Content) -> some View {
    content
      .onHover { hovering = $0 }
      .task(id: hovering) {
        if hovering {
          try? await Task.sleep(nanoseconds: 300_000_000)
          if !Task.isCancelled && hovering { previewing = true }
        } else {
          previewing = false
        }
      }
  }
}

extension View {
  func hoverPreview(hovering: Binding<Bool>, previewing: Binding<Bool>) -> some View {
    modifier(HoverPreview(hovering: hovering, previewing: previewing))
  }
}
