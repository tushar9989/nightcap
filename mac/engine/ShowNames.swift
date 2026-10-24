import Foundation

// Names to expect in a video's dialogue, for subtitles made on this Mac
// (MadeSubs): the characters of the show and of the episode, and the names in
// the episode's summary, from TVmaze; and the names the user taught by fixing a
// made line. The recogniser spells a name it doesn't know a new way nearly every
// time it's said (Budahas: Boudhaas, Buddhaas, Boudhus…); a heard word that is
// nearly a known name becomes it.
//
// TVmaze (tvmaze.com) is a free TV database: no key, at least 20 requests per
// 10 s, its data licensed CC BY-SA (credited in the made track's description).
// It has no films.
//
// On disk (DATA_DIR):
//   names.json   TVmaze's answers (kept 30 days) and the names learned from fixes

struct NamesData: Codable {
  struct Show: Codable, Equatable {
    /// nil: TVmaze has no show of that name.
    var id: Int?
    var at: Int64
  }

  struct People: Codable, Equatable {
    /// The characters' names, as TVmaze writes them ("Lt. Col. Robert Budahas").
    var characters: [String]
    /// An episode's summary (HTML); nil for a show's cast.
    var summary: String?
    var at: Int64
  }

  /// "<name>|<year>" (OpenSubtitles.norm'd name) -> the show TVmaze has by that name.
  var shows: [String: Show] = [:]
  /// "<show id>": the show's cast; "<show id>/<season>x<episode>": an episode's guests and summary.
  var people: [String: People] = [:]
  /// Title id -> the names the user taught by fixing made subtitles, oldest first.
  var learned: [String: [String]] = [:]

  init() {}
  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    shows = c.lenientDict(.shows)
    people = c.lenientDict(.people)
    learned = c.lenientDict(.learned)
  }
}

@MainActor
final class ShowNames {
  nonisolated static let defaultBase = "https://api.tvmaze.com"
  nonisolated static let keepMs: Int64 = 30 * 86_400_000
  /// A show TVmaze doesn't have is asked about again after a day.
  nonisolated static let missMs: Int64 = 86_400_000

  let store: JsonStore<NamesData>
  let base: String

  init(
    store: JsonStore<NamesData> = JsonStore(Paths.data("names.json"), defaults: NamesData()),
    base: String = ProcessInfo.processInfo.environment["TVMAZE_API"].flatMap { $0.isEmpty ? nil : $0 } ?? ShowNames.defaultBase
  ) {
    self.store = store
    self.base = base
  }

  func flush() { store.flush() }

  // ---- Names for a video -----------------------------------------------------------

  /// What a made track's names came from, to credit TVmaze.
  struct Found: Equatable {
    var names: [String] = []
    /// TVmaze knew the episode.
    var fromTVmaze = false
  }

  /// The names to expect in `file`: those learned for its title, then for an
  /// episode, those TVmaze knows (none from TVmaze when it can't be reached).
  /// `known` says whether the dictionary knows a word.
  func names(for file: LibraryFile, title: Title?, episode: (season: Int, episode: Int)?, known: (String) -> Bool) async -> Found {
    var found = Found(names: title.map { learned($0.id) } ?? [])
    guard let title, title.isShow, let episode else { return found }
    do {
      if let people = try await people(title, season: episode.season, episode: episode.episode) {
        for n in ShowNames.words(characters: people.characters, summary: people.summary, known: known)
        where !found.names.contains(where: { $0.lowercased() == n.lowercased() }) {
          found.names.append(n)
        }
        found.fromTVmaze = true
      }
    } catch {
      logLine("[names] TVmaze: \(error.localizedDescription) (\(title.name) \(episode.season)x\(episode.episode))")
    }
    return found
  }

  /// The words of characters' names, and the capitalised words of a summary,
  /// that the recogniser could misspell: 4 letters or more, not a title (Agent,
  /// Colonel…), not in the dictionary. In the order found, each once.
  nonisolated static func words(characters: [String], summary: String?, known: (String) -> Bool) -> [String] {
    var out: [String] = []
    func add(_ w: String) {
      guard let f = w.first, f.isUppercase, MadeSubs.isNameTarget(w), !known(w), !out.contains(where: { $0.lowercased() == w.lowercased() })
      else { return }
      out.append(w)
    }
    for c in characters { for w in tokens(c) { add(w) } }
    for w in tokens(plainText(summary ?? "")) { add(w) }
    return out
  }

  /// "Lt. Col. Robert Budahas's" -> ["Lt", "Col", "Robert", "Budahas"]: letters and inner apostrophes, at
  /// spaces, hyphens and slashes; a closing 's dropped.
  nonisolated static func tokens(_ text: String) -> [String] {
    text.replacingOccurrences(of: "’", with: "'")
      .split { $0.isWhitespace || $0 == "-" || $0 == "–" || $0 == "—" || $0 == "/" }
      .compactMap { raw in
        var w = Substring(raw)
        while let c = w.first, !(c.isLetter || c.isNumber) { w = w.dropFirst() }
        while let c = w.last, !(c.isLetter || c.isNumber) { w = w.dropLast() }
        if w.count > 3, w.hasSuffix("'s") { w = w.dropLast(2) }
        return w.isEmpty || w.contains(where: { !($0.isLetter || $0.isNumber || $0 == "'") }) ? nil : String(w)
      }
  }

