import Foundation

// Subtitles made on this Mac (MadeSubs): the cue rules, names, and how a made
// track is kept and shown. The test that really listens is skipped unless
// NIGHTCAP_SPEECH_TESTS=1 (speech recognition runs on the Neural Engine, so
// it goes through the GPU queue).

private func w(_ t: String, _ s: Double, _ e: Double) -> MadeSubs.Word { MadeSubs.Word(t: t, s: s, e: e) }

/// The words of `text`, said one after another, `each` seconds a word.
private func said(_ text: String, from: Double, each: Double = 0.2) -> [MadeSubs.Word] {
  text.split(separator: " ").enumerated().map { i, t in
    w(String(t), from + Double(i) * each, from + Double(i + 1) * each)
  }
}

private final class Steps {
  var seen: [MadeSubs.Step] = []
}

@MainActor func madeSubsTests(_ t: Tests) {
  let tmp = tempDir("nightcap-made-")

  t.test("made subtitles leave out fillers, and a filler's full stop passes back") {
    let out = MadeSubs.dropFillers([w("Uh,", 0, 0.2), w("I", 0.2, 0.3), w("think", 0.3, 0.5), w("so,", 0.5, 0.7), w("um.", 0.7, 0.9), w("then", 1, 1.2)])
    try expectEqual(out.map(\.t), ["I", "think", "so.", "Then"])
  }

  t.test("made subtitles leave out marks heard on their own; a full stop passes back to a word without one") {
    try expectEqual(MadeSubs.dropMarks([w(",", 0, 1), w(",", 1, 2), w(",", 2, 3)]), [])
    try expectEqual(MadeSubs.dropMarks(said(", All of my life,", from: 0)).map(\.t), ["All", "of", "my", "life,"])
    try expectEqual(MadeSubs.dropMarks(said("Good morning, Al. .", from: 0)).map(\.t), ["Good", "morning,", "Al."])
    try expectEqual(MadeSubs.dropMarks(said("! No! Clear, !", from: 0)).map(\.t), ["No!", "Clear!"])
    try expectEqual(MadeSubs.dropMarks(said("Tom & Jerry, 5 - 4", from: 0)).map(\.t), ["Tom", "&", "Jerry,", "5", "4"])
    try expectEqual(MadeSubs.cues([[w(",", 3.9, 4.8)], [w("!", 37, 38)]]), [])
  }

  t.test("sung stretches: the singing score averaged over about 5 s reaches 0.2, for 4 s or more; talk over it stays") {
    // Seconds rated every half second: talk, a song wavering 0.1-0.6 (the voice also rated a
    // little as speech), talk.
    func rate(_ singing: [Double], speech: (Int) -> Double = { _ in 0.3 }) -> [MadeSubs.Rated] {
      singing.enumerated().map { MadeSubs.Rated(start: Double($0.offset) * 0.5, duration: 1, singing: $0.element, speech: speech($0.offset)) }
    }
    let scores = Array(repeating: 0.02, count: 20) + (0..<40).map { [0.5, 0.1, 0.6, 0.3][$0 % 4] } + Array(repeating: 0.02, count: 20)
    let song = MadeSubs.sungStretches(rate(scores))
    // The song is rated from 10 s to 30.5 s: its seconds' middle halves, 10.25 to 30.25 s.
    try expectEqual(song.count, 1)
    try expect(abs(song[0].lowerBound - 10.25) < 0.01 && abs(song[0].upperBound - 30.25) < 0.01, "\(song)")
    // A line said over the song (rated far surer speech, 19 to 21.5 s) is not sung; the song
    // either side still is.
    let talkedOver = MadeSubs.sungStretches(rate(scores) { $0 >= 38 && $0 < 42 ? 0.9 : 0.3 }.enumerated().map { i, r in
      var r = r
      if i >= 38 && i < 42 { r.singing = 0.1 }
      return r
    })
    try expectEqual(talkedOver.count, 2)
    try expect(talkedOver[0].upperBound <= 19.25 && talkedOver[1].lowerBound >= 20.75, "\(talkedOver)")
    // A voice that sounds a little sung for a moment is talk.
    try expectEqual(MadeSubs.sungStretches(rate((0..<60).map { $0 >= 20 && $0 < 23 ? 0.4 : 0.02 })), [])
    try expectEqual(MadeSubs.sungStretches([]), [])
  }

  t.test("made subtitles leave out words sung, and the stretch of speech breaks there") {
    let heard = said("We got it. All of my life I've been waiting. Come on, go.", from: 10, each: 0.5)
    let out = MadeSubs.dropSung([heard], [11.6...15.0])
    try expectEqual(out.map(MadeSubs.text), ["We got it.", "Come on, go."])
    // "my" heard between sung words is sung too; three words between them are not.
    try expectEqual(MadeSubs.dropSung([heard], [11.6...12.6, 12.9...15.0]).map(MadeSubs.text), ["We got it.", "Come on, go."])
    try expectEqual(MadeSubs.dropSung([heard], [11.6...12.6, 14.1...15.0]).map(MadeSubs.text), ["We got it.", "my life I've", "Come on, go."])
    try expectEqual(MadeSubs.dropSung([heard], []), [heard])
    try expectEqual(MadeSubs.dropSung([heard], [0...9, 17...20]), [heard])
    try expectEqual(MadeSubs.dropSung([heard], [9.5...17]), [])
  }

  t.test("made subtitles: a sentence ends at . ? ! or …, maybe before a closing quote") {
    let parts = MadeSubs.sentences(said("He said \"go.\" She went… Did she?", from: 0))
    try expectEqual(parts.map(MadeSubs.text), ["He said \"go.\"", "She went…", "Did she?"])
  }

  t.test("made subtitles: a long sentence is broken at its comma, into cues that fit") {
    let ws = said("When we got to the house on the hill, the lights were off and nobody answered the door, so we went back to the car.", from: 0)
    try expect(!MadeSubs.fits(ws))
    let parts = MadeSubs.split(ws)
    try expectEqual(parts.map(MadeSubs.text), [
      "When we got to the house on the hill,", "the lights were off and nobody answered the door, so we went back to the car.",
    ])
    try expect(parts.allSatisfy(MadeSubs.fits))
  }

  t.test("made subtitles: two lines of at most 42 characters, never ending a line on \"the\"") {
    try expectEqual(MadeSubs.twoLines("Short enough."), ["Short enough."])
    try expectEqual(
      MadeSubs.twoLines("Yes, I think we should all go back to the car right now."), ["Yes, I think we should all", "go back to the car right now."])
    try expectEqual(MadeSubs.twoLines(String(repeating: "x", count: 43)), nil)
    let lines = MadeSubs.twoLines("We have to get the files from the basement before the others come back.") ?? []
    try expect(lines.count == 2 && lines.allSatisfy { $0.count <= 42 } && !lines[0].hasSuffix(" the"), "\(lines)")
  }

  t.test("made subtitles: a word's start is estimated from its length (ranges hold the silence before)") {
    try expect(abs(MadeSubs.onset(w("Mulder.", 10, 13)) - 12.46) < 1e-9)
    try expectEqual(MadeSubs.onset(w("I", 5, 5.1)), 5)
  }

  t.test("made cues linger 0.4 s, last at least 5/6 s, and stay 2 frames before the next") {
    try expectEqual(
      MadeSubs.vtt(MadeSubs.cues([[w("Hello", 1, 1.4), w("there.", 1.4, 1.9)], [w("Fine.", 10, 10.5)]])),
      "WEBVTT\n\n00:00:01.000 --> 00:00:02.300\nHello there.\n\n00:00:10.100 --> 00:00:10.933\nFine.\n\n")
    let next = said("Yes, I think we should all go back to the car right now.", from: 1.5)
    try expectEqual(
      MadeSubs.vtt(MadeSubs.cues([[w("No.", 1, 1.2)], next])),
      "WEBVTT\n\n00:00:01.000 --> 00:00:01.417\nNo.\n\n00:00:01.500 --> 00:00:04.500\nYes, I think we should all\ngo back to the car right now.\n\n")
  }

  t.test("made subtitles: a quick reply shares its question's cue, a line each") {
    let cues = MadeSubs.cues([[w("Who's", 5, 5.3), w("there?", 5.3, 5.6), w("Me.", 5.7, 6)]])
    try expectEqual(MadeSubs.vtt(cues), "WEBVTT\n\n00:00:05.000 --> 00:00:06.400\nWho's there?\nMe.\n\n")
  }

  t.test("made subtitles: a name heard several ways takes its most common spelling") {
    let unknown: Set<String> = ["Mulder", "Molder"]
    let out = MadeSubs.settleNames([
      [w("Agent", 0, 0.3), w("Mulder,", 0.3, 0.6), w("come", 0.6, 0.8), w("here.", 0.8, 1)],
      [w("I", 2, 2.1), w("told", 2.1, 2.3), w("Molder's", 2.3, 2.7), w("friend.", 2.7, 3)],
      [w("Mulder?", 4, 4.4)],
      [w("Mulder", 5, 5.3), w("said", 5.3, 5.5), w("so.", 5.5, 5.7)],
      [w("Ask", 6, 6.2), w("Bill", 6.2, 6.4), w("and", 6.4, 6.5), w("Bell.", 6.5, 6.8)],
    ]) { !unknown.contains($0) }
    try expectEqual(out[1].map(\.t), ["I", "told", "Mulder's", "friend."])
    try expectEqual(out[4].map(\.t), ["Ask", "Bill", "and", "Bell."], "two dictionary words are left alone")
    try expectEqual(out[1][2].s, 2.3)
  }

  t.test("made subtitles: times are whole milliseconds, never 60 seconds") {
    try expectEqual(MadeSubs.stamp(59.9996), "00:01:00.000")
    try expectEqual(MadeSubs.stamp(3723.004), "01:02:03.004")
    try expectEqual(MadeSubs.stamp(-1), "00:00:00.000")
  }

  t.test("made subtitles are listed as made on this Mac, numbered when there are more") {
    let subs = OnlineSubs(getTitle: { _ in nil }, media: Media())
    let file = LibraryFile(
      id: "made0000test", titleId: "t", season: 0, number: nil, name: "Clip", path: join(tmp, "none.mkv"), size: 1, mtime: 0, thumb: nil,
      subs: [])
    let a = try subs.addMade(file, "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello.\n\n", audio: 1)
    try expectEqual(a?.label, "English · Made on this Mac")
    try expectEqual(a?.source, "made")
    try expectEqual(a?.lang, "en")
    try expectEqual(a?.release, "Made on this Mac from audio track 2")
    let b = try subs.addMade(file, "WEBVTT\n\n", audio: 0, namesFrom: "TVmaze")
    try expectEqual(b?.label, "English · Made on this Mac 2")
    try expectEqual(b?.release, "Made on this Mac from audio track 1, names from TVmaze", "TVmaze is credited")
    let n = Int(a!.id.dropFirst())!
    try expect(subs.isMade(file.id, n))
    try expect(matches(subs.vtt(file.id, n) ?? "", "Hello\\."))
  }

  let engine = Engine()
  func clip(_ name: String) throws -> String {
    let path = join(tmp, name)
    try expect(FileManager.default.createFile(atPath: path, contents: Data(count: 1024)), "could not write \(path)")
    return path
  }

  t.test("made subtitles are shown as made: no advert filter") {
    let path = try clip("plain.mkv")
    let id = await engine.openPath(path)
    try expect(id != nil, "not opened")
    let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nSubtitles by explosiveskull\n\n"
    try expect(!matches(Subtext.stripAds(vtt).vtt, "explosiveskull"), "the filter would remove it")
    let track = try engine.onlineSubs.addMade(try engine.file(id!), vtt, audio: 0)!
    try expect(matches(try await engine.subtitleText(id!, track.id), "explosiveskull"))
  }

  let listen = Tools.ffmpeg == nil ? "needs ffmpeg" : ProcessInfo.processInfo.environment["NIGHTCAP_SPEECH_TESTS"] == "1" ? nil
    : "listens; run with NIGHTCAP_SPEECH_TESTS=1 through the GPU queue"
  t.test("makes subtitles from what is said, once when asked twice", skip: listen) {
    let speech = join(tmp, "speech.aiff")
    let r = try await runTool("/usr/bin/say", ["-o", speech, "The lights were off when we got to the house. Nobody answered the door."])
    try expect(r.code == 0, "say failed: \(r.lastErrorLine)")
    let video = join(tmp, "speech.mkv")
    try await ffmpeg(["-i", speech, "-af", "adelay=2000:all=1", "-c:a", "aac", "-y", video])
    let id = await engine.openPath(video)
    try expect(id != nil, "not opened")
    let steps = Steps()
    async let first = engine.makeSubtitles(id!, audio: 0) { steps.seen.append($0) }
    async let second = engine.makeSubtitles(id!, audio: 0) { _ in }
    let (a, b) = try await (first, second)
    try expectEqual(a.id, b.id, "made once")
    try expectEqual(a.source, "made")
    let tracks = try await engine.subtitleTracks(id!)
    try expectEqual(tracks.filter { $0.source == "made" }.count, 1)
    try expect(steps.seen.contains(.audio), "\(steps.seen)")
    let text = try await engine.subtitleText(id!, a.id)
    try expect(matches(text, "lights were off", ignoringCase: true) && matches(text, "answered the door", ignoringCase: true), text)
    let starts = Subtext.cueTimes(text).map(\.0)
    try expect((starts.first ?? 0) >= 1.5, "said from 2 s, shown from \(starts)")
  }

  t.after { removeItem(tmp) }
}
