import CoreMedia
import CoreVideo
import Metal
import VideoToolbox

/// How the picture is shown (Prefs.picture).
enum PictureMode: String, CaseIterable {
  /// As the file has it, scaled to the window.
  case original
  /// Doubled by Apple's super resolution.
  case sharper
  /// Doubled, then lightly sharpened.
  case sharpest

  var label: String {
    switch self {
    case .original: "Original"
    case .sharper: "Sharper"
    case .sharpest: "Sharper + sharpening"
    }
  }
}

/// Doubles standard-definition video with Apple's low-latency super resolution
/// (VideoToolbox, macOS 26: a learned 2× scaler, about 1.5 ms a frame on an M1
/// Pro), optionally followed by a light contrast-adaptive sharpening of the
/// brightness. Only the player's pump thread uses it.
///
/// The scaler takes 8-bit video-range 4:2:0 (the decoder's usual output) with
/// both sides multiples of 16, up to its maximum size (960 a side here); other
/// sizes are padded by repeating the edge, and the result is cut back.
/// Starting the scaler for a size (0.2–0.6 s) and building the sharpening
/// kernel (0.4 s) happen in the background: until they are ready, frames are
/// shown as they are.
final class Upscaler {
  enum Status: Equatable {
    /// The setting is off.
    case off
    /// The scaler is starting: frames are shown as they are for now.
    case starting
    /// The picture is shown at this size.
    case doubled(width: Int, height: Int)
    /// The setting is on but can't be applied to this video.
    case unavailable(String)
  }

  private struct Size: Hashable {
    var width = 0, height = 0
  }

