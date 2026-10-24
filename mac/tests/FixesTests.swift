import Foundation

// Fixing lines of made subtitles (LineFixes, Engine.fixMadeLine): the line in
// the track, the log, the names a fix teaches, the same word respelt elsewhere,
// undoing it.

@MainActor func fixesTests(_ t: Tests) {
  // The dictionary, as far as these tests need it (words in lower case are all known).
  let dictionary: Set<String> = ["colonel", "will", "ranger", "ask", "the", "it's", "i"]
  let known: (String) -> Bool = { $0.first?.isLowercase == true || dictionary.contains($0.lowercased()) }
  let vtt = """
    WEBVTT

    00:00:01.000 --> 00:00:02.500
    Colonel Boudhaas
    is here.

    00:00:03.000 --> 00:00:04.000
    Ask Boudhaas, now.

    00:00:05.000 --> 00:00:06.000
    Will you go?

    00:00:07.000 --> 00:00:08.000
    I said Will.


    """

  t.test("fixed lines: as typed, spaces made one; one long line broken in two as made cues are") {
    try expectEqual(LineFixes.lines("  Colonel   Budahas \n\n is here. "), ["Colonel Budahas", "is here."])
    try expectEqual(LineFixes.lines("Yes, I think we should all go back to the car right now."), ["Yes, I think we should all", "go back to the car right now."])
    try expectEqual(LineFixes.lines(" \n "), [])
  }

  t.test("fixed lines: the cue at those times reading that text is replaced, or taken out") {
    let out = LineFixes.replace(vtt, start: 1, end: 2.5, before: "Colonel Boudhaas is here.", with: ["Colonel Budahas is here."])
    try expect(out?.contains("00:00:01.000 --> 00:00:02.500\nColonel Budahas is here.\n\n00:00:03.000") == true, out ?? "nil")
    try expectEqual(LineFixes.replace(vtt, start: 1, end: 2.5, before: "Somebody else", with: ["x"]), nil, "not the line shown")
    try expectEqual(LineFixes.replace(vtt, start: 1.2, end: 2.5, before: "Colonel Boudhaas is here.", with: ["x"]), nil, "not those times")
    let gone = LineFixes.replace(vtt, start: 3, end: 4, before: "Ask Boudhaas, now.", with: []) ?? ""
    try expect(!gone.contains("Ask") && gone.contains("Will you go?") && gone.hasSuffix("I said Will.\n\n"), gone)
  }

  t.test("fixed lines teach the names they correct, with the word replaced when one replaced one") {
    try expectEqual(
      LineFixes.taught(before: "Colonel Boudhaas is here.", after: "Colonel Budahas is here.", known: known),
      [LineFixes.Respelling(heard: "Boudhaas", name: "Budahas")])
    try expectEqual(LineFixes.taught(before: "Ask Buddha has", after: "Ask Budahas", known: known), [LineFixes.Respelling(heard: nil, name: "Budahas")])
    try expectEqual(LineFixes.taught(before: "It's budahas.", after: "It's Budahas.", known: known), [LineFixes.Respelling(heard: "budahas", name: "Budahas")])
    try expectEqual(LineFixes.taught(before: "the ranger said", after: "the Ranger said", known: known), [], "a word the dictionary knows")
    try expectEqual(LineFixes.taught(before: "Ask Mr. Kane.", after: "Ask Mr. Kane.", known: known), [], "nothing changed")
  }

  t.test("a fixed name is respelt in the track's other lines; a word the dictionary knows only mid-sentence") {
    let a = LineFixes.respell(vtt, heard: "Boudhaas", as: "Budahas", except: (1, 2.5), known: known)
    try expectEqual(a.cues, 1)
    try expect(a.vtt.contains("Colonel Boudhaas\nis here.") && a.vtt.contains("Ask Budahas, now."), a.vtt)
    let b = LineFixes.respell(vtt, heard: "Will", as: "Weil", except: (0, 0), known: known)
    try expectEqual(b.cues, 1)
    try expect(b.vtt.contains("Will you go?") && b.vtt.contains("I said Weil."), b.vtt)
  }

  let engine = Engine()
  t.test("fixing a made line: kept in the track and the log, the name learned for the show and respelt elsewhere; undone") {
    let root = tempDir("nightcap-fix-")
    let path = join(root, "Testshow", "Season 1", "Testshow S01E01.mkv")
    try FileManager.default.createDirectory(atPath: dirname(path), withIntermediateDirectories: true)
    try expect(FileManager.default.createFile(atPath: path, contents: Data(count: 1024)), "could not write \(path)")
    _ = try await engine.addFolder(root, kind: "shows")
    let id = hashId(path)
    let f = try engine.file(id)
    try expect(!f.titleId.isEmpty, "not in the library")
    let track = try engine.onlineSubs.addMade(f, vtt, audio: 0)!
    let done = try engine.fixMadeLine(id, track.id, start: 1, end: 2.5, before: "Colonel Boudhaas\nis here.", after: "Colonel Budahas is here.")
    try expectEqual(done.fix.learned, ["Budahas"])
    try expectEqual(done.fix.elsewhere, 1)
    try expectEqual(done.fix.after, "Colonel Budahas is here.")
    let text = try await engine.subtitleText(id, track.id)
    try expect(matches(text, "Colonel Budahas is here\\.") && matches(text, "Ask Budahas, now\\.") && !matches(text, "Boudhaas"), text)
    try expectEqual(engine.names.learned(f.titleId), ["Budahas"])
    try expectEqual(engine.learnedNames().map(\.title), ["Testshow"])
    try expectEqual(engine.fixes.data.fixes.last, done.fix)
    do {
      _ = try engine.fixMadeLine(id, track.id, start: 1, end: 2.5, before: "Colonel Boudhaas\nis here.", after: "x")
      throw TestFailure(description: "a line no longer there was fixed")
    } catch let e as EngineError {
      try expectEqual(e.status, 409)
    }
    let back = try engine.undoFix(done)
    try expectEqual(back, vtt)
    try expectEqual(try await engine.subtitleText(id, track.id), vtt)
    try expectEqual(engine.names.learned(f.titleId), [])
    try expect(!engine.fixes.data.fixes.contains(done.fix), "still in the log")
    for folder in engine.config.data.folders { _ = await engine.removeFolder(folder.id) }
  }

  t.test("only made subtitles can be fixed") {
    let root = tempDir("nightcap-fix2-")
    let path = join(root, "clip.mkv")
    try expect(FileManager.default.createFile(atPath: path, contents: Data(count: 1024)), "could not write \(path)")
    let id = await engine.openPath(path)
    try expect(id != nil, "not opened")
    do {
      _ = try engine.fixMadeLine(id!, "d999", start: 1, end: 2, before: "a", after: "b")
      throw TestFailure(description: "fixed a track that isn't made")
    } catch let e as EngineError {
      try expectEqual(e.status, 400)
    }
  }
}
