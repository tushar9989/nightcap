import Foundation

// Audio fingerprinting and segment matching, used to find intros and end
// credits that repeat across the episodes of a season.
//
// The fingerprint is the Haitsma–Kalker ("Philips") robust hash: the audio is
// cut into overlapping frames, each frame's spectrum is split into 33
// logarithmic bands between 300 Hz and 2 kHz, and each of the 32 bits records
// whether the energy difference between two neighbouring bands grew or shrank
// since the previous frame. The same music played in two episodes gives
// nearly identical 32-bit words, even after different encodes, volume changes
// or small timing offsets. Unrelated audio differs in about half of the bits.
//
// The arithmetic follows the JavaScript engine step for step (same operation
// order, doubles where it used doubles, floats where it used Float32Array), so
// fingerprints it stored on disk stay valid and match bit for bit.

enum FP {
  static let version: UInt32 = 1
  static let sampleRate = 5512
  static let frameSize = 2048  // ~371 ms
  static let hop = 256  // ~46 ms, ~21.5 fingerprints per second
  static let bands = 33
  static let fmin = 300.0
  static let fmax = 2000.0
  static let silenceRms = 0.0015
  static let framesPerSec = Double(sampleRate) / Double(hop)

  static func frameToSec(_ i: Int) -> Double { Double(i * hop + frameSize / 2) / Double(sampleRate) }
  static func secToFrames(_ s: Double) -> Int { Int(jsRound(s * framesPerSec)) }

  private static let bitReverse: [Int] = {
    let n = frameSize
    let levels = Int(log2(Double(n)))
    return (0..<n).map { i in
      var r = 0, x = i
      for _ in 0..<levels {
        r = (r << 1) | (x & 1)
        x >>= 1
      }
      return r
    }
  }()
  // The window and twiddle factors as V8 computed them (see FFTTables.swift).
  private static let cosTable = FFTTables.cos
  private static let sinTable = FFTTables.sin
  static let hann = FFTTables.hann
  static let bandEdges: [Int] = (0...bands).map { k in
    Int(jsRound(((fmin * pow(fmax / fmin, Double(k) / Double(bands))) * Double(frameSize)) / Double(sampleRate)))
  }

  /// In-place radix-2 FFT of length frameSize.
  private static func fft(_ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>) {
    let n = frameSize
    bitReverse.withUnsafeBufferPointer { rev in
      for i in 0..<n {
        let j = rev[i]
        if i < j {
          var t = re[i]; re[i] = re[j]; re[j] = t
          t = im[i]; im[i] = im[j]; im[j] = t
        }
      }
    }
    cosTable.withUnsafeBufferPointer { cosT in
      sinTable.withUnsafeBufferPointer { sinT in
        var size = 2
        while size <= n {
          let half = size >> 1
          let step = n / size
          var start = 0
          while start < n {
            var t = 0
            for k in 0..<half {
              let a = start + k
              let b = a + half
              let xr = re[b] * cosT[t] - im[b] * sinT[t]
              let xi = re[b] * sinT[t] + im[b] * cosT[t]
              re[b] = re[a] - xr
              im[b] = im[a] - xi
              re[a] += xr
              im[a] += xi
              t += step
            }
            start += size
          }
          size <<= 1
        }
      }
    }
  }

  /// pcm: mono samples at sampleRate. One 32-bit word per frame; 0 marks a silent frame.
  static func compute(_ pcm: [Float]) -> [UInt32] {
    let n = frameSize
    let count = pcm.count < n ? 0 : (pcm.count - n) / hop + 1
    var out = [UInt32](repeating: 0, count: count)
    let re = UnsafeMutablePointer<Double>.allocate(capacity: n)
    let im = UnsafeMutablePointer<Double>.allocate(capacity: n)
    var energy = [Double](repeating: 0, count: bands)
    var prev = [Double](repeating: 0, count: bands)
    defer {
      re.deallocate()
      im.deallocate()
    }
    let edges = bandEdges
    pcm.withUnsafeBufferPointer { samples in
      hann.withUnsafeBufferPointer { window in
        for f in 0..<count {
          let off = f * hop
          var sq = 0.0
          for i in 0..<n {
            let s = Double(samples[off + i])
            sq += s * s
            re[i] = s * window[i]
            im[i] = 0
          }
          fft(re, im)
          for m in 0..<bands {
            var e = 0.0
            var b = edges[m]
            while b < edges[m + 1] {
              e += re[b] * re[b] + im[b] * im[b]
              b += 1
            }
            energy[m] = e
          }
          if (sq / Double(n)).squareRoot() < silenceRms {
            out[f] = 0
          } else {
            var v: UInt32 = 0
            for m in 0..<32 where energy[m] - energy[m + 1] - (prev[m] - prev[m + 1]) > 0 {
              v |= 1 << UInt32(m)
            }
            out[f] = v == 0 ? 1 : v
          }
          swap(&prev, &energy)
        }
      }
    }
    return out
  }