  /// The scaler's answer, from its completion handler.
  private final class Result: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var ok = false
  }

  private static let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  private static let failedText = "Apple’s scaler failed on this video"
  /// The sharpening and cutting step, shared by every player (built once).
  private static let finisher = Warm { Finisher() }

  /// The scaler's session for one (padded) size.
  private var session: (size: Size, warm: Warm<VTFrameProcessor>)?
  /// Sizes the scaler failed on: shown as they are from then on.
  private var failed: Set<Size> = []
  private var padPool: (Size, CVPixelBufferPool)?
  private var bigPool: (Size, CVPixelBufferPool)?
  private var outPool: (Size, CVPixelBufferPool)?

  deinit { close() }

  /// Ends the scaler's session (now, or once it has started).
  func close() {
    session?.warm.retire { $0.endSession() }
    session = nil
  }

  /// The picture to show for `src`: doubled, or `src` itself when the mode is
  /// off, the video doesn't fit the scaler, the scaler is still starting, or
  /// anything fails. With `wait`, a scaler that is starting is waited for (a
  /// paused picture shown again in the new mode).
  func process(_ src: CVPixelBuffer, mode: PictureMode, wait: Bool = false) -> (CVPixelBuffer, Status) {
    guard mode != .original else { return (src, .off) }
    guard VTLowLatencySuperResolutionScalerConfiguration.isSupported,
      let lo = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions,
      let hi = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions
    else { return (src, .unavailable("Not supported on this Mac")) }
    guard CVPixelBufferGetPixelFormatType(src) == Self.format else {
      return (src, .unavailable("Not available for this video’s colour format"))
    }
    let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
    let padded = Size(width: (w + 15) / 16 * 16, height: (h + 15) / 16 * 16)
    guard w >= Int(lo.width), h >= Int(lo.height), padded.width <= Int(hi.width), padded.height <= Int(hi.height) else {
      return (src, .unavailable("Only for standard-definition video"))
    }
    guard !failed.contains(padded) else { return (src, .unavailable(Self.failedText)) }

    if session?.size != padded {
      close()
      session = (padded, Warm {
        let p = VTFrameProcessor()
        let config = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: padded.width, frameHeight: padded.height, scaleFactor: 2)
        do { try p.startSession(configuration: config) } catch { return nil }
        return p
      })
    }
    let sharpen = mode == .sharpest
    let exact = padded.width == w && padded.height == h
    // Starting the shared step too, so that it is ready for a later choice or video.
    let finisherState = Self.finisher.state(waiting: wait && (sharpen || !exact))
    guard let warm = session?.warm else { return (src, .starting) }
    let processor: VTFrameProcessor
    switch warm.state(waiting: wait) {
    case .making: return (src, .starting)
    case .failed:
      failed.insert(padded)
      close()
      return (src, .unavailable(Self.failedText))
    case let .ready(p): processor = p
    }
    var finisher: Finisher?
    if sharpen || !exact {
      switch finisherState {
      case .making: return (src, .starting)
      case .failed: return (src, .unavailable("The sharpening step could not start"))
      case let .ready(f): finisher = f
      }
    }
    guard let out = upscale(src, w, h, padded, processor, finisher, sharpen: sharpen) else {
      failed.insert(padded)
      close()
      return (src, .unavailable(Self.failedText))
    }
    // Colour, pixel aspect and chroma siting as the decoder tagged the frame, and
    // nothing left from a frame the pooled buffer held before.
    CVBufferRemoveAllAttachments(out)
    CVBufferPropagateAttachments(src, out)
    return (out, .doubled(width: 2 * w, height: 2 * h))
  }

  private func upscale(
    _ src: CVPixelBuffer, _ w: Int, _ h: Int, _ padded: Size, _ processor: VTFrameProcessor, _ finisher: Finisher?,
    sharpen: Bool
  ) -> CVPixelBuffer? {
    let exact = padded.width == w && padded.height == h
    var source = src
    if !exact {
      guard let pad = buffer(&padPool, padded), Self.pad(src, into: pad) else { return nil }
      source = pad
    }
    guard let big = buffer(&bigPool, Size(width: 2 * padded.width, height: 2 * padded.height)),
      let sf = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: .zero),
      let df = VTFrameProcessorFrame(buffer: big, presentationTimeStamp: .zero)
    else { return nil }
    // The handler holds the parameters (and so both buffers) until the scaler is done with them.
    let result = Result()
    processor.process(parameters: VTLowLatencySuperResolutionScalerParameters(sourceFrame: sf, destinationFrame: df)) { _, error in
      result.ok = error == nil
      result.done.signal()
    }
    guard result.done.wait(timeout: .now() + 1) == .success, result.ok else { return nil }
    guard let finisher else { return big }
    // Cut the padding off and/or sharpen, into a buffer of the doubled size.
    guard let out = buffer(&outPool, Size(width: 2 * w, height: 2 * h)), finisher.finish(big, into: out, sharpen: sharpen) else {
      return nil
    }
    return out
  }

  /// A buffer of the scaler's format from `pool`, which is made again for a new size.
  private func buffer(_ pool: inout (Size, CVPixelBufferPool)?, _ size: Size) -> CVPixelBuffer? {
    if pool?.0 != size {
      pool = nil
      let attrs: [String: Any] = [
        kCVPixelBufferWidthKey as String: size.width,
        kCVPixelBufferHeightKey as String: size.height,
        kCVPixelBufferPixelFormatTypeKey as String: Self.format,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]
      var p: CVPixelBufferPool?
      guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p) == kCVReturnSuccess, let p else { return nil }
      pool = (size, p)
    }
    guard let pool else { return nil }
    var pb: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool.1, &pb) == kCVReturnSuccess else { return nil }
    return pb
  }

  /// Copies `src` into the larger `dst`, repeating its last column and row.
  private static func pad(_ src: CVPixelBuffer, into dst: CVPixelBuffer) -> Bool {
    guard CVPixelBufferLockBaseAddress(src, .readOnly) == kCVReturnSuccess else { return false }
    defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
    guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else { return false }
    defer { CVPixelBufferUnlockBaseAddress(dst, []) }
    for plane in 0..<2 {
      let bytes = plane == 0 ? 1 : 2  // Y, then Cb Cr pairs
      let sw = CVPixelBufferGetWidthOfPlane(src, plane), sh = CVPixelBufferGetHeightOfPlane(src, plane)
      let dw = CVPixelBufferGetWidthOfPlane(dst, plane), dh = CVPixelBufferGetHeightOfPlane(dst, plane)
      guard sw > 0, sh > 0, dw >= sw, dh >= sh,
        let s = CVPixelBufferGetBaseAddressOfPlane(src, plane), let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane)
      else { return false }
      let sr = CVPixelBufferGetBytesPerRowOfPlane(src, plane), dr = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
      for y in 0..<dh {
        let row = d + y * dr
        row.copyMemory(from: s + min(y, sh - 1) * sr, byteCount: sw * bytes)
        for x in sw..<dw { (row + x * bytes).copyMemory(from: row + (sw - 1) * bytes, byteCount: bytes) }
      }
    }
    return true
  }
}

/// Something slow to make (a scaler session, a compiled Metal kernel), made on
/// a background queue so that playback never waits for it.
private final class Warm<T>: @unchecked Sendable {
  enum State {
    case making
    case ready(T)
    case failed
  }

  private let lock = NSLock()
  private let made = DispatchGroup()
  private var value: State = .making
  private var retired: ((T) -> Void)?

  init(_ make: @escaping @Sendable () -> T?) {
    made.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      let v = make()
      let end = self.lock.withLock {
        self.value = v.map(State.ready) ?? .failed
        return self.retired
      }
      self.made.leave()
      if let end, let v { end(v) }
    }
  }

  /// What there is now; with `waiting`, after up to 1.5 s for it to be made.
  func state(waiting: Bool = false) -> State {
    if waiting { _ = made.wait(timeout: .now() + 1.5) }
    return lock.withLock { value }
  }

  /// Lets go of it: `end` runs now if it is made, or as soon as it is.
  func retire(_ end: @escaping (T) -> Void) {
    let now: T? = lock.withLock {
      switch value {
      case let .ready(v): return v
      case .making: retired = end
      case .failed: break
      }
      return nil
    }
    if let now { end(now) }
  }
}

