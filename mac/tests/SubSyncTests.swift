import Foundation

private let RATE = Sync.rate

// 40 minutes of "dialogue": lines of 1-4 s with pauses, plus music and noise
// that have no subtitles, as a speech-activity curve and the true line times.
private func episode(_ seed: UInt32) -> (act: [Float], lines: [(Double, Double)]) {
  let r = lcg(seed)
  let len = 40 * 60 * RATE
  var act = [Float](repeating: 0, count: len)
  for i in 0..<len { act[i] = Float(r() * 0.25) }
  var lines: [(Double, Double)] = []
  func fill(_ t: Double, _ d: Double, _ value: () -> Double) {
    var i = Int(jsRound(t * Double(RATE)))
    while Double(i) < min(Double(len), (t + d) * Double(RATE)) {
      act[i] = Float(value())
      i += 1
    }
  }
  var t = 20.0
  while t < 40 * 60 - 10 {
    if r() < 0.08 {
      // a music cue: loud, but nobody speaks
      let d = 10 + r() * 30
      fill(t, d) { 0.5 + r() * 0.5 }
      t += d + 1
      continue
    }
    let d = 1 + r() * 3
    lines.append((t, t + d))
    fill(t, d) { 0.55 + r() * 0.45 }
    t += d + 0.4 + r() * 5
  }
  return (act, lines)
}

private func distort(_ lines: [(Double, Double)], offset: Double = 0, scale: Double = 1) -> [(Double, Double)] {
  lines.map { ($0.0 * scale + offset, $0.1 * scale + offset) }
}

@MainActor func subSyncTests(_ t: Tests) {
  t.test("finds a constant delay") {
    let (act, lines) = episode(1)
    let r = Sync.bestAlignment(act, distort(lines, offset: 3.7))
    try expect(r.confident, "\(r)")
    try expectEqual(r.scale, 1)
    try expect(abs(r.offset + 3.7) <= 0.04, "offset \(r.offset)")
  }

  t.test("finds subtitles timed for 25 fps on a 23.976 fps video") {
    let (act, lines) = episode(2)
    // Timed for the faster PAL release: everything is 4% early, plus a cut logo.
    let r = Sync.bestAlignment(act, distort(lines, offset: -12.3, scale: 23.976 / 25))
    try expect(r.confident, "\(r)")
    try expect(abs(r.scale - 25 / 23.976) < 1e-9, "scale \(r.scale)")
    // t_video = (t_sub) * 25/23.976 + offset, with t_sub = t * 23.976/25 - 12.3
    try expect(abs(r.offset - 12.3 * (25 / 23.976)) <= 0.06, "offset \(r.offset)")
  }

  t.test("subtitles of another episode are not trusted") {
    let a = episode(3)
    let b = episode(4)
    let r = Sync.bestAlignment(a.act, b.lines)
    try expectEqual(r.confident, false, "\(r)")
  }

  t.test("speech activity rises above the local noise floor") {
    var db = [Float](repeating: 30, count: 60 * RATE)
    for i in (20 * RATE)..<(22 * RATE) { db[i] = 55 }  // a line of dialogue
    for i in (40 * RATE)..<(41 * RATE) { db[i] = 33 }  // a faint rustle
    let act = Sync.activityFromEnergy(db)
    try expectEqual(act[21 * RATE], 1)
    try expectEqual(act[10 * RATE], 0)
    try expectEqual(act[40 * RATE + 10], 0)
  }
}
