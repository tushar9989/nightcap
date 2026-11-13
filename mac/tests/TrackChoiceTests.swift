import Foundation

// Each show's audio track (TrackChoice): the track chosen in one episode found
// again in the others, by language, name and place; and the list of shows kept.

private func a(_ lang: String, _ title: String = "", default d: Bool = false) -> ProbeInfo.Audio {
  ProbeInfo.Audio(index: 0, codec: "aac", channels: 2, lang: lang, title: title, default: d)
}

@MainActor
func trackChoiceTests(_ t: Tests) {
  t.test("audio: a language only plays the first track in it, else the default (as before)") {
    let tracks = [a("eng", default: true), a("jpn"), a("jpn", "Commentary")]
    try expectEqual(AudioChoice.pick(tracks, nil), 0, "nothing chosen: the default")
    try expectEqual(AudioChoice.pick(tracks, AudioChoice(lang: "jpn")), 1)
    try expectEqual(AudioChoice.pick(tracks, AudioChoice(lang: "JPN")), 1, "case does not matter")
    try expectEqual(AudioChoice.pick(tracks, AudioChoice(lang: "fre")), 0, "none in it: the default")
    try expectEqual(AudioChoice.pick(tracks, AudioChoice(lang: "")), 0, "no language: nothing chosen")
    let noDefault = [a("eng"), a("jpn")]
    try expectEqual(AudioChoice.pick(noDefault, nil), 0, "no default flag: the first")
    try expectEqual(AudioChoice.pick([a("jpn")], AudioChoice(lang: "eng")), 0, "a single track")
    try expectEqual(AudioChoice.pick([], AudioChoice(lang: "eng")), 0, "no tracks")
  }

  t.test("audio: a commentary chosen in one episode is chosen in the next") {
    let ep1 = [a("eng", default: true), a("eng", "Commentary")]
    let choice = AudioChoice(ep1, 1)
    try expect(choice.lang == "eng" && choice.title == "Commentary" && choice.position == 1, "\(choice)")
    try expectEqual(AudioChoice.pick(ep1, choice), 1)
    // By its name, wherever it sits.
    try expectEqual(AudioChoice.pick([a("eng", "Commentary"), a("eng", default: true)], choice), 0)
    try expectEqual(AudioChoice.pick([a("jpn", default: true), a("eng"), a("eng", "Commentary")], choice), 2)
    // Names missing: by its place among the tracks in that language.
    try expectEqual(AudioChoice.pick([a("eng", default: true), a("eng")], choice), 1)
    // No second English track: the first.
    try expectEqual(AudioChoice.pick([a("jpn", default: true), a("eng")], choice), 1)
    // No English: the default.
    try expectEqual(AudioChoice.pick([a("ger"), a("fre", default: true)], choice), 1)
  }

  t.test("audio: the main track chosen back stays the main track") {
    let ep1 = [a("eng", "Commentary"), a("eng", default: true)]
    let choice = AudioChoice(ep1, 1)
    try expectEqual(AudioChoice.pick([a("eng", default: true), a("eng", "Commentary")], choice), 0, "by its name (none)")
    let main = AudioChoice([a("eng", default: true), a("eng", "Commentary")], 0)
    try expectEqual(AudioChoice.pick([a("eng", "English"), a("eng", "Commentary")], main), 0, "its name not found: by its place")
  }

  t.test("audio: tracks without a language are told apart by their place") {
    let ep1 = [a("", default: true), a("und")]
    let choice = AudioChoice(ep1, 1)
    try expectEqual(AudioChoice.pick([a("und", default: true), a("")], choice), 1, "\"\" and und are the same")
    try expectEqual(AudioChoice.pick([a("", default: true), a("eng")], choice), 0, "the one without a language")
    try expectEqual(AudioChoice.pick([a("eng", default: true), a("jpn")], choice), 0, "none without one: the default")
    try expectEqual(AudioChoice.pick([a("eng"), a("", default: true)], AudioChoice(ep1, 0)), 1)
  }

  t.test("each show's choices: one entry a show, the latest last, at most the limit") {
    let x = ShowTracks(show: "x", audio: AudioChoice(lang: "eng"), sub: nil, lastSub: "")
    let y = ShowTracks(show: "y", audio: nil, sub: "English", lastSub: "English")
    var list = ShowTracks.keep(x, in: [])
    list = ShowTracks.keep(y, in: list)
    var x2 = x
    x2.sub = "English · Made on this Mac"
    list = ShowTracks.keep(x2, in: list)
    try expectEqual(list, [y, x2])
    list = ShowTracks.keep(ShowTracks(show: "z", audio: nil, sub: nil, lastSub: ""), in: list, limit: 2)
    try expectEqual(list.map(\.show), ["x", "z"])
    // Kept as JSON in the preferences.
    let data = try JSONEncoder().encode(list)
    try expectEqual(try JSONDecoder().decode([ShowTracks].self, from: data), list)
  }
}