/// The Metal step after the scaler: copies the doubled picture without its
/// padding, sharpening the brightness on the way when asked. One for the app;
/// players take turns.
private final class Finisher: @unchecked Sendable {
  /// How strong the sharpening is (CAS's 0...1): 0.5 is light.
  static let sharpness: Float = 0.5

  // Contrast-adaptive sharpening (after AMD FidelityFX CAS, the sharpen-only
  // path) on the luma plane. The amount follows the local contrast, measured
  // on video-range luma (16...235) stretched to 0...1; the filter is applied to
  // the values as they are, since its weights sum to 1.
  private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void cas(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float &sharpness [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
      int2 p = int2(gid);
      int2 last = int2(src.get_width() - 1, src.get_height() - 1);
      auto at = [&](int dx, int dy) { return src.read(uint2(clamp(p + int2(dx, dy), int2(0), last))).r; };
      float a = at(-1, -1), b = at(0, -1), c = at(1, -1);
      float d = at(-1, 0), e = at(0, 0), f = at(1, 0);
      float g = at(-1, 1), h = at(0, 1), i = at(1, 1);
      auto n = [](float v) { return saturate((v - 16.0 / 255.0) * (255.0 / 219.0)); };
      float mn = min(min(min(n(d), n(e)), min(n(f), n(b))), n(h));
      float mn2 = min(min(min(mn, n(a)), min(n(c), n(g))), n(i));
      mn += mn2;
      float mx = max(max(max(n(d), n(e)), max(n(f), n(b))), n(h));
      float mx2 = max(max(max(mx, n(a)), max(n(c), n(g))), n(i));
      mx += mx2;
      float amp = sqrt(saturate(min(mn, 2.0 - mx) / max(mx, 1e-5)));
      float w = amp * (-1.0 / mix(8.0, 5.0, sharpness));
      dst.write(float4(saturate(((b + d + f + h) * w + e) / (1.0 + 4.0 * w))), gid);
    }
    """

  private let lock = NSLock()
  private let queue: MTLCommandQueue
  private let cas: MTLComputePipelineState
  private let cache: CVMetalTextureCache

  init?() {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let lib = try? device.makeLibrary(source: Self.source, options: nil), let fn = lib.makeFunction(name: "cas"),
      let cas = try? device.makeComputePipelineState(function: fn)
    else { return nil }
    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
    self.queue = queue
    self.cas = cas
    self.cache = cache
  }

  /// Fills `out` from the top left of `big`: luma sharpened or copied, chroma copied.
  func finish(_ big: CVPixelBuffer, into out: CVPixelBuffer, sharpen: Bool) -> Bool {
    lock.lock()
    defer {
      CVMetalTextureCacheFlush(cache, 0)
      lock.unlock()
    }
    // Core Video's textures must live until the GPU is done with them.
    guard let bigY = texture(big, 0, .r8Unorm), let bigC = texture(big, 1, .rg8Unorm),
      let outY = texture(out, 0, .r8Unorm), let outC = texture(out, 1, .rg8Unorm),
      let cb = queue.makeCommandBuffer()
    else { return false }
    return withExtendedLifetime([bigY, bigC, outY, outC]) {
      if sharpen {
        guard let enc = cb.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(cas)
        enc.setTexture(bigY.texture, index: 0)
        enc.setTexture(outY.texture, index: 1)
        var s = Self.sharpness
        enc.setBytes(&s, length: MemoryLayout<Float>.size, index: 0)
        enc.dispatchThreads(
          MTLSize(width: outY.texture.width, height: outY.texture.height, depth: 1),
          threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
      }
      guard let blit = cb.makeBlitCommandEncoder() else { return false }
      for (from, to) in sharpen ? [(bigC, outC)] : [(bigY, outY), (bigC, outC)] {
        blit.copy(
          from: from.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
          sourceSize: MTLSize(width: to.texture.width, height: to.texture.height, depth: 1),
          to: to.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
      }
      blit.endEncoding()
      cb.commit()
      cb.waitUntilCompleted()
      return cb.status == .completed
    }
  }

  private struct PlaneTexture {
    let cv: CVMetalTexture
    let texture: MTLTexture
  }

  private func texture(_ pb: CVPixelBuffer, _ plane: Int, _ format: MTLPixelFormat) -> PlaneTexture? {
    var t: CVMetalTexture?
    let r = CVMetalTextureCacheCreateTextureFromImage(
      nil, cache, pb, nil, format, CVPixelBufferGetWidthOfPlane(pb, plane), CVPixelBufferGetHeightOfPlane(pb, plane), plane, &t)
    guard r == kCVReturnSuccess, let t, let texture = CVMetalTextureGetTexture(t) else { return nil }
    return PlaneTexture(cv: t, texture: texture)
  }
}