  // ---- Matching ---------------------------------------------------------------------------

  struct MatchOptions {
    var smoothFrames = 21
    var maxBits = 10.0
    var edgeBits = 11.0
    var gapFrames = Int(jsRound(FP.framesPerSec * 2.5))
    var minFrames = FP.secToFrames(15)
    var maxFrames = FP.secToFrames(150)
  }

  struct Segment: Equatable {
    var a0, a1, b0, b1: Int
    var len: Int
    var mean: Double
    var offset: Int
  }

  /// Candidate alignments between A and B. Every frame of A looks up the frames
  /// of B that share its low or high 16 bits, and votes for the offset (j - i)
  /// that would line them up. Repeated audio piles its votes onto one offset.
  static func candidateOffsets(_ A: [UInt32], _ B: [UInt32], maxCandidates: Int = 6) -> [Int] {
    let bucketLimit: UInt16 = 40
    var heads = [[Int32]](repeating: [Int32](repeating: -1, count: 65536), count: 2)
    var sizes = [[UInt16]](repeating: [UInt16](repeating: 0, count: 65536), count: 2)
    var next = [[Int32]](repeating: [Int32](repeating: 0, count: B.count), count: 2)
    func key(_ v: UInt32, _ h: Int) -> Int { Int(h == 1 ? v >> 16 : v & 0xffff) }
    for j in 0..<B.count where B[j] != 0 {
      for h in 0..<2 {
        let k = key(B[j], h)
        next[h][j] = heads[h][k]
        heads[h][k] = Int32(j)
        if sizes[h][k] < 65535 { sizes[h][k] += 1 }
      }
    }
    let base = A.count
    var votes = [Float](repeating: 0, count: A.count + B.count + 1)
    for i in 0..<A.count where A[i] != 0 {
      for h in 0..<2 {
        let k = key(A[i], h)
        if sizes[h][k] > bucketLimit { continue }
        var j = Int(heads[h][k])
        while j != -1 {
          votes[j - i + base] += 1
          j = Int(next[h][j])
        }
      }
    }
    // Timing jitter spreads a match over neighbouring offsets; sum a small window.
    var smooth = [Float](repeating: 0, count: votes.count)
    for d in 0..<votes.count {
      let before = d > 0 ? Double(votes[d - 1]) : 0
      let after = d + 1 < votes.count ? Double(votes[d + 1]) : 0
      smooth[d] = Float(Double(votes[d]) + 0.5 * (before + after))
    }
    var picks: [Int] = []
    let suppress = Int(jsRound(framesPerSec * 2))
    var taken = [Bool](repeating: false, count: votes.count)
    for _ in 0..<maxCandidates {
      var best = -1
      var bestV = 6.0  // ignore offsets with almost no evidence
      for d in 0..<smooth.count where !taken[d] && Double(smooth[d]) > bestV {
        bestV = Double(smooth[d])
        best = d
      }
      if best < 0 { break }
      picks.append(best - base)
      for d in max(0, best - suppress)...min(smooth.count - 1, best + suppress) { taken[d] = true }
    }
    return picks
  }

  static func popcount(_ x: UInt32) -> Int { x.nonzeroBitCount }

