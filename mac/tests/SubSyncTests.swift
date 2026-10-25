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

// 45 minutes of subtitles in made-up words: cues of 3-9 words, 1.5-4 s long.
private func script(_ seed: UInt32) -> [(start: Double, end: Double, text: String)] {
  let r = lcg(seed)
  let letters = Array("abcdefghijklmnopqrstuvwxyz")
  let vocabulary = (0..<1500).map { _ in String((0..<(3 + Int(r() * 6))).map { _ in letters[Int(r() * 26)] }) }
  var cues: [(start: Double, end: Double, text: String)] = []
  var t = 30.0
  while t < 45 * 60 {
    let d = 1.5 + r() * 2.5
    let words = (0..<(3 + Int(r() * 7))).map { _ in vocabulary[Int(r() * Double(vocabulary.count))] }
    cues.append((t, t + d, words.joined(separator: " ")))
    t += d + 0.3 + r() * 2.7
  }
  return cues
}

private func fitted(_ fit: Sync.WordsFit?, file: StaticString = #fileID, line: UInt = #line) throws -> Sync.WordsFit {
  guard let fit else { throw TestFailure(description: "\(file):\(line): no fit") }
  return fit
}

/// The words of `cues` as the recogniser hears them where `at` puts each cue (nil: not in
/// the video): each word when the subtitle has it, ±0.2 s, and about one in seven misheard.
private func hear(_ cues: [(start: Double, end: Double, text: String)], seed: UInt32, _ at: (Double) -> Double?) -> [[MadeSubs.Word]] {
  let r = lcg(seed)
  return cues.compactMap { c in
    guard let v = at(c.start) else { return nil }
    let ws = Sync.said(c.text)
    let letters = Double(ws.reduce(0) { $0 + $1.count })
    var before = 0
    return ws.map { w in
      let s = v + (c.end - c.start) * 0.9 * Double(before) / letters + (r() - 0.5) * 0.4
      before += w.count
      let heard = r() < 0.15 ? "zz" + w : w
      return MadeSubs.Word(t: heard, s: s, e: s + 0.12 + 0.07 * Double(heard.count))
    }
  }
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

  t.test("words as compared: lower case, apostrophes inside words; sounds and speakers aren't said") {
    try expectEqual(Sync.comparable("Don't GO—now, 'Mitch'!"), ["don't", "go", "now", "mitch"])
    try expectEqual(Sync.comparable("rock ’n’ roll, café"), ["rock", "n", "roll", "café"])
    try expectEqual(Sync.said("MAN: [door closes] Hey,\n<i>you</i> (laughs) {\\an8}there"), ["hey", "you", "there"])
  }

  t.test("subtitles in sync with the words heard stay as they are") {
    let cues = script(11)
    let fit = try fitted(Sync.wordsFit(cues, hear(cues, seed: 12) { $0 }))
    try expectEqual(fit.scale, 1)
    try expectEqual(fit.parts.count, 1, "\(fit.parts)")
    try expect(abs(fit.parts[0].offset) < 0.1, "\(fit.parts)")
  }

  t.test("subtitles of another cut: each part finds its offset from the words heard") {
    let cues = script(13)
    // A pause 7.3 s longer at 10:00; from 20:00, a scene of 27.3 s the video doesn't have.
    let fit = try fitted(Sync.wordsFit(cues, hear(cues, seed: 14) { t in
      t < 600 ? t : t < 1200 ? t + 7.3 : t < 1227.3 ? nil : t - 20
    }))
    try expectEqual(fit.scale, 1)
    try expectEqual(fit.parts.count, 3, "\(fit.parts)")
    try expect(zip(fit.parts.map(\.offset), [0, 7.3, -20]).allSatisfy { abs($0 - $1) < 0.15 }, "\(fit.parts)")
    try expect(abs(fit.parts[1].from - 600) < 5 && abs(fit.parts[2].from - 1213) < 15, "\(fit.parts)")
  }

  t.test("subtitles timed for 25 fps fit a 23.976 fps video's words") {
    let cues = script(15)
    let fit = try fitted(Sync.wordsFit(cues, hear(cues, seed: 16) { $0 * 25 / 23.976 + 3 }))
    try expect(abs(fit.scale - 25 / 23.976) < 1e-9, "scale \(fit.scale)")
    try expectEqual(fit.parts.count, 1, "\(fit.parts)")
    try expect(abs(fit.parts[0].offset - 3) < 0.1, "\(fit.parts)")
  }

  t.test("subtitles of another episode don't fit its words") {
    try expectEqual(Sync.wordsFit(script(17), hear(script(18), seed: 19) { $0 }), nil)
  }

  t.test("a few lines heard late don't make parts of their own") {
    let cues = script(20)
    // Five lines across the episode said 1.5 s after their subtitles have them.
    let late = Set([100, 200, 300, 400, 500].map { cues[$0].start })
    let fit = try fitted(Sync.wordsFit(cues, hear(cues, seed: 21) { $0 + 2 + (late.contains($0) ? 1.5 : 0) }))
    try expectEqual(fit.parts.count, 1, "\(fit.parts)")
    try expect(abs(fit.parts[0].offset - 2) < 0.1, "\(fit.parts)")
  }

  t.test("a fit in parts is kept on disk, and each part's cues move by its own offset") {
    let file = LibraryFile(id: "cut", titleId: "t", season: 1, number: 1, name: "Cut", path: "/cut.avi", size: 1, mtime: 0, thumb: nil, subs: [])
    let cues = script(22)
    // The video has a scene of 30 s at 15:00 that the subtitles' cut lacks.
    let heard = hear(cues, seed: 23) { $0 < 900 ? $0 : $0 + 30 }
    let vtt = "WEBVTT\n\n" + cues.map { "\(Subtext.fmtTime($0.start)) --> \(Subtext.fmtTime($0.end))\n\($0.text)" }.joined(separator: "\n\n") + "\n"
    let first = SubSync()
    let r = first.alignToWords(file, "d1", vtt, heard: heard)
    try expect(r.applied && r.parts?.count == 2, "\(r)")
    first.flush()
    // Read back as the app reads it when it starts.
    let again = SubSync()
    defer {
      again.clear(file, "d1")
      again.flush()
    }
    guard let timing = again.get(file, "d1") else { throw TestFailure(description: "no correction read back") }
    try expect(timing.byWords && timing.parts.count == 2, "\(timing)")
    let moved = Subtext.blocks(Subtext.retime(vtt, timing)).filter { $0.text != nil }.map(\.start)
    try expectEqual(moved.count, cues.count)
    for (c, t) in zip(cues, moved) where abs(c.start - 900) > 10 {
      try expect(abs(t - (c.start < 900 ? c.start : c.start + 30)) < 0.15, "\(c.start) -> \(t)")
    }
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
