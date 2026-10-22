import AVFoundation
import AppKit
import CoreMedia

/// Plays one file: ncdecoder.c decodes it, macOS's sample-buffer renderers show
/// and play it, and a render synchronizer keeps them on one clock (which also
/// gives speed changes with the pitch kept). A single pump thread owns the
/// decoder; the main thread only sends it commands.
final class MediaPlayer: @unchecked Sendable {
  struct AudioTrack: Equatable {
    let index: Int
    let codec, language, title: String
    let channels: Int
    let isDefault: Bool
  }

  struct Info {
    let duration: Double
    let hasVideo: Bool
    let width, height: Int
    let fps: Double
    let hardware: Bool
    let videoCodec, container: String
    let audioTracks: [AudioTrack]
    let audioIndex: Int
  }

  let displayLayer = AVSampleBufferDisplayLayer()
  private let audioRenderer = AVSampleBufferAudioRenderer()
  private let synchronizer = AVSampleBufferRenderSynchronizer()
  private var videoRenderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

  // Called on the main thread.
  var onOpen: ((Info) -> Void)?
  var onError: ((String) -> Void)?
  var onEnded: (() -> Void)?
  /// A seek (or the first picture after opening) has landed.
  var onSeeked: ((Double) -> Void)?
  /// Width / height of the picture as it should be shown.
  var onAspect: ((Double) -> Void)?

  private(set) var info: Info?
  private(set) var aspect: Double = 16.0 / 9.0
  private(set) var isPlaying = false
  private(set) var ended = false
  var rate: Float = 1 {
    didSet { send { $0.rate = self.rate } }
  }
  /// 0...2; above 1 the samples are boosted, with a limiter.
  var volume: Float = 1 {
    didSet { applyVolume() }
  }
  var isMuted = false {
    didSet { audioRenderer.isMuted = isMuted }
  }

  // Shared with the pump thread, under `cond`.
  private struct Commands {
    var path: String?
    var openAudio = -1
    var seek: (time: Double, exact: Bool)?
    var audio: Int?
    var playing = false
    var rate: Float = 1
    var gain: Float = 1
    var closing = false
    var changed = false
  }
  private let cond = NSCondition()
  private var cmd = Commands()
  private var shownTime: Double?  // while a seek is landing, the time to report
  private var thread: Thread?

