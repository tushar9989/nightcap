import Foundation

// Lines subtitles up with the dialogue, on this machine.
//
// The audio becomes a speech-activity curve, 50 values per second: energy in
// the voice band (300-3400 Hz) relative to the local noise floor. The cues
// become on/off intervals. Correlating the two over offsets of up to three
// minutes, and over the usual frame-rate mix-ups (subtitles timed for 25 fps
// on a 23.976 fps video drift by a minute per 25 minutes), finds where the
// subtitles fit. The fit is only used when it clearly beats every other
// offset; subtitles for another episode, or with a different cut, never do.

enum Sync {
  static let rate = 50  // activity values per second
  static let sampleRate = 8000
  static let hop = sampleRate / rate
  static let scales: [Double] = [1, 25 / 23.976, 23.976 / 25, 24 / 23.976, 23.976 / 24, 25 / 24, 24 / 25]
  static let minZ = 4.0  // peak height in standard deviations of all offsets
  static let minRatio = 1.3  // peak versus the best offset more than 2 s away

  /// Energy per frame (dB) -> speech activity 0...1: how far each frame rises
  /// above the quietest frames around it (20th percentile of 1 s minima, ±5 s).
  static func activityFromEnergy(_ db: [Float]) -> [Float] {
    var blocks: [Double] = []
    var i = 0
    while i < db.count {
      var m = Double.infinity
      for j in i..<min(db.count, i + rate) { m = min(m, Double(db[j])) }
      blocks.append(m)
      i += rate
    }
    var out = [Float](repeating: 0, count: db.count)
    for b in 0..<blocks.count {
      let win = blocks[max(0, b - 5)..<min(blocks.count, b + 6)].sorted()
      let floor = win[Int((Double(win.count) * 0.2).rounded(.down))]
      for i in (b * rate)..<min(db.count, (b + 1) * rate) {
        out[i] = Float(max(0, min(1, (Double(db[i]) - floor - 6) / 12)))
      }
    }
    return out
  }

  struct Failure: Error { let message: String }

  /// Speech activity of one audio track of a video (about 3 s per 45 min).
  static func speechActivity(_ path: String, audio: Int = 0) async throws -> [Float] {
    guard let ffmpeg = Tools.ffmpeg else { throw Failure(message: "ffmpeg is needed to sync subtitles") }
    final class Energy: @unchecked Sendable {
      var db: [Double] = []
      var acc = 0.0
      var n = 0
      var carry: UInt8?
    }
    let e = Energy()
    @Sendable func addSample(_ e: Energy, _ s: Int16) {
      let v = Double(s)
      e.acc += v * v
      e.n += 1
      if e.n == hop {
        // fdlibm's log10, as JavaScript's Math.log10 (the result is rounded to float32 after).
        e.db.append(10 * nc_fdlibm_log10(e.acc / Double(hop) + 1))
        e.acc = 0
        e.n = 0
      }
    }
    let r = try await runTool(ffmpeg, [
      "-nostdin", "-loglevel", "error", "-i", path, "-map", "0:a:\(audio)", "-vn", "-sn", "-dn", "-ac", "1",
      "-af", "aresample=\(sampleRate),highpass=f=300,lowpass=f=3400", "-f", "s16le", "pipe:1",
    ]) { chunk in
      // Little-endian 16-bit samples; a chunk can end halfway through one.
      chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var k = 0
        if let lo = e.carry, raw.count > 0 {
          addSample(e, Int16(bitPattern: UInt16(lo) | UInt16(raw[0]) << 8))
          e.carry = nil
          k = 1
        }
        while k + 1 < raw.count {
          addSample(e, Int16(bitPattern: UInt16(raw[k]) | UInt16(raw[k + 1]) << 8))
          k += 2
        }
        if k < raw.count { e.carry = raw[k] }
      }
    }
    if r.code != 0 && e.db.isEmpty {
      let last = r.lastErrorLine
      throw Failure(message: last.isEmpty ? "could not read the audio" : last)
    }
    return activityFromEnergy(e.db.map { Float($0) })
  }

  struct Alignment {
    var scale: Double
    var offset: Double
    var z: Double
    var ratio: Double
    var confident = false
  }

  /// Best {offset, scale} so that cue time t belongs at t * scale + offset.
  static func bestAlignment(_ activity: [Float], _ cues: [(Double, Double)], maxOffset: Double = 180, scales: [Double] = Sync.scales) -> Alignment {
    let len = activity.count
    var mean = 0.0
    for a in activity { mean += Double(a) }
    mean /= len == 0 ? 1 : Double(len)
    // Prefix sums make each cue's overlap with the curve two lookups.
    var P = [Double](repeating: 0, count: len + 1)
    for i in 0..<len { P[i + 1] = P[i] + Double(activity[i]) - mean }
    let lenD = Double(len)
    let MAX = Int(jsRound(maxOffset * Double(rate)))
    var results: [Alignment] = []
    P.withUnsafeBufferPointer { P in
      // P[i] with i clamped; cue positions are whole numbers or ±infinity.
      func at(_ i: Double) -> Double { i < 0 ? P[0] : i > lenD ? P[len] : P[Int(i)] }
      for scale in scales {
        let cs = cues.map { (jsRound($0.0 * scale * Double(rate)), jsRound($0.1 * scale * Double(rate))) }
        var c = [Double](repeating: 0, count: 2 * MAX + 1)
        for k in -MAX...MAX {
          let kd = Double(k)
          var sum = 0.0
          for (a, b) in cs { sum += at(b + kd) - at(a + kd) }
          c[k + MAX] = sum
        }
        var best = 0
        var m = 0.0
        for i in 0..<c.count {
          m += c[i]
          if c[i] > c[best] { best = i }
        }
        m /= Double(c.count)
        var v = 0.0
        var second = -Double.infinity
        for i in 0..<c.count {
          v += (c[i] - m) * (c[i] - m)
          if abs(i - best) > 2 * rate && c[i] > second { second = c[i] }
        }
        var sd = (v / Double(c.count)).squareRoot()
        if sd == 0 || sd.isNaN { sd = 1 }
        results.append(Alignment(
          scale: scale, offset: Double(best - MAX) / Double(rate), z: (c[best] - m) / sd,
          ratio: second > m ? (c[best] - m) / (second - m) : .infinity))
      }
    }
    results.stableSort { a, b in numCompare(b.z, a.z) }
    var top = results[0]
    top.confident = top.z >= minZ && top.ratio >= minRatio
    return top
  }
}