  /// Longest stretch where A[i] and B[i + d] stay similar, judged on a ~1 s
  /// moving average of the bit distance. Short dips (up to `gapFrames`) are
  /// bridged so a line of dialogue over the theme song does not split it.
  static func bestRunAtOffset(_ A: [UInt32], _ B: [UInt32], _ d: Int, _ opts: MatchOptions) -> Segment? {
    let i0 = max(0, -d)
    let i1 = min(A.count, B.count - d)
    let n = i1 - i0
    if n <= 0 { return nil }
    var dist = [Float](repeating: 0, count: n)
    var voiced = [UInt8](repeating: 0, count: n)
    for k in 0..<n {
      let a = A[i0 + k]
      let b = B[i0 + k + d]
      if a == 0 && b == 0 {
        dist[k] = 0
      } else if a == 0 || b == 0 {
        dist[k] = 16
      } else {
        dist[k] = Float(popcount(a ^ b))
        voiced[k] = 1
      }
    }
    let half = opts.smoothFrames >> 1
    var prefix = [Double](repeating: 0, count: n + 1)
    for k in 0..<n { prefix[k + 1] = prefix[k] + Double(dist[k]) }
    var runs: [(Int, Int)] = []
    var start = -1
    var lastGood = -1
    for k in 0..<n {
      let lo = max(0, k - half)
      let hi = min(n, k + half + 1)
      let good = (prefix[hi] - prefix[lo]) / Double(hi - lo) <= opts.maxBits
      if good {
        if start < 0 {
          start = k
        } else if k - lastGood > opts.gapFrames {
          runs.append((start, lastGood))
          start = k
        }
        lastGood = k
      }
    }
    if start >= 0 { runs.append((start, lastGood)) }

    var best: Segment?
    for (s0, e0) in runs {
      var s = s0, e = e0
      // Trim the blur the moving average adds at both ends.
      while s < e && Double(dist[s]) > opts.edgeBits { s += 1 }
      while e > s && Double(dist[e]) > opts.edgeBits { e -= 1 }
      let len = e - s + 1
      if len < opts.minFrames || len > opts.maxFrames { continue }
      var sum = 0.0
      var v = 0
      for k in s...e {
        sum += Double(dist[k])
        v += Int(voiced[k])
      }
      if Double(v) < Double(len) * 0.5 { continue }  // mostly shared silence, not shared audio
      let mean = sum / Double(len)
      if mean > opts.maxBits { continue }  // scattered near-misses chained together
      if best == nil || len > best!.len {
        best = Segment(a0: i0 + s, a1: i0 + e, b0: 0, b1: 0, len: len, mean: mean, offset: d)
      }
    }
    if var b = best {
      b.b0 = b.a0 + d
      b.b1 = b.a1 + d
      best = b
    }
    return best
  }

  /// Finds the longest shared audio segment between two fingerprints: frame
  /// ranges in both, or nil.
  static func findSharedSegment(_ A: [UInt32], _ B: [UInt32], _ opts: MatchOptions = MatchOptions()) -> Segment? {
    if A.count < opts.minFrames || B.count < opts.minFrames { return nil }
    var best: Segment?
    for d in candidateOffsets(A, B) {
      if let run = bestRunAtOffset(A, B, d, opts), best == nil || run.len > best!.len { best = run }
    }
    return best
  }

  struct Member {
    var id: String
    var fp: [UInt32]
    /// Seconds into the file where fp starts.
    var offset: Double
  }

  struct Repeated: Equatable {
    var start: Double
    var end: Double
    var support: Int
    var compared: Int
    /// Shared with one other episode only (see PairRule).
    var pair = false
  }

  /// An intro version used by just two episodes (a two-part premiere with
  /// titles of its own) never gets the two agreeing siblings the season rule
  /// asks for. Such a pair still counts when the two match each other and no
  /// other episode, closely and for long enough to be titles rather than a
  /// reused jingle or a scene a recap plays again.
  struct PairRule {
    var minFrames = FP.secToFrames(45)
    var maxBits = 6.0
    /// How far apart, in seconds, the segment may start in the two episodes
    /// (nil: anywhere). A recap replays part one somewhere else than it first played.
    var maxShift: Double? = 10
  }

  /// One comparison, seen from the episode being analysed: where it has the
  /// shared segment, and which episode (index in the list compared with) shares it where.
  private struct Found {
    var start: Double
    var end: Double
    var other: Int
    var otherStart: Double
    var otherEnd: Double
    var seg: Segment
  }

