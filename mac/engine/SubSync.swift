import Foundation

// Lines subtitles up with the dialogue, on this machine, two ways.
//
// By the words (English subtitles and dialogue; see wordsFit): the subtitles'
// words are matched to those Apple's speech recogniser hears, so each part of
// the subtitles finds its place, also when they were timed for another cut of
// the video (a scene longer, a longer pause at an ad break). About 35 s for an
// episode, or nothing when its dialogue was heard already.
//
// By the loudness of speech (any language, about 3 s): the audio becomes a
// speech-activity curve, 50 values per second: energy in the voice band
// (300-3400 Hz) relative to the local noise floor. The cues become on/off
// intervals. Correlating the two over offsets of up to three minutes, and over
// the usual frame-rate mix-ups (subtitles timed for 25 fps on a 23.976 fps
// video drift by a minute per 25 minutes), finds where the subtitles fit, as
// one offset. The fit is only used when it clearly beats every other offset;
// subtitles for another episode never do. Subtitles of another cut can (half
// of Baywatch's Heat Wave fitted, the rest 36-48 s off), so the words come after.

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

  // ---- Fitting to the words heard -------------------------------------------------------

  /// Subtitles fitted to the words heard: from subtitle time `parts[i].from` on, cues
  /// belong at t * scale + parts[i].offset (one part unless they are of another cut).
  struct WordsFit: Equatable {
    var scale: Double
    var parts: [SyncPart]
    /// Words matched on both sides, and the cues they are in.
    var anchors: Int
    var cues: Int
  }

  /// A split into parts costs as much as `splitCost` words heard a second off; a word
  /// further off than `farOff` counts as that far (a wrong match).
  static let splitCost = 40.0
  static let farOff = 2.0

  /// Words as compared: lower case letters and digits, with apostrophes inside a word.
  static func comparable(_ text: String) -> [String] {
    var out: [String] = []
    var word = ""
    func end() {
      while word.hasSuffix("'") { word.removeLast() }
      if !word.isEmpty { out.append(word) }
      word = ""
    }
    for c in text.lowercased() {
      if c.isLetter || c.isNumber {
        word.append(c)
      } else if c == "'" || c == "\u{2019}" || c == "\u{2018}" {
        if !word.isEmpty { word.append("'") }
      } else {
        end()
      }
    }
    end()
    return out
  }

  private static let notSaidRe = Re(#"<[^>]*>|\{[^}]*\}|\[[^\]]*\]|\([^)]*\)|^[A-Z][A-Z .'-]*:"#, "m")

  /// The words said in a cue: tags, sounds ([door closes], (laughs)) and speakers (MAN:) left out.
  static func said(_ text: String) -> [String] { comparable(notSaidRe.replace(text, " ")) }

  private static func median(_ xs: [Double]) -> Double {
    let s = xs.stableSorted(by: numCompare)
    let m = s.count >> 1
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
  }

  /// Fits subtitles (cues in time order) to the words the speech recogniser heard, both
  /// English. Anchors are word triples found once on each side, kept where both run in
  /// the same order (as a patience diff keeps lines); each says how far its subtitle word
  /// is from when it was heard. Where those offsets jump and stay jumped, the subtitles
  /// are of another cut (a scene longer, a pause at an ad break), and they fall into parts
  /// by dynamic programming: each anchor costs its distance from its part's offset, each
  /// split `splitCost`. nil when too little was heard (subtitles of another episode).
  ///
  /// Measured on the Baywatch pilot and three X-Files episodes against their published
  /// subtitles, cut and slowed by known amounts (16 cases): cues within 0.35 s of their
  /// published timing, but for 7 of 10,800 (sounds, no words to match; lines at a cut).
  static func wordsFit(_ cues: [(start: Double, end: Double, text: String)], _ heard: [[MadeSubs.Word]]) -> WordsFit? {
    // The subtitles' words, each at its share of its cue by letters (the last tenth of a
    // cue is a pause), and whether it starts its cue.
    var sw: [String] = [], st: [Double] = [], starts: [Bool] = [], cueOf: [Int] = []
    var spoken = 0
    for (ci, c) in cues.enumerated() {
      let ws = said(c.text)
      if ws.isEmpty { continue }
      spoken += 1
      let letters = Double(max(1, ws.reduce(0) { $0 + $1.count }))
      var before = 0
      for (i, w) in ws.enumerated() {
        sw.append(w)
        st.append(c.start + (c.end - c.start) * 0.9 * Double(before) / letters)
        starts.append(i == 0)
        cueOf.append(ci)
        before += w.count
      }
    }
    // The words heard, each when it was said.
    var hw: [String] = [], ht: [Double] = []
    for w in heard.joined() {
      let t = MadeSubs.onset(w)
      for x in comparable(w.t) {
        hw.append(x)
        ht.append(t)
      }
    }

    // Anchors: triples found once on each side, in the longest run in order on both.
    func once(_ ws: [String]) -> [String: Int] {
      var seen: [String: Int] = [:]
      if ws.count >= 3 {
        for i in 0...(ws.count - 3) {
          let k = "\(ws[i]) \(ws[i + 1]) \(ws[i + 2])"
          seen[k] = seen[k] == nil ? i : -1
        }
      }
      return seen
    }
    let heardOnce = once(hw)
    var pairs: [(i: Int, j: Int)] = []
    for (k, i) in once(sw) where i >= 0 {
      if let j = heardOnce[k], j >= 0 { pairs.append((i, j)) }
    }
    pairs.sort { $0.i < $1.i }
    var tails: [Int] = [], tailAt: [Int] = [], prev = [Int](repeating: -1, count: pairs.count)
    for (k, p) in pairs.enumerated() {
      var lo = 0, hi = tails.count
      while lo < hi {
        let m = (lo + hi) / 2
        if tails[m] < p.j { lo = m + 1 } else { hi = m }
      }
      if lo == tails.count {
        tails.append(p.j)
        tailAt.append(k)
      } else {
        tails[lo] = p.j
        tailAt[lo] = k
      }
      prev[k] = lo > 0 ? tailAt[lo - 1] : -1
    }
    var chain: [Int] = []
    var k = tailAt.last ?? -1
    while k >= 0 {
      chain.append(k)
      k = prev[k]
    }
    let anchors = chain.reversed().map { pairs[$0] }
    let anchoredCues = Set(anchors.map { cueOf[$0.i] }).count
    guard anchoredCues >= 20, Double(anchoredCues) >= 0.25 * Double(spoken) else { return nil }
    let s = anchors.map { st[$0.i] }, h = anchors.map { ht[$0.j] }, first = anchors.map { starts[$0.i] }

    // The speed: the median slope between anchors 1 to 3 minutes apart (few lie across a
    // cut); the frame-rate changes near it are tried.
    var slopes: [Double] = []
    for x in 0..<s.count {
      var y = x + 1
      while y < s.count && s[y] - s[x] <= 180 {
        if s[y] - s[x] >= 60 { slopes.append((h[y] - h[x]) / (s[y] - s[x])) }
        y += 5
      }
    }
    let measured = slopes.isEmpty ? 1 : median(slopes)
    var tried = scales.filter { abs($0 - measured) < 0.002 }
    if tried.isEmpty { tried = [1] }

    // Each scale: the anchors' offsets split into parts (offsets on a grid), the cheapest kept.
    var chosen: (cost: Double, scale: Double, offs: [Double], at: [Int]) = (.infinity, 1, [], [])
    for scale in tried {
      let offs = (0..<s.count).map { h[$0] - scale * s[$0] }
      let sorted = offs.stableSorted(by: numCompare)
      let lo = sorted[sorted.count / 100] - 1, hi = sorted[sorted.count - 1 - sorted.count / 100] + 1
      let step = max(0.05, (hi - lo) / 20000)
      let G = Int((hi - lo) / step) + 1
      let words = (G + 63) / 64
      var best = (0..<G).map { min(abs(offs[0] - (lo + Double($0) * step)), farOff) }
      var jumped = [UInt64](repeating: 0, count: offs.count * words)
      var from = [Int](repeating: 0, count: offs.count)
      for i in 1..<offs.count {
        var top = 0
        for g in 1..<G where best[g] < best[top] { top = g }
        let split = best[top] + splitCost
        from[i] = top
        let o = offs[i]
        for g in 0..<G {
          var c = best[g]
          if split < c {
            c = split
            jumped[i * words + g / 64] |= 1 << UInt64(g % 64)
          }
          best[g] = c + min(abs(o - (lo + Double(g) * step)), farOff)
        }
      }
      var g = 0
      for x in 1..<G where best[x] < best[g] { g = x }
      guard best[g] < chosen.cost else { continue }
      let cost = best[g]
      var at = [Int](repeating: 0, count: offs.count)
      for i in stride(from: offs.count - 1, through: 0, by: -1) {
        at[i] = g
        if i > 0 && jumped[i * words + g / 64] & (1 << UInt64(g % 64)) != 0 { g = from[i] }
      }
      chosen = (cost, scale, offs, at)
    }

    // The parts: each one's offset is the median of its anchors that start a cue (no share
    // of a cue to guess) when it has ten, else of all; cues between two parts' anchors go
    // with the nearer.
    var parts: [SyncPart] = []
    var lastAnchor = 0.0
    var i = 0
    while i < chosen.at.count {
      var j = i
      while j + 1 < chosen.at.count && chosen.at[j + 1] == chosen.at[i] { j += 1 }
      let firsts = (i...j).filter { first[$0] }.map { chosen.offs[$0] }
      let offset = jsRound((firsts.count >= 10 ? median(firsts) : median(Array(chosen.offs[i...j]))) * 100) / 100
      if parts.isEmpty {
        parts.append(SyncPart(from: 0, offset: offset))
      } else if abs(offset - parts[parts.count - 1].offset) >= 0.1 {
        parts.append(SyncPart(from: jsRound((lastAnchor + s[i]) / 2 * 1000) / 1000, offset: offset))
      }
      lastAnchor = s[j]
      i = j + 1
    }
    guard parts.allSatisfy({ abs($0.offset) <= 600 }) else { return nil }
    return WordsFit(scale: chosen.scale, parts: parts, anchors: anchors.count, cues: anchoredCues)
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
  /// Fitted to the words heard: in how many parts, with how many words matched.
  var parts: [SyncPart]? = nil
  var anchors: Int? = nil
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
    return SubTiming(offset: s.offset, scale: s.scale, parts: s.parts ?? [], byWords: s.by == "words")
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

  /// Fits `vtt` (the track as served before any correction) to the words heard in the
  /// audio (Sync.wordsFit) and keeps the correction.
  func alignToWords(_ f: LibraryFile, _ subId: String, _ vtt: String, heard: [[MadeSubs.Word]]) -> SyncResult {
    let cues = Subtext.blocks(vtt).compactMap { b -> (start: Double, end: Double, text: String)? in
      guard let text = b.text, b.end > b.start else { return nil }
      return (b.start, b.end, text)
    }.stableSorted { numCompare($0.start, $1.start) }
    guard let fit = Sync.wordsFit(cues, heard) else {
      return SyncResult(confident: false, applied: false, reason: "No clear match with the dialogue")
    }
    var result = SyncResult(
      offset: fit.parts[0].offset, scale: fit.scale, confident: true, applied: false, parts: fit.parts, anchors: fit.anchors)
    // Already in sync: keep the file as it is.
    if fit.parts.count == 1 && abs(fit.parts[0].offset) < 0.15 && fit.scale == 1 {
      clear(f, subId)
      result.inSync = true
      return result
    }
    store.data.tracks["\(f.id):\(subId)"] = SyncEntry(
      offset: fit.parts[0].offset, scale: fit.scale, parts: fit.parts.count > 1 ? fit.parts : nil, by: "words", z: nil,
      ratio: nil, sig: sigHash(f), at: nowMs())
    store.save()
    result.applied = true
    return result
  }
}