/// What a sync attempt found, and whether the correction is now in use.
struct SyncResult: Equatable {
  var offset: Double?
  var scale: Double?
  var confident: Bool
  var z: Double?
  var ratio: Double?
  var applied: Bool
  var inSync = false
  var reason: String?
}

/// Remembers each track's correction; subtitles are served with it applied.
@MainActor
final class SubSync {
  let store = JsonStore(Paths.data("subsync.json"), defaults: SyncData())
  private var cache: [(key: String, activity: [Float])] = []  // the last few videos
  private var inflight: [String: Task<SyncResult, Error>] = [:]

  func flush() { store.flush() }

  func get(_ f: LibraryFile, _ subId: String) -> SubTiming? {
    guard let s = store.data.tracks["\(f.id):\(subId)"], s.sig == sigHash(f) else { return nil }
    return SubTiming(offset: s.offset, scale: s.scale)
  }

  func clear(_ f: LibraryFile, _ subId: String) {
    store.data.tracks["\(f.id):\(subId)"] = nil
    store.save()
  }

  private func activity(_ f: LibraryFile, _ audio: Int) async throws -> [Float] {
    let key = "\(sigHash(f)):\(audio)"
    if let hit = cache.first(where: { $0.key == key }) { return hit.activity }
    let path = f.path
    let act = try await Task.detached(priority: .userInitiated) { try await Sync.speechActivity(path, audio: audio) }.value
    if !cache.contains(where: { $0.key == key }) { cache.append((key, act)) }
    while cache.count > 3 { cache.removeFirst() }
    return act
  }

  /// `vtt`: the track as served before any correction.
  func align(_ f: LibraryFile, _ subId: String, _ vtt: String, audio: Int = 0) async throws -> SyncResult {
    let key = "\(f.id):\(subId)"
    if let running = inflight[key] { return try await running.value }
    let task = Task { () throws -> SyncResult in
      defer { inflight[key] = nil }
      let cues = Subtext.cueTimes(vtt)
      if cues.count < 20 { return SyncResult(confident: false, applied: false, reason: "Too few subtitles to sync") }
      let act = try await activity(f, audio)
      let r = await Task.detached(priority: .userInitiated) { Sync.bestAlignment(act, cues) }.value
      let offset = jsRound(r.offset * 100) / 100
      var result = SyncResult(
        offset: offset, scale: r.scale, confident: r.confident, z: jsRound(r.z * 10) / 10, ratio: jsRound(r.ratio * 100) / 100,
        applied: false)
      if !r.confident {
        result.reason = "No clear match with the dialogue"
        return result
      }
      // Already in sync: keep the file as it is.
      if abs(offset) < 0.15 && r.scale == 1 {
        clear(f, subId)
        result.inSync = true
        return result
      }
      store.data.tracks[key] = SyncEntry(
        offset: offset, scale: r.scale, z: result.z, ratio: result.ratio!.isFinite ? result.ratio : nil, sig: sigHash(f), at: nowMs())
      store.save()
      result.applied = true
      return result
    }
    inflight[key] = task
    return try await task.value
  }
}