  private static func overlaps(_ x: Found, _ y: Found) -> Bool {
    min(x.end, y.end) - max(x.start, y.start) >= 0.5 * min(x.end - x.start, y.end - y.start)
  }

  private static func span(_ arr: [Found]) -> Double { arr.reduce(0.0) { $0 + $1.end - $1.start } }

  /// The most results that agree on where the segment is.
  private static func bestCluster(_ found: [Found]) -> [Found] {
    var best: [Found] = []
    for c in found {
      let cluster = found.filter { overlaps(c, $0) }
      if cluster.count > best.count || (cluster.count == best.count && span(cluster) > span(best)) { best = cluster }
    }
    return best
  }

  private static func median(_ xs: [Double]) -> Double {
    let s = xs.stableSorted(by: numCompare)
    let m = s.count >> 1
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
  }

  /// Given fingerprints for every episode of a group (usually one season),
  /// finds each episode's segment by comparing it with its nearest siblings and
  /// keeping the answer at least two of them agree on. Seasons can alternate
  /// between intro versions, so when the nearest siblings disagree the search
  /// widens to more episodes (comparisons are cheap once fingerprints exist).
  ///   targets: ids to produce results for (others only serve as references)
  ///   pairs: also accept two episodes that share a segment with nobody else
  static func detectRepeatedSegments(
    _ members: [Member], _ targets: [String], _ opts: MatchOptions = MatchOptions(),
    minSiblings: Int = 4, maxSiblings: Int = 10, pairs: PairRule? = nil
  ) -> [(id: String, result: Repeated)] {
    var byId: [String: Int] = [:]
    for (i, m) in members.enumerated() { byId[m.id] = i }
    var cache: [String: Segment?] = [:]
    func pair(_ i: Int, _ j: Int) -> Found? {
      let a = members[i], b = members[j]
      let key = a.id < b.id ? "\(a.id)|\(b.id)" : "\(b.id)|\(a.id)"
      if cache[key] == nil {
        let (x, y) = a.id < b.id ? (a, b) : (b, a)
        cache[key] = .some(findSharedSegment(x.fp, y.fp, opts))
      }
      guard let r = cache[key]! else { return nil }
      let mine = a.id < b.id ? (r.a0, r.a1) : (r.b0, r.b1)
      let theirs = a.id < b.id ? (r.b0, r.b1) : (r.a0, r.a1)
      return Found(
        start: a.offset + frameToSec(mine.0), end: a.offset + frameToSec(mine.1), other: j,
        otherStart: b.offset + frameToSec(theirs.0), otherEnd: b.offset + frameToSec(theirs.1), seg: r)
    }
    var surveys: [Int: (found: [Found], compared: Int)] = [:]
    func survey(_ index: Int) -> (found: [Found], compared: Int) {
      if let s = surveys[index] { return s }
      var siblings: [Int] = []
      if members.count > 1 {
        for step in 1..<members.count {
          for idx in [index + step, index - step] where idx >= 0 && idx < members.count && !members[idx].fp.isEmpty {
            siblings.append(idx)
          }
        }
      }
      var found: [Found] = []
      var compared = 0
      for s in siblings.prefix(maxSiblings) {
        let r = pair(index, s)
        compared += 1
        if let r { found.append(r) }
        if compared >= minSiblings && bestCluster(found).count >= 2 { break }
      }
      surveys[index] = (found, compared)
      return (found, compared)
    }
    // With several references, ask for at least two to agree.
    func agreed(_ s: (found: [Found], compared: Int)) -> [Found]? {
      let cluster = bestCluster(s.found)
      return cluster.isEmpty || cluster.count < (s.compared >= 3 ? 2 : 1) ? nil : cluster
    }

    var results: [(String, Repeated)] = []
    var unmatched: [(id: String, index: Int)] = []
    var done = Set<String>()
    for id in targets {
      guard let index = byId[id], !done.contains(id) else { continue }
      if members[index].fp.isEmpty { continue }
      done.insert(id)
      let s = survey(index)
      guard let cluster = agreed(s) else {
        unmatched.append((id, index))
        continue
      }
      results.append((id, Repeated(
        start: median(cluster.map(\.start)), end: median(cluster.map(\.end)),
        support: cluster.count, compared: s.compared)))
    }
    guard let rule = pairs else { return results }
    // The only match of an episode that found no agreement, if it has exactly one.
    func lone(_ index: Int) -> Found? {
      let s = survey(index)
      return agreed(s) == nil && s.found.count == 1 ? s.found[0] : nil
    }
    for (id, index) in unmatched {
      guard let f = lone(index), lone(f.other)?.other == index else { continue }
      if f.seg.len < rule.minFrames || f.seg.mean > rule.maxBits { continue }
      if let shift = rule.maxShift, abs(f.start - f.otherStart) > shift { continue }
      results.append((id, Repeated(start: f.start, end: f.end, support: 1, compared: survey(index).compared, pair: true)))
    }
    return results
  }

