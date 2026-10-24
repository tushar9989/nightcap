import Foundation

private func tree(_ files: [String]) -> String {
  let root = tempDir("nightcap-scan-")
  for f in files {
    let p = join(root, f)
    try! FileManager.default.createDirectory(atPath: dirname(p), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: p, contents: Data())
  }
  return root
}

private struct SeasonDesc: Equatable {
  var name: String
  var episodes: [String]
  init(_ name: String, _ episodes: [String]) {
    self.name = name
    self.episodes = episodes
  }
}

private struct TitleDesc: Equatable {
  var kind: String
  var name: String
  var year: Int?
  var seasons: [SeasonDesc]
}

private func scan(_ root: String, _ kind: String = "auto") -> [TitleDesc] {
  let lib = Scanner.scanLibrary([Folder(id: "f", path: root, kind: kind, addedAt: 0)])
  return lib.titles.map { t in
    TitleDesc(kind: t.kind, name: t.name, year: t.year, seasons: t.seasons.map { s in SeasonDesc(s.name, s.episodes.map { lib.files[$0]!.name }) })
  }
}

@MainActor func scannerTests(_ t: Tests) {
  t.test("show folder with seasons, films and extras") {
    let root = tree([
      "The X-Files Season 1, 2 & 3 + Extras DVDRip/Season 01/The X-Files Season 01 Episode 02 - Deep Throat.avi",
      "The X-Files Season 1, 2 & 3 + Extras DVDRip/Season 01/The X-Files Season 01 Episode 01 - Pilot.avi",
      "The X-Files Season 1, 2 & 3 + Extras DVDRip/Season 01/The X-Files Season 01 Episode 01 - Pilot.srt",
      "The X-Files Season 1, 2 & 3 + Extras DVDRip/Season 02/The X-Files Season 02 Episode 10 - Red Museum.avi",
      "The X-Files Season 1, 2 & 3 + Extras DVDRip/Season 02/The X-Files Season 02 Episode 9 - Firewalker.avi",
      "The X-Files Season 1, 2 & 3 + Extras DVDRip/Films/Fight the Future/Fight the Future.avi",
      "The X-Files Season 1, 2 & 3 + Extras DVDRip/Extras/Season 01 Extras/Deleted Scenes/Scene 1.mp4",
      "The X-Files Season 1, 2 & 3 + Extras DVDRip/TSV/Read Me.txt",
      "The X-Files Season 1, 2 & 3 + Extras DVDRip/Season 01/._The X-Files Season 01 Episode 01 - Pilot.avi",
    ])
    let titles = scan(root)
    guard let show = titles.first(where: { $0.kind == "show" }) else { throw TestFailure(description: "no show") }
    try expectEqual(show.name, "The X-Files")
    try expectEqual(show.seasons, [
      SeasonDesc("Season 1", ["Pilot", "Deep Throat"]),
      SeasonDesc("Season 2", ["Firewalker", "Red Museum"]),
      SeasonDesc("Extras", ["Season 01 Extras › Scene 1"]),
    ])
    try expectEqual(titles.filter { $0.kind == "movie" }.map(\.name), ["Fight the Future"])
    let lib = Scanner.scanLibrary([Folder(id: "f", path: root, kind: "auto", addedAt: 0)])
    let pilot = lib.files.values.first { $0.name == "Pilot" }
    try expectEqual(pilot?.subs.count, 1)
  }

  t.test("flat release-style episodes become one season") {
    let root = tree([
      "Breaking.Bad.S01.720p/Breaking.Bad.S01E02.Cats.in.the.Bag.720p.mkv", "Breaking.Bad.S01.720p/Breaking.Bad.S01E01.Pilot.720p.mkv",
      "Breaking.Bad.S01.720p/Breaking.Bad.S01E01.sample.mkv",
    ])
    let show = scan(root)[0]
    try expectEqual(show.kind, "show")
    try expectEqual(show.name, "Breaking Bad")
    try expectEqual(show.seasons, [SeasonDesc("Season 1", ["Pilot", "Cats in the Bag"])])
  }

  t.test("a TV folder holding several shows") {
    let root = tree([
      "Friends/Season 1/Friends S01E01.mkv", "Friends/Season 2/Friends S02E01.mkv", "Frieren/[Subs] Frieren - 01 [1080p].mkv",
      "Frieren/[Subs] Frieren - 02 [1080p].mkv",
    ])
    let titles = scan(root)
    try expectEqual(titles.map { "\($0.kind) \($0.name) \($0.seasons.count)" }, ["show Friends 2", "show Frieren 1"])
  }

  t.test("movies folder: one title per film, extras ignored") {
    let root = tree(["Inception (2010)/Inception.2010.1080p.BluRay.x264.mkv", "Inception (2010)/Featurettes/Making of.mkv", "The.Matrix.1999.1080p.mkv"])
    let titles = scan(root)
    try expectEqual(titles.map { "\($0.kind) \($0.name) \($0.year.map(String.init) ?? "null")" }, ["movie Inception 2010", "movie The Matrix 1999"])
  }

  t.test("a season folder added on its own is named after the show") {
    let root = tree(["Severance/Season 2/Severance S02E01.mkv", "Severance/Season 2/Severance S02E02.mkv"])
    let show = scan(join(root, "Severance", "Season 2"))[0]
    try expectEqual(show.name, "Severance")
    try expectEqual(show.seasons.map(\.name), ["Season 2"])
  }

  t.test("name parsing") {
    try expectEqual(
      Scanner.parseEpisode("The X-Files Season 09 Episode 19 & 20 - The Truth"), Scanner.Episode(season: 9, episode: 19, title: "The Truth", strong: true))
    try expectEqual(Scanner.parseEpisode("Show 1x05 The Thing").episode, 5)
    try expectEqual(Scanner.parseEpisode("[Group] Show - 03 [1080p]").episode, 3)
    try expectEqual(Scanner.parseEpisode("The X-Files Season 03 Episode 03 - D.P.O").title, "D.P.O")
    let blade = Scanner.parseTitle("Blade.Runner.2049.2017.1080p.BluRay")
    try expectEqual(blade.name, "Blade Runner 2049")
    try expectEqual(blade.year, 2017)
    try expectEqual(Scanner.seasonNumber("Specials"), 0)
    try expectEqual(Scanner.seasonNumber("Show.S03.720p"), 3)
    try expectEqual(Scanner.seasonNumber("Extras"), nil)
  }

  t.test("season release folders of one show merge into one show") {
    let root = tree([
      "Breaking.Bad.S01.720p.BluRay/Breaking.Bad.S01E01.720p.mkv", "Breaking.Bad.S02.720p.BluRay/Breaking.Bad.S02E01.720p.mkv",
      "Breaking Bad/Breaking Bad Season 3/Breaking.Bad.S03E01.mkv",
    ])
    let titles = scan(root)
    try expectEqual(titles.count, 1)
    try expectEqual(titles[0].name, "Breaking Bad")
    try expectEqual(titles[0].seasons.map(\.name), ["Season 1", "Season 2", "Season 3"])
  }

  t.test("loose episode files and single-episode folders group into shows") {
    let root = tree([
      "Severance.S02E01.1080p.mkv", "Severance.S02E02.1080p.mkv", "Some.Movie.2021.1080p.mkv", "Doctor.Who.2005.S01E05.720p/Doctor.Who.2005.S01E05.720p.mkv",
      "Doctor.Who.2005.S01E06.720p/Doctor.Who.2005.S01E06.720p.mkv",
    ])
    let titles = scan(root)
    try expectEqual(
      titles.map { t in "\(t.kind) \(t.name) \(t.year.map(String.init) ?? "null") \(t.seasons.map { "\($0.name):\($0.episodes.count)" }.joined(separator: ","))" },
      ["show Doctor Who 2005 Season 1:2", "show Severance null Season 2:2", "movie Some Movie 2021 :1"])
  }

  t.test("a video opened on its own takes its subtitles and thumbnail from its folder") {
    let root = tree([
      "Downloads/Severance.S02E01.1080p.mkv", "Downloads/Severance.S02E01.1080p.en.srt", "Downloads/Severance.S02E01.1080p-thumb.jpg",
      "Downloads/Severance.S02E02.1080p.mkv", "Downloads/Severance.S02E02.1080p.en.srt",
      "Downloads/Subs/Severance.S02E01.1080p/2_English.srt", "Downloads/Other Show/Other.S01E01.mkv",
      "Downloads/Other Show/Other.S01E01.srt", "Downloads/Clip-sample.mp4",
    ])
    let path = join(root, "Downloads/Severance.S02E01.1080p.mkv")
    guard let f = Scanner.looseFile(path) else { throw TestFailure(description: "not opened") }
    try expectEqual(f.id, hashId(path))
    try expectEqual(f.name, "Severance.S02E01.1080p")
    try expectEqual(f.titleId, "")
    try expectEqual(f.season, -1)
    try expectEqual(f.thumb, join(root, "Downloads/Severance.S02E01.1080p-thumb.jpg"))
    try expectEqual(
      f.subs, [
        SubRef(path: join(root, "Downloads/Severance.S02E01.1080p.en.srt"), label: "English"),
        SubRef(path: join(root, "Downloads/Subs/Severance.S02E01.1080p/2_English.srt"), label: "English"),
      ])
    // A file the scan passes over by its name still opens.
    try expectEqual(Scanner.looseFile(join(root, "Downloads/Clip-sample.mp4"))?.name, "Clip-sample")
    try expectEqual(Scanner.looseFile(join(root, "Downloads/Missing.mkv")), nil)
    try expectEqual(Scanner.looseFile(join(root, "Downloads/Subs")), nil)
  }

  // Names as one uploader's packs have them (2026-10-24): Baywatch Nights had been taken for
  // seasons 1 and 2 of Baywatch, and a Rockford Files episode for one of Magnum's.
  t.test("a spin-off in a show's folder is a show of its own; its films are named from the file") {
    let b = "Baywatch S01-S11 (1989-) + Nights"
    let root = tree([
      "\(b)/Baywatch S01 (360p re-dvdrip)/Baywatch S01E01 Panic At Malibu Pier.mp4",
      "\(b)/Baywatch S01 (360p re-dvdrip)/Baywatch S01E02 In Deep.mp4",
      "\(b)/Baywatch S02 (360p re-dvdrip)/Baywatch S02E01+E02 Nightmare Bay.mp4",
      "\(b)/Baywatch S02 (360p re-dvdrip)/Baywatch S02E03 The One That Got Away.mp4",
      "\(b)/Baywatch S11M01 Hawaiian Wedding (2003 360p re-dvdrip).mp4",
      "\(b)/Xtras - Baywatch Nights S01 (1995- 360p re-dvdrip)/Baywatch Nights S01E01 Pursuit.mp4",
      "\(b)/Xtras - Baywatch Nights S01 (1995- 360p re-dvdrip)/Baywatch Nights S01E02 Bad Blades.mp4",
      "\(b)/Xtras - Baywatch Nights S02 (360p re-dvdrip)/Baywatch Nights S02E01Terror of the Deep.mp4",
      "\(b)/Xtras - Baywatch Nights S02 (360p re-dvdrip)/Baywatch Nights S02E02 Creature.mp4",
      "\(b)/Xtras - Movies/Baywatch M01 (2017 360p re-blurip).mp4",
    ])
    try expectEqual(
      scan(join(root, b)),
      [
        TitleDesc(
          kind: "show", name: "Baywatch", year: nil,
          seasons: [
            SeasonDesc("Season 1", ["Panic At Malibu Pier", "In Deep"]),
            SeasonDesc("Season 2", ["Nightmare Bay", "The One That Got Away"]),
            SeasonDesc("Specials", ["Hawaiian Wedding"]),
          ]),
        TitleDesc(kind: "movie", name: "Baywatch", year: 2017, seasons: [SeasonDesc("", ["Baywatch"])]),
        TitleDesc(
          kind: "show", name: "Baywatch Nights", year: nil,
          seasons: [
            SeasonDesc("Season 1", ["Pursuit", "Bad Blades"]),
            SeasonDesc("Season 2", ["Terror of the Deep", "Creature"]),
          ]),
      ])
  }

  t.test("another show's episode in a show's Xtras folder is one of its extras") {
    let m = "Magnum PI S01-S08 (1980-)"
    let root = tree([
      "\(m)/Magnum PI S05 (360p re-dvdrip)/Magnum PI S05E04 The Legacy of Garwood Huddle.mp4",
      "\(m)/Magnum PI S05 (360p re-dvdrip)/Magnum PI S05E05 Under World.mp4",
      "\(m)/Magnum PI S07 (360p re-dvdrip)/Magnum PI S07E08a Novel Connection.mp4",
      "\(m)/Magnum PI S07 (360p re-dvdrip)/Magnum PI S07E08b Magnum on Ice (Murder She Wrote S03E08).mp4",
      "\(m)/Magnum PI S07 (360p re-dvdrip)/Magnum PI S07E09 Kapu.mp4",
      "\(m)/Xtras/The Rockford Files S05E04 White on White and Nearly Perfect.mp4",
    ])
    try expectEqual(
      scan(join(root, m)),
      [
        TitleDesc(
          kind: "show", name: "Magnum PI", year: nil,
          seasons: [
            SeasonDesc("Season 5", ["The Legacy of Garwood Huddle", "Under World"]),
            SeasonDesc("Season 7", ["Novel Connection", "Magnum on Ice (Murder She Wrote S03E08)", "Kapu"]),
            SeasonDesc("Extras", ["The Rockford Files S05E04 White on White and Nearly Perfect"]),
          ])
      ])
    let lib = Scanner.scanLibrary([Folder(id: "f", path: join(root, m), kind: "auto", addedAt: 0)])
    try expectEqual(lib.titles[0].seasons[1].episodes.map { lib.files[$0]!.number }, [8, 8, 9])
  }
}
