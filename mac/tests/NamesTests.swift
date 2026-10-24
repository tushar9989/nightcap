import Foundation

// Names expected in made subtitles (ShowNames): the words taken from TVmaze's
// characters and summaries, the lookups (against a stand-in TVmaze, cached),
// names learned from fixes; and MadeSubs respelling what it heard as them.

private func w(_ t: String, _ s: Double, _ e: Double) -> MadeSubs.Word { MadeSubs.Word(t: t, s: s, e: e) }

/// A stand-in for TVmaze: The X-Files, its cast, one episode and its guests; counts requests.
private final class FakeTVmaze: @unchecked Sendable {
  private(set) var paths: [String] = []
  private var server: FakeHTTP!
  var base: String { "http://127.0.0.1:\(server.port)" }

  init() {
    server = FakeHTTP { [unowned self] req in handle(req) }
  }

  private func send(_ status: Int, _ json: String) -> FakeHTTP.Response {
    FakeHTTP.Response(status: status, type: "application/json", body: Data(json.utf8))
  }

  private func handle(_ req: FakeHTTP.Request) -> FakeHTTP.Response {
    paths.append(req.path + (req.query.isEmpty ? "" : "?\(req.query)"))
    switch req.path {
    case "/search/shows":
      return send(200, """
        [{"score": 0.9, "show": {"id": 7, "name": "The X-Files", "premiered": "2016-01-24"}},
         {"score": 0.8, "show": {"id": 430, "name": "The X-Files", "premiered": "1993-09-10"}},
         {"score": 0.5, "show": {"id": 9, "name": "The X-Files: Origins", "premiered": "2017-01-01"}}]
        """)
    case "/shows/430/cast":
      return send(200, """
        [{"person": {"name": "David Duchovny"}, "character": {"name": "Special Agent Fox Mulder"}},
         {"person": {"name": "Gillian Anderson"}, "character": {"name": "Special Agent Dana Scully"}}]
        """)
    case "/shows/430/episodebynumber" where req.query == "number=2&season=1":
      return send(200, """
        {"id": 40421, "name": "Deep Throat",
         "summary": "<p>Mulder and Scully head to Ellens Air Force Base, where Mulder meets &quot;Deep Throat&quot;.</p>"}
        """)
    case "/shows/430/episodebynumber":
      return send(404, #"{"name": "Not Found", "status": 404}"#)
    case "/episodes/40421/guestcast":
      return send(200, """
        [{"person": {"name": "Andrew Johnston"}, "character": {"name": "Lt. Col. Robert Budahas"}},
         {"person": {"name": "Someone Uncredited"}, "character": null},
         {"person": {"name": "Michael Puttonen"}, "character": {"name": "Motel Manager"}},
         {"person": {"name": "Sheila Moore"}, "character": {"name": "Verla McLennen"}}]
        """)
    default:
      return send(404, "{}")
    }
  }
}

@MainActor func namesTests(_ t: Tests) {
  let tmp = tempDir("nightcap-names-")
  // The dictionary, as far as these tests need it (words in lower case are all known).
  let dictionary: Set<String> = [
    "fox", "dana", "scully", "robert", "motel", "manager", "air", "force", "base", "deep", "throat", "verla", "ellens", "ranger", "roger",
    "nobody", "that's", "colonel", "mrs", "mr", "dr", "ask", "they", "molder",
  ]
  let known: (String) -> Bool = { $0.first?.isLowercase == true || dictionary.contains($0.lowercased()) }

  t.test("names: characters' and summaries' words the dictionary doesn't know, 4 letters or more, no titles") {
    let out = ShowNames.words(
      characters: ["Special Agent Fox Mulder", "Lt. Col. Robert Budahas", "Motel Manager", "Zoe", "Mrs. Anita Budahas's"],
      summary: "<p>Mulder meets &quot;Deep Throat&quot; at Ellens Air Force Base. Nobody asks Kissell.</p>", known: known)
    try expectEqual(out, ["Mulder", "Budahas", "Anita", "Kissell"])
  }

  t.test("names: TVmaze's show of the same name and first year, its cast and the episode's guests, kept") {
    let fake = FakeTVmaze()
    let names = ShowNames(store: JsonStore(join(tmp, "names-a.json"), defaults: NamesData()), base: fake.base)
    let title = Title(id: "xf", kind: "show", name: "The X-Files", year: 1993, folderIds: [], poster: nil, backdrop: nil, seasons: [], addedAt: 0)
    let file = LibraryFile(id: "dt", titleId: "xf", season: 0, number: 2, name: "Deep Throat", path: "/x.avi", size: 1, mtime: 0, thumb: nil, subs: [])
    let found = await names.names(for: file, title: title, episode: (1, 2), known: known)
    try expectEqual(found.names, ["Mulder", "Budahas", "McLennen"])
    try expect(found.fromTVmaze)
    try expectEqual(fake.paths, [
      "/search/shows?q=The%20X-Files", "/shows/430/cast", "/shows/430/episodebynumber?number=2&season=1", "/episodes/40421/guestcast",
    ])
    // Asked again: from what was kept.
    _ = await names.names(for: file, title: title, episode: (1, 2), known: known)
    try expectEqual(fake.paths.count, 4)
    // An episode TVmaze doesn't have: only the show's.
    let none = await names.names(for: file, title: title, episode: (1, 99), known: known)
    try expectEqual(none, ShowNames.Found(names: [], fromTVmaze: false))
  }

  t.test("names: no TVmaze lookup for a film, and none found when it can't be reached") {
    let names = ShowNames(store: JsonStore(join(tmp, "names-b.json"), defaults: NamesData()), base: "http://127.0.0.1:9")
    let film = Title(id: "f", kind: "movie", name: "Fight the Future", year: 1998, folderIds: [], poster: nil, backdrop: nil, seasons: [], addedAt: 0)
    let show = Title(id: "s", kind: "show", name: "The X-Files", year: nil, folderIds: [], poster: nil, backdrop: nil, seasons: [], addedAt: 0)
    let file = LibraryFile(id: "a", titleId: "f", season: 0, number: nil, name: "Film", path: "/f.mkv", size: 1, mtime: 0, thumb: nil, subs: [])
    names.learn(["Kurtzweil"], for: "f")
    try expectEqual(await names.names(for: file, title: film, episode: nil, known: known), ShowNames.Found(names: ["Kurtzweil"]))
    try expectEqual(await names.names(for: file, title: show, episode: (1, 2), known: known), ShowNames.Found())
  }

  t.test("names: learned for a title, each once, and forgotten") {
    let names = ShowNames(store: JsonStore(join(tmp, "names-c.json"), defaults: NamesData()), base: "http://127.0.0.1:9")
    try expectEqual(names.learn(["Budahas", "Okoboji"], for: "xf"), ["Budahas", "Okoboji"])
    try expectEqual(names.learn(["budahas", "Brullet"], for: "xf"), ["Brullet"])
    try expectEqual(names.learned("xf"), ["Budahas", "Okoboji", "Brullet"])
    names.forget(["OKOBOJI"], for: "xf")
    try expectEqual(names.learned("xf"), ["Budahas", "Brullet"])
    names.store.flush()
    let again = ShowNames(store: JsonStore(join(tmp, "names-c.json"), defaults: NamesData()), base: "http://127.0.0.1:9")
    try expectEqual(again.learned("xf"), ["Budahas", "Brullet"])
  }

  t.test("made subtitles: a spelling heard that is nearly an expected name becomes it, and so does its group") {
    let out = MadeSubs.settleNames([
      [w("That's", 0, 0.3), w("Colonel", 0.3, 0.6), w("Robert", 0.6, 0.9), w("Boudhaus.", 0.9, 1.4)],
      [w("Mrs.", 2, 2.3), w("Boudhaas", 2.3, 2.8), w("has", 2.8, 3), w("gone.", 3, 3.3)],
      [w("Boudaus?", 4, 4.5)],
      [w("Ask", 5, 5.2), w("Ranger", 5.2, 5.5), w("Brulé.", 5.5, 6)],
      [w("Mr.", 7, 7.2), w("Mulder,", 7.2, 7.6), w("Molder", 7.6, 8), w("said", 8, 8.2), w("so.", 8.2, 8.4)],
    ], known: known, names: ["Budahas", "Brullet", "Mulder", "Roger", "Mor"])
    try expectEqual(out.map(MadeSubs.text), [
      "That's Colonel Robert Budahas.", "Mrs. Budahas has gone.", "Budahas?", "Ask Ranger Brullet.", "Mr. Mulder, Mulder said so.",
    ])
    try expectEqual(out[1][1].s, 2.3)
  }

  t.test("made subtitles: no expected name nearer than another, none for a title, none in the dictionary") {
    try expectEqual(MadeSubs.nameFor("Kissel", in: ["Kissell", "Kissela"]), nil, "a tie")
    try expectEqual(MadeSubs.nameFor("Mr", in: ["Mrs"]), nil)
    let out = MadeSubs.settleNames([[w("Ask", 0, 0.2), w("Ranger", 0.2, 0.5), w("Roger.", 0.5, 0.9)]], known: known, names: ["Roger"])
    try expectEqual(MadeSubs.text(out[0]), "Ask Ranger Roger.", "Roger is a word: never a target")
  }

  t.test("made subtitles: a title's full stop doesn't end the sentence") {
    let parts = MadeSubs.sentences([w("They", 0, 0.2), w("asked", 0.2, 0.4), w("Mrs.", 0.4, 0.6), w("Budahas.", 0.6, 1), w("Dr.", 1.2, 1.4), w("Scully?", 1.4, 1.8)])
    try expectEqual(parts.map(MadeSubs.text), ["They asked Mrs. Budahas.", "Dr. Scully?"])
  }

  t.after { removeItem(tmp) }
}
