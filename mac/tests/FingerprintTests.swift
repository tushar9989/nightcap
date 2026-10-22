import Foundation

private let SR = FP.sampleRate

// Music-like audio: random notes with harmonics plus noise hits.
private func music(_ seconds: Double, _ seed: UInt32) -> [Float] {
  let r = lcg(seed)
  var out = [Float](repeating: 0, count: Int(jsRound(seconds * Double(SR))))
  var i = 0
  while i < out.count {
    let len = Int(jsRound((0.15 + r() * 0.4) * Double(SR)))
    let f = 110 * pow(2, (r() * 36).rounded(.down) / 12)
    let g = 0.15 + r() * 0.2
    let hit = r() < 0.3
    var k = 0
    while k < len && i + k < out.count {
      let t = Double(k) / Double(SR)
      let env = min(1, Double(k) / 200) * exp(-t * 3)
      var v = 0.0
      for h in 1...4 { v += sin(2 * Double.pi * f * Double(h) * t) / Double(h) }
      if hit && k < 800 { v += (r() * 2 - 1) * (1 - Double(k) / 800) }
      out[i + k] = Float(g * env * v)
      k += 1
    }
    i += len
  }
  return out
}

private func episode(coldOpen: Double, intro: [Float], body: Double, seed: UInt32, gain: Double = 1) -> [Float] {
  let r = lcg(seed * 7 + 3)
  var out = music(coldOpen, seed * 11 + 1) + intro + music(body, seed * 13 + 5)
  for k in out.indices { out[k] = Float(Double(out[k]) * gain + (r() * 2 - 1) * 0.004) }
  return out
}

private let theme = music(60, 999)

private func byId(_ res: [(id: String, result: FP.Repeated)]) -> [String: FP.Repeated] {
  Dictionary(uniqueKeysWithValues: res.map { ($0.id, $0.result) })
}

@MainActor func fingerprintTests(_ t: Tests) {
  t.test("fingerprint round-trips through the on-disk format") {
    let fp = FP.compute(music(5, 1))
    let back = FP.decode(FP.encode(fp, offset: 12.5, length: 600))
    try expectEqual(back?.offset, 12.5)
    try expectEqual(back?.fp, fp)
  }

  t.test("finds a shared theme placed at different, misaligned offsets") {
    let a = episode(coldOpen: 31.37, intro: theme, body: 90, seed: 1)
    let b = episode(coldOpen: 77.912, intro: theme, body: 90, seed: 2, gain: 0.6)
    let seg = FP.findSharedSegment(FP.compute(a), FP.compute(b))
    guard let seg else { throw TestFailure(description: "expected a match") }
    let aStart = FP.frameToSec(seg.a0)
    let aEnd = FP.frameToSec(seg.a1)
    let bStart = FP.frameToSec(seg.b0)
    try expect(abs(aStart - 31.37) < 1, "a start \(aStart)")
    try expect(abs(aEnd - 91.37) < 1, "a end \(aEnd)")
    try expect(abs(bStart - 77.912) < 1, "b start \(bStart)")
  }

  t.test("unrelated audio does not match") {
    let a = FP.compute(music(180, 5))
    let b = FP.compute(music(180, 6))
    try expectEqual(FP.findSharedSegment(a, b), nil)
  }

  t.test("season detection agrees across siblings and skips an episode without the theme") {
    let opens = [10.2, 45.7, 0, 120.33, 64.1]
    let members = opens.enumerated().map { i, open in
      FP.Member(
        id: "e\(i)",
        fp: FP.compute(
          i == 3
            ? music(300, 4242)  // this one has no intro
            : episode(coldOpen: open, intro: theme, body: 60, seed: 20 + UInt32(i))),
        offset: 0)
    }
    let res = byId(FP.detectRepeatedSegments(members, members.map(\.id)))
    for (i, open) in opens.enumerated() {
      let r = res["e\(i)"]
      if i == 3 {
        try expect(r == nil, "episode without intro should have none")
        continue
      }
      guard let r else { throw TestFailure(description: "e\(i) missing") }
      try expect(abs(r.start - open) < 1, "e\(i) start \(r.start) vs \(open)")
      try expect(abs(r.end - (open + 60)) < 1, "e\(i) end \(r.end) vs \(open + 60)")
    }
  }

  t.test("segments shorter than the minimum are ignored") {
    let jingle = music(8, 77)
    let a = episode(coldOpen: 20, intro: jingle, body: 100, seed: 8)
    let b = episode(coldOpen: 50, intro: jingle, body: 100, seed: 9)
    try expectEqual(FP.findSharedSegment(FP.compute(a), FP.compute(b), FP.MatchOptions(minFrames: FP.secToFrames(15))), nil)
  }

  t.test("fingerprinting ten minutes of audio is fast") {
    let pcm = music(600, 3)
    let t0 = Date()
    _ = FP.compute(pcm)
    let ms = Date().timeIntervalSince(t0) * 1000
    try expect(ms < 5000, "took \(ms) ms")
    print("  10 min fingerprint: \(Int(ms.rounded())) ms")
  }

  t.test("a season alternating between two intro versions still finds both") {
    let themeB = music(32, 4321)
    // A A B B B A A: the first two episodes' nearest neighbours mostly use B.
    let plan = ["A", "A", "B", "B", "B", "A", "A"]
    let members = plan.enumerated().map { i, v in
      FP.Member(
        id: "e\(i)",
        fp: FP.compute(episode(coldOpen: 20 + Double(i) * 7.3, intro: v == "A" ? theme : themeB, body: 40, seed: 60 + UInt32(i))),
        offset: 0)
    }
    let res = byId(FP.detectRepeatedSegments(members, members.map(\.id)))
    for (i, v) in plan.enumerated() {
      guard let r = res["e\(i)"] else { throw TestFailure(description: "e\(i) (\(v)) missing") }
      try expect(abs(r.end - r.start - (v == "A" ? 60 : 32)) < 1.5, "e\(i) length \(r.end - r.start)")
    }
  }
}