  /// An episode that shares nothing with its own season can share its intro (or
  /// credits) with another season's: a premiere re-edited with a later
  /// season's titles, say. `others` are those episodes, nearest first, and as
  /// in a season two of them must agree. With `whole`, the part this episode
  /// shares with them must also be (nearly) all of what those two share with
  /// each other, so a pilot whose own opening song quotes the theme does not
  /// pass the quote off as its intro.
  static func detectFromOthers(
    _ me: Member, _ others: [Member], _ opts: MatchOptions, whole: Double? = nil, minCompared: Int = 4
  ) -> Repeated? {
    if me.fp.isEmpty { return nil }
    var found: [Found] = []
    var compared = 0
    for (k, o) in others.enumerated() where !o.fp.isEmpty {
      compared += 1
      if let seg = findSharedSegment(me.fp, o.fp, opts) {
        found.append(Found(
          start: me.offset + frameToSec(seg.a0), end: me.offset + frameToSec(seg.a1), other: k,
          otherStart: o.offset + frameToSec(seg.b0), otherEnd: o.offset + frameToSec(seg.b1), seg: seg))
      }
      if compared >= minCompared && bestCluster(found).count >= 2 { break }
    }
    let cluster = bestCluster(found)
    if cluster.count < 2 { return nil }
    if let whole {
      let a = cluster[0], b = cluster[1]
      guard let shared = findSharedSegment(others[a.other].fp, others[b.other].fp, opts) else { return nil }
      let s0 = others[a.other].offset + frameToSec(shared.a0)
      let s1 = others[a.other].offset + frameToSec(shared.a1)
      if min(s1, a.otherEnd) - max(s0, a.otherStart) < whole * (s1 - s0) { return nil }
    }
    return Repeated(
      start: median(cluster.map(\.start)), end: median(cluster.map(\.end)), support: cluster.count, compared: compared)
  }

  // ---- The on-disk index -------------------------------------------------------------------

  private static let magic: UInt32 = 0x4c4e_4650  // "LNFP"

  static func encode(_ fp: [UInt32], offset: Double, length: Double) -> Data {
    var d = Data(capacity: 32 + fp.count * 4)
    func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
    put(magic.littleEndian)
    put(version.littleEndian)
    put(UInt32(sampleRate).littleEndian)
    put(UInt32(hop).littleEndian)
    put(offset.bitPattern.littleEndian)
    put(Float(length).bitPattern.littleEndian)
    put(UInt32(fp.count).littleEndian)
    fp.withUnsafeBytes { d.append(contentsOf: $0) }
    return d
  }

  static func decode(_ d: Data) -> (fp: [UInt32], offset: Double, length: Double)? {
    guard d.count >= 32 else { return nil }
    return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (fp: [UInt32], offset: Double, length: Double)? in
      func u32(_ at: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
      guard u32(0) == magic, u32(4) == version, u32(8) == UInt32(sampleRate), u32(12) == UInt32(hop) else { return nil }
      let count = Int(u32(28))
      guard d.count == 32 + count * 4 else { return nil }
      let offset = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
      let length = Double(Float(bitPattern: u32(24)))
      var fp = [UInt32](repeating: 0, count: count)
      fp.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[32...])) }
      return (fp, offset, length)
    }
  }
}
