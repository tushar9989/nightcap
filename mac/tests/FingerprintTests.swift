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

  // A season whose first two episodes share titles no other episode has; the
  // others share `theme` at varying points.
  func pairSeason(_ first: [Float], _ second: [Float], opens: (Double, Double)) -> [FP.Member] {
    (0..<7).map { i in
      let fp: [Float]
      switch i {
      case 0: fp = episode(coldOpen: opens.0, intro: first, body: 60, seed: 140)
      case 1: fp = episode(coldOpen: opens.1, intro: second, body: 60, seed: 141)
      default: fp = episode(coldOpen: 12 + Double(i) * 9.1, intro: theme, body: 60, seed: 140 + UInt32(i))
      }
      return FP.Member(id: "e\(i)", fp: FP.compute(fp), offset: 0)
    }
  }

  t.test("titles only two episodes share count when the pair rule is on") {
    let own = music(70, 5150)
    let members = pairSeason(own, own, opens: (20, 24.5))
    try expect(byId(FP.detectRepeatedSegments(members, ["e0", "e1"]))["e0"] == nil, "found without the pair rule")
    let res = byId(FP.detectRepeatedSegments(members, members.map(\.id), pairs: FP.PairRule()))
    for (id, open) in [("e0", 20.0), ("e1", 24.5)] {
      guard let r = res[id] else { throw TestFailure(description: "\(id) missing") }
      try expect(r.pair && r.support == 1, "\(id) not a pair: \(r)")
      try expect(abs(r.start - open) < 1 && abs(r.end - (open + 70)) < 1, "\(id) \(r.start)–\(r.end)")
    }
    try expect(res["e2"].map { !$0.pair && $0.support >= 2 } ?? false, "e2 should come from the season rule")
  }

  t.test("a pair is refused when the shared stretch is short or plays at another point") {
    let short = music(30, 5151)
    try expect(byId(FP.detectRepeatedSegments(pairSeason(short, short, opens: (20, 20)), ["e0", "e1"], pairs: FP.PairRule())).isEmpty)
    // Part one's scene replayed by part two's recap, a minute later than it first played.
    let scene = music(70, 5152)
    let members = pairSeason(scene, scene, opens: (5, 65))
    try expect(byId(FP.detectRepeatedSegments(members, ["e0", "e1"], pairs: FP.PairRule())).isEmpty)
    try expectEqual(byId(FP.detectRepeatedSegments(members, ["e0", "e1"], pairs: FP.PairRule(maxShift: nil))).count, 2)
  }

  t.test("an episode matching nothing in its season finds its intro in another season's") {
    let others = [33.3, 0, 71.9, 18.4].enumerated().map { k, open in
      FP.Member(id: "o\(k)", fp: FP.compute(episode(coldOpen: open, intro: theme, body: 60, seed: 160 + UInt32(k))), offset: 0)
    }
    let me = FP.Member(id: "me", fp: FP.compute(episode(coldOpen: 5.5, intro: theme, body: 60, seed: 170)), offset: 0)
    guard let r = FP.detectFromOthers(me, others, FP.MatchOptions(), whole: 0.75) else { throw TestFailure(description: "no intro found") }
    try expect(abs(r.start - 5.5) < 1 && abs(r.end - 65.5) < 1, "\(r.start)–\(r.end)")
    try expect(r.support >= 2 && !r.pair, "\(r)")
    // Only half of the theme, quoted in an opening song of its own: not the intro.
    let quote = Array(theme[(15 * SR)..<(45 * SR)])
    let pilot = FP.Member(id: "pilot", fp: FP.compute(episode(coldOpen: 40, intro: quote, body: 90, seed: 171)), offset: 0)
    try expect(FP.detectFromOthers(pilot, others, FP.MatchOptions()) != nil, "the quote should match")
    try expect(FP.detectFromOthers(pilot, others, FP.MatchOptions(), whole: 0.75) == nil, "a quote taken for the intro")
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