  init() {
    displayLayer.videoGravity = .resize
    displayLayer.backgroundColor = NSColor.black.cgColor
    audioRenderer.audioTimePitchAlgorithm = .spectral
    synchronizer.addRenderer(audioRenderer)
    synchronizer.addRenderer(videoRenderer)
    // macOS empties the renderers itself now and then (a new audio device, a
    // display that needs its decoder reset): refill from where it happened.
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: audioRenderer, queue: .main
    ) { [weak self] note in
      guard let self, self.info != nil else { return }
      let at = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
      self.seek(to: at.map(CMTimeGetSeconds) ?? self.currentTime)
    })
    observers.append(center.addObserver(
      forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification, object: videoRenderer, queue: .main
    ) { [weak self] _ in
      guard let self, self.info != nil, self.videoRenderer.requiresFlushToResumeDecoding else { return }
      self.seek(to: self.currentTime)
    })
  }

  private var observers: [NSObjectProtocol] = []

  deinit { close() }

  // MARK: Commands (main thread)

  /// Opens a file (a player is not reused after close()).
  func open(path: String, at time: Double, audioIndex: Int? = nil, play: Bool = true) {
    isPlaying = play
    ended = false
    cond.lock()
    if cmd.closing {
      cond.unlock()
      return
    }
    cmd.changed = true
    cmd.path = path
    cmd.openAudio = audioIndex ?? -1
    cmd.seek = (max(0, time), true)
    cmd.playing = play
    cmd.rate = rate
    shownTime = max(0, time)
    cond.signal()
    cond.unlock()
    if thread == nil {
      let t = Thread { [weak self] in self?.pump() }
      t.name = "Nightcap player"
      t.qualityOfService = .userInteractive
      thread = t
      t.start()
    }
  }

  func play() {
    if ended { seek(to: 0) }
    isPlaying = true
    send { $0.playing = true }
  }

  func pause() {
    isPlaying = false
    send { $0.playing = false }
  }

  func seek(to time: Double, exact: Bool = true) {
    var t = max(0, time)
    if let d = info?.duration, d > 0 { t = min(t, max(0, d - 0.05)) }
    ended = false
    cond.lock()
    cmd.changed = true
    cmd.seek = (t, exact)
    shownTime = t
    cond.signal()
    cond.unlock()
  }

  func selectAudio(_ index: Int) {
    send { $0.audio = index }
  }

  func close() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    send { $0.closing = true }
    thread = nil
  }

  /// The picture on screen now (for tests).
  func displayedPixelBuffer() -> CVPixelBuffer? { videoRenderer.displayedPixelBuffer() }

  /// A seek (or the opening) has not landed yet.
  var isSeeking: Bool {
    cond.lock()
    defer { cond.unlock() }
    return shownTime != nil
  }

  /// The position on the file's timeline.
  var currentTime: Double {
    cond.lock()
    let shown = shownTime
    cond.unlock()
    if let shown { return shown }
    return max(0, CMTimeGetSeconds(synchronizer.currentTime()))
  }

  private func send(_ change: (inout Commands) -> Void) {
    cond.lock()
    change(&cmd)
    cmd.changed = true
    cond.signal()
    cond.unlock()
  }

  private func applyVolume() {
    audioRenderer.volume = min(1, max(0, volume))
    send { $0.gain = max(1, min(2, self.volume)) }
  }

  private func main(_ work: @escaping () -> Void) {
    DispatchQueue.main.async(execute: work)
  }

  // MARK: Pump thread

  private var dec: OpaquePointer?
  private var hasAudio = false, hasVideo = false
  private var audioIndex = -1
  private var landing = false       // a seek is filling the renderers before the clock starts
  private var target = 0.0, start = 0.0
  private var exactSeek = true
  private var gotVideo = false
  private var videoDone = false, audioDone = false
  private var videoEnd = 0.0, audioEnd = 0.0
  private var reportedEnd = false
  private var appliedPlaying = false
  private var appliedRate: Float = 1
  private var gain: Float = 1
  private var limiter: Float = 1
  private var videoFormat: CMVideoFormatDescription?
  private var audioFormat: CMAudioFormatDescription?
  private var audioFormatRate = 0
  private var lastSar = (0, 0)
  /// Audio already handed to the renderer, unboosted, so a volume change above
  /// 100% can be applied to it at once.
  private var sentAudio: [(pts: Double, rate: Int, samples: [Float])] = []

  private func pump() {
    while true {
      cond.lock()
      var c = cmd
      cmd.path = nil
      cmd.seek = nil
      cmd.audio = nil
      cmd.changed = false
      cond.unlock()
      if c.closing { break }

      if let path = c.path { openFile(path, audio: c.openAudio) }
      if dec == nil {
        idle(0.05)
        continue
      }
      if let a = c.audio, a != audioIndex, nc_select_audio(dec, Int32(a)) == 0 {
        let now = landing ? target : playheadTime()
        refreshInfo(audioIndex: a)
        if c.seek == nil { c.seek = (now, true) }
      }
      if let s = c.seek { beginSeek(s.time, exact: s.exact) }
      if c.gain != gain { changeGain(c.gain) }
      applyClock(playing: c.playing, rate: c.rate)

      var worked = false
      let now = landing ? start : playheadTime()
      let speed = Double(max(1, c.rate))
      // While a seek lands: the first picture, then enough sound to start.
      if hasVideo && !videoDone && videoRenderer.isReadyForMoreMediaData
        && (landing ? !gotVideo : videoEnd < now + 0.5 * speed) {
        pushVideo(now: now)
        worked = true
      }
      if hasAudio && !audioDone && (!landing || gotVideo || videoDone) && audioRenderer.isReadyForMoreMediaData
        && audioEnd < now + 1.0 * speed {
        pushAudio()
        worked = true
      }
      if landing { finishLandingIfReady(playing: c.playing, rate: c.rate) }
      checkEnd(now: now)
      if !worked { idle(landing ? 0.002 : 0.01) }
    }
    synchronizer.rate = 0
    videoRenderer.flush()
    audioRenderer.flush()
    if let d = dec { nc_close(d) }
    dec = nil
  }

  private static let tracing = ProcessInfo.processInfo.environment["NC_TRACE"] != nil
  private var traceStart = Date()
  private func trace(_ s: @autoclosure () -> String) {
    guard Self.tracing else { return }
    if s().hasPrefix("seek") { traceStart = Date() }
    print(String(format: "    [pump %6.1f ms] %@", Date().timeIntervalSince(traceStart) * 1000, s()))
  }

  private func idle(_ seconds: Double) {
    cond.lock()
    if !cmd.changed { cond.wait(until: Date(timeIntervalSinceNow: seconds)) }
    cond.unlock()
  }

  private func playheadTime() -> Double {
    max(0, CMTimeGetSeconds(synchronizer.currentTime()))
  }

  private func openFile(_ path: String, audio: Int) {
    synchronizer.rate = 0
    appliedPlaying = false
    videoRenderer.flush(removingDisplayedImage: true) {}
    audioRenderer.flush()
    if let d = dec { nc_close(d) }
    dec = nil
    info = nil
    var err = [CChar](repeating: 0, count: 512)
    guard let d = nc_open(path, Int32(audio), &err, Int32(err.count)) else {
      let message = String(cString: err)
      cond.lock()
      shownTime = nil
      cond.unlock()
      main { self.onError?(message.isEmpty ? "This file can't be played." : message) }
      return
    }
    dec = d
    videoFormat = nil
    audioFormat = nil
    lastSar = (0, 0)
    refreshInfo(audioIndex: nil)
  }

  private func refreshInfo(audioIndex: Int?) {
    guard let d = dec else { return }
    var i = NCInfo()
    nc_info(d, &i)
    var tracks: [AudioTrack] = []
    for n in 0..<Int(i.audioCount) {
      var t = NCAudioTrack()
      if nc_audio_track(d, Int32(n), &t) == 0 {
        tracks.append(AudioTrack(
          index: n, codec: cString(&t.codec), language: cString(&t.language), title: cString(&t.title),
          channels: Int(t.channels), isDefault: t.isDefault != 0))
      }
    }
    hasVideo = i.hasVideo != 0
    hasAudio = i.audioIndex >= 0
    self.audioIndex = Int(i.audioIndex)
    let info = Info(
      duration: i.duration, hasVideo: hasVideo, width: Int(i.width), height: Int(i.height), fps: i.fps,
      hardware: i.hardware != 0, videoCodec: cString(&i.videoCodec), container: cString(&i.container),
      audioTracks: tracks, audioIndex: Int(i.audioIndex))
    let ratio = i.height > 0 ? Double(i.width) * Double(i.sarNum) / (Double(i.height) * Double(max(1, i.sarDen))) : 16.0 / 9.0
    let first = audioIndex == nil
    main {
      self.info = info
      if first {
        self.aspect = ratio
        self.onAspect?(ratio)
        self.onOpen?(info)
      }
    }
  }

  private func beginSeek(_ time: Double, exact: Bool) {
    guard let d = dec else { return }
    trace("seek \(time)")
    // Stopping the clock costs ~35 ms while sound plays (it waits for the audio
    // device), but moving a running clock and flushing under it costs more.
    synchronizer.setRate(0, time: CMTime(seconds: time, preferredTimescale: 90000))
    appliedPlaying = false
    trace("setRate")
    videoRenderer.flush()
    trace("video flush")
    audioRenderer.flush()
    trace("audio flush")
    sentAudio.removeAll()
    limiter = 1
    nc_seek(d, time, exact ? 1 : 0)
    trace("nc_seek")
    landing = true
    target = time
    start = time
    exactSeek = exact
    gotVideo = false
    videoDone = !hasVideo
    audioDone = !hasAudio
    videoEnd = time
    audioEnd = time
    reportedEnd = false
  }

  private func applyClock(playing: Bool, rate: Float) {
    guard !landing, dec != nil else { return }
    let wanted = playing && !reportedEnd
    if wanted != appliedPlaying || rate != appliedRate {
      synchronizer.rate = wanted ? rate : 0
      appliedPlaying = wanted
      appliedRate = rate
    }
  }

  private func finishLandingIfReady(playing: Bool, rate: Float) {
    let videoReady = !hasVideo || gotVideo || videoDone
    let audioReady = !hasAudio || audioDone || audioEnd >= start + 0.3
    guard videoReady && audioReady else { return }
    trace("landing, audio to \(audioEnd)")
    landing = false
    let wanted = playing
    synchronizer.setRate(wanted ? rate : 0, time: CMTime(seconds: start, preferredTimescale: 90000))
    trace("clock started")
    appliedPlaying = wanted
    appliedRate = rate
    cond.lock()
    if cmd.seek == nil { shownTime = nil }
    cond.unlock()
    let landed = start
    main { self.onSeeked?(landed) }
  }

  private func pushVideo(now: Double) {
    guard let d = dec else { return }
    var f = NCVideoFrame()
    let r = nc_next_video(d, &f)
    if r <= 0 {
      videoDone = true
      return
    }
    guard let pb = f.pixbuf?.takeRetainedValue() else { return }
    if !gotVideo && landing {
      if Self.tracing {
        var i = NCInfo()
        nc_info(d, &i)
        trace("first video frame \(f.pts)\(i.hardware != 0 ? " (VideoToolbox)" : "")")
      }
      gotVideo = true
      start = exactSeek ? max(target, f.pts) : f.pts
      nc_audio_start(d, start)
      audioEnd = start
    } else if f.pts + f.duration < now - 0.1 && !landing {
      videoEnd = f.pts + f.duration
      return  // too late to show
    }
    if (Int(f.sarNum), Int(f.sarDen)) != lastSar {
      lastSar = (Int(f.sarNum), Int(f.sarDen))
      let w = Double(CVPixelBufferGetWidth(pb)) * Double(f.sarNum)
      let h = Double(CVPixelBufferGetHeight(pb)) * Double(max(1, f.sarDen))
      if h > 0 {
        let ratio = w / h
        main {
          if abs(ratio - self.aspect) > 0.001 {
            self.aspect = ratio
            self.onAspect?(ratio)
          }
        }
      }
    }
    if videoFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(videoFormat!, imageBuffer: pb) {
      videoFormat = nil
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &videoFormat)
    }
    guard let format = videoFormat else { return }
    var timing = CMSampleTimingInfo(
      duration: CMTime(seconds: f.duration, preferredTimescale: 90000),
      presentationTimeStamp: CMTime(seconds: f.pts, preferredTimescale: 90000),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil, imageBuffer: pb, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
    if let sample { videoRenderer.enqueue(sample) }
    videoEnd = f.pts + f.duration
  }

  private func pushAudio() {
    guard let d = dec else { return }
    var c = NCAudioChunk()
    let r = nc_next_audio(d, &c)
    if r <= 0 {
      audioDone = true
      return
    }
    let n = Int(c.frames)
    guard n > 0, let src = c.samples else { return }
    let samples = Array(UnsafeBufferPointer(start: src, count: n * 2))
    let rate = Int(c.rate)
    enqueueAudio(samples, pts: c.pts, rate: rate)
    sentAudio.append((c.pts, rate, samples))
    audioEnd = c.pts + Double(n) / Double(rate)
    let now = landing ? start : playheadTime()
    while let first = sentAudio.first, first.pts + Double(first.samples.count / 2) / Double(first.rate) < now - 0.2 {
      sentAudio.removeFirst()
    }
  }

  private func enqueueAudio(_ samples: [Float], pts: Double, rate: Int) {
    let n = samples.count / 2
    if audioFormat == nil || audioFormatRate != rate {
      var asbd = AudioStreamBasicDescription(
        mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
        mReserved: 0)
      var layout = AudioChannelLayout()
      layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
      audioFormat = nil
      CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
      audioFormatRate = rate
    }
    guard let format = audioFormat else { return }
    let bytes = n * 8
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
      allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
      offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
      let block
    else { return }
    var ptr: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &ptr)
    guard let ptr else { return }
    ptr.withMemoryRebound(to: Float.self, capacity: n * 2) { out in
      if gain <= 1.0001 {
        samples.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: n * 2) }
        limiter = 1
      } else {
        boost(samples, into: out, rate: rate)
      }
    }
    var sample: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: n,
      presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: CMTimeScale(rate)),
      packetDescriptions: nil, sampleBufferOut: &sample)
    if let sample { audioRenderer.enqueue(sample) }
  }

  /// Gain with a peak limiter: instant attack, ~150 ms release, ceiling 0.95.
  private func boost(_ samples: [Float], into out: UnsafeMutablePointer<Float>, rate: Int) {
    let g = gain
    let release = 1 - Float(exp(-1.0 / (0.15 * Double(rate))))
    var env = limiter
    for i in stride(from: 0, to: samples.count, by: 2) {
      let l = samples[i] * g, r = samples[i + 1] * g
      let peak = max(abs(l), abs(r))
      if peak * env > 0.95 { env = 0.95 / peak }
      out[i] = l * env
      out[i + 1] = r * env
      env += (1 - env) * release
    }
    limiter = env
  }

  /// Re-sends the audio not yet heard with the new boost, so a volume change
  /// above 100% is heard at once rather than after the buffered second.
  private func changeGain(_ g: Float) {
    gain = g
    trace("gain \(g)")
    guard !landing, hasAudio, !sentAudio.isEmpty else { return }
    let from = playheadTime() + 0.12
    let done = DispatchSemaphore(value: 0)
    var ok = false
    audioRenderer.flush(fromSourceTime: CMTime(seconds: from, preferredTimescale: 90000)) { success in
      ok = success
      done.signal()
    }
    guard done.wait(timeout: .now() + 0.5) == .success, ok else {
      trace("gain: flush refused")
      return
    }
    trace("gain: flushed from \(from), resending")
    limiter = 1
    for chunk in sentAudio {
      let n = chunk.samples.count / 2
      let end = chunk.pts + Double(n) / Double(chunk.rate)
      if end <= from { continue }
      if chunk.pts >= from {
        enqueueAudio(chunk.samples, pts: chunk.pts, rate: chunk.rate)
      } else {
        let skip = min(n, Int(((from - chunk.pts) * Double(chunk.rate)).rounded()))
        if skip < n {
          enqueueAudio(Array(chunk.samples[(skip * 2)...]), pts: chunk.pts + Double(skip) / Double(chunk.rate), rate: chunk.rate)
        }
      }
    }
  }

  private func checkEnd(now: Double) {
    guard !landing, !reportedEnd, videoDone, audioDone else { return }
    let end = max(hasVideo ? videoEnd : 0, hasAudio ? audioEnd : 0)
    guard now >= end - 0.03 else { return }
    reportedEnd = true
    synchronizer.rate = 0
    appliedPlaying = false
    cond.lock()
    cmd.playing = false
    cond.unlock()
    main {
      self.ended = true
      self.isPlaying = false
      self.onEnded?()
    }
  }
}

private func cString<T>(_ tuple: inout T) -> String {
  withUnsafePointer(to: &tuple) {
    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
  }
}

/// Shows a MediaPlayer's picture, letterboxed to its aspect ratio.
class VideoView: NSView {
  let player: MediaPlayer

  init(player: MediaPlayer) {
    self.player = player
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.addSublayer(player.displayLayer)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let b = bounds
    let ratio = player.aspect > 0 ? player.aspect : 16.0 / 9.0
    var w = b.width, h = b.width / ratio
    if h > b.height {
      h = b.height
      w = h * ratio
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    player.displayLayer.frame = CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h).integral
    CATransaction.commit()
  }
}
