import Foundation

// The audio and subtitles a show plays with, kept for each show: chosen in one
// episode, taken up by the others. A show takes up the choices last made
// anywhere when it is first played, and from then on keeps its own, so choices
// made in another show or a film don't reach it. Films and videos opened on
// their own follow the choices last made anywhere, as before.

/// An audio track chosen: its language, its name, and its place among the file's tracks.
struct AudioChoice: Codable, Equatable {
  /// The language as the file labels it ("jpn"); "" or "und" for none.
  var lang: String
  /// The track's name ("Commentary"); nil when only the language counts.
  var title: String?
  /// Its place among the file's audio tracks; nil when only the language counts.
  var position: Int?

  /// What the track `i` of `tracks` is, to find its like in other episodes.
  init(_ tracks: [ProbeInfo.Audio], _ i: Int) {
    lang = tracks[i].lang
    title = tracks[i].title
    position = i
  }

  /// Only a language (the choice last made anywhere).
  init(lang: String) {
    self.lang = lang
  }

  /// The track of `tracks` that plays: the one chosen, or its like. In the
  /// chosen language, the one with the same name, then the one in the same
  /// place, then the first; the file's default when none is in that language.
  static func pick(_ tracks: [ProbeInfo.Audio], _ choice: AudioChoice?) -> Int {
    if tracks.count <= 1 { return 0 }
    let fallback = max(0, tracks.firstIndex(where: \.default) ?? -1)
    guard let choice else { return fallback }
    let lang = norm(choice.lang)
    // Only a language, and none: nothing was chosen.
    if lang.isEmpty && choice.position == nil { return fallback }
    let same = tracks.indices.filter { norm(tracks[$0].lang) == lang }
    if same.isEmpty { return fallback }
    let named = choice.title.map { t in same.filter { tracks[$0].title == t } } ?? []
    let list = named.isEmpty ? same : named
    if let p = choice.position, list.contains(p) { return p }
    return list[0]
  }

  private static func norm(_ lang: String) -> String {
    let l = lang.jsLowercased
    return l == "und" ? "" : l
  }
}

/// What one show plays with.
struct ShowTracks: Codable, Equatable {
  /// The show (Title.id).
  var show: String
  /// The audio track; nil for each file's default.
  var audio: AudioChoice?
  /// The subtitles shown (their label); nil for none.
  var sub: String?
  /// The subtitles last shown, for C to turn back on.
  var lastSub: String

  /// The shows kept, the latest last; `t` replaces its show's entry and goes
  /// last, and the oldest go beyond `limit`.
  static func keep(_ t: ShowTracks, in list: [ShowTracks], limit: Int = 500) -> [ShowTracks] {
    var out = list.filter { $0.show != t.show }
    out.append(t)
    if out.count > limit { out.removeFirst(out.count - limit) }
    return out
  }
}