  /// HTML as text: tags out, the few entities TVmaze uses decoded.
  nonisolated static func plainText(_ html: String) -> String {
    var t = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    for (e, c) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
      t = t.replacingOccurrences(of: e, with: c)
    }
    return t
  }

  // ---- Learned names ---------------------------------------------------------------

  func learned(_ titleId: String) -> [String] { store.data.learned[titleId] ?? [] }

  /// Adds names the user taught for a title (each once, ignoring case); the ones added.
  @discardableResult
  func learn(_ names: [String], for titleId: String) -> [String] {
    var list = learned(titleId)
    var added: [String] = []
    for n in names where !list.contains(where: { $0.lowercased() == n.lowercased() }) {
      list.append(n)
      added.append(n)
    }
    if !added.isEmpty {
      store.data.learned[titleId] = list
      store.save()
    }
    return added
  }

  func forget(_ names: [String], for titleId: String) {
    let drop = Set(names.map { $0.lowercased() })
    let list = learned(titleId).filter { !drop.contains($0.lowercased()) }
    store.data.learned[titleId] = list.isEmpty ? nil : list
    store.save()
  }

  // ---- TVmaze ----------------------------------------------------------------------

  struct Failure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private struct ShowHit: Decodable {
    struct Show: Decodable {
      var id: Int
      var name: String
      var premiered: String?
    }
    var show: Show
  }

  private struct Role: Decodable {
    struct Character: Decodable { var name: String? }
    /// A role may have no character (nothing to learn from it then).
    var character: Character?
  }

  private struct EpisodeInfo: Decodable {
    var id: Int
    var summary: String?
  }

  nonisolated private static let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 10
    c.timeoutIntervalForResource = 15
    c.urlCache = nil
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    return URLSession(configuration: c)
  }()

  /// One GET: the decoded answer, nil when TVmaze has no such thing (404).
  private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T? {
    guard var parts = URLComponents(string: base + path) else { throw Failure(message: "bad address") }
    if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
    guard let url = parts.url else { throw Failure(message: "bad address") }
    var req = URLRequest(url: url)
    req.setValue(OpenSubtitles.userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await ShowNames.session.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 404 { return nil }
    guard (200...299).contains(status) else { throw Failure(message: "TVmaze answered \(status)") }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw Failure(message: "TVmaze sent an unexpected answer")
    }
  }

  private func fresh(_ at: Int64, _ ms: Int64) -> Bool { nowMs() - at < ms }

  /// The TVmaze show for a title: the same name (OpenSubtitles.norm), and the
  /// same first year when the title has one.
  func showId(_ title: Title) async throws -> Int? {
    let year = title.year.flatMap { $0 == 0 ? nil : $0 }
    let key = "\(OpenSubtitles.norm(title.name))|\(year.map(String.init) ?? "")"
    if let hit = store.data.shows[key], fresh(hit.at, hit.id == nil ? ShowNames.missMs : ShowNames.keepMs) { return hit.id }
    let hits: [ShowHit] = try await get("/search/shows", ["q": title.name]) ?? []
    let want = OpenSubtitles.norm(title.name)
    let same = hits.filter { OpenSubtitles.norm($0.show.name) == want }
    let byYear = year.map { y in same.filter { $0.show.premiered?.hasPrefix(String(y)) == true } } ?? []
    let id = (byYear.isEmpty ? same : byYear).first?.show.id
    store.data.shows[key] = NamesData.Show(id: id, at: nowMs())
    store.save()
    return id
  }

  /// The characters of a show and of one of its episodes, with the episode's
  /// summary (nil: TVmaze doesn't have the show or the episode).
  func people(_ title: Title, season: Int, episode: Int) async throws -> NamesData.People? {
    guard let show = try await showId(title) else { return nil }
    let castKey = "\(show)", epKey = "\(show)/\(season)x\(episode)"
    var cast = store.data.people[castKey].flatMap { fresh($0.at, ShowNames.keepMs) ? $0 : nil }
    if cast == nil {
      let roles: [Role] = try await get("/shows/\(show)/cast") ?? []
      cast = NamesData.People(characters: roles.compactMap { $0.character?.name }, summary: nil, at: nowMs())
      store.data.people[castKey] = cast
      store.save()
    }
    var guests = store.data.people[epKey].flatMap { fresh($0.at, ShowNames.keepMs) ? $0 : nil }
    if guests == nil {
      guard let ep: EpisodeInfo = try await get("/shows/\(show)/episodebynumber", ["season": "\(season)", "number": "\(episode)"]) else {
        return nil
      }
      let roles: [Role] = try await get("/episodes/\(ep.id)/guestcast") ?? []
      guests = NamesData.People(characters: roles.compactMap { $0.character?.name }, summary: ep.summary ?? "", at: nowMs())
      store.data.people[epKey] = guests
      store.save()
    }
    return NamesData.People(characters: cast!.characters + guests!.characters, summary: guests!.summary, at: guests!.at)
  }
}
