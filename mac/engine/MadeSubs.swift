import AppKit
import AVFoundation
import Foundation
import Speech

// English subtitles made on this Mac from a video's dialogue. Apple's speech
// recogniser (SpeechTranscriber, on device) hears the words and when each is
// said; each name's spellings are made one, spelt as written where the name is
// expected (ShowNames: the episode's characters from TVmaze, names the user
// taught); the words become cues the way subtitle style guides ask. About 30 s
// for a 45-minute episode. Kept with the downloaded subtitles (OnlineSubs), as
// provider "nightcap".
//
// Measured on three X-Files episodes against their published subtitles: 88-94 %
// of the words found, 98.5-99.8 % of them shown within half a second of when
// the published cue shows them. A local language model correcting the text was
// tried and dropped: about half its changes were wrong. Telling the recogniser
// the names (contextual strings) changed nothing: SpeechTranscriber ignores them.
// With TVmaze's names, the names the dictionary doesn't know were heard right
// 48 -> 90 % (Deep Throat), 73 -> 77 % (The Jersey Devil), 44 -> 44 % (Conduit).

enum MadeSubs {
  /// A word as heard, with its punctuation, from `s` to `e` seconds.
  struct Word: Equatable {
    var t: String
    var s: Double
    var e: Double
  }

  struct Cue: Equatable {
    var start: Double
    var end: Double
    var lines: [String]
  }

  /// How far making has got.
  enum Step: Equatable {
    /// Getting Apple's English speech model (the fraction done).
    case model(Double)
    /// Reading the audio track.
    case audio
    /// Hearing the words (the fraction of the video done).
    case listening(Double)
  }

  struct Failure: Error {
    let message: String
  }

  // ---- Hearing -----------------------------------------------------------------------

  /// The words of audio track `audio` (the n-th audio stream), one list per
  /// stretch of speech the recogniser reports.
  static func hear(_ path: String, audio: Int, progress: @escaping @Sendable (Step) -> Void) async throws -> [[Word]] {
    guard let ffmpeg = Tools.ffmpeg else { throw Failure(message: "ffmpeg is needed to read the audio") }
    guard SpeechTranscriber.isAvailable else { throw Failure(message: "This Mac can’t recognise speech") }
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) else {
      throw Failure(message: "Apple’s speech recognition doesn’t offer English on this Mac")
    }
    let transcriber = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [],
      attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    // The model is often on the Mac already (status "supported": installed, not yet
    // reserved for this app); the request then reserves it and downloads nothing.
    if await AssetInventory.status(forModules: [transcriber]) != .installed,
      let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
    {
      let have = await SpeechTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
      if !have { progress(.model(0)) }
      let watch = request.progress.observe(\.fractionCompleted) { p, _ in
        if !have { progress(.model(p.fractionCompleted)) }
      }
      defer { watch.invalidate() }
      try await request.downloadAndInstall()
    }

    progress(.audio)
    let wav = join(NSTemporaryDirectory(), "nightcap-speech-\(UUID().uuidString).wav")
    defer { removeItem(wav) }
    let r = try await runTool(ffmpeg, [
      "-nostdin", "-loglevel", "error", "-i", path, "-map", "0:a:\(audio)", "-vn", "-sn", "-dn",
      "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-y", wav,
    ], background: true)
    guard r.code == 0, fileExists(wav) else {
      let last = r.lastErrorLine
      throw Failure(message: last.isEmpty ? "Could not read the audio" : last)
    }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: wav))
    let seconds = Double(file.length) / file.processingFormat.sampleRate
    guard seconds > 0 else { throw Failure(message: "The audio track is empty") }

    progress(.listening(0))
    let collector = Task { () throws -> [[Word]] in
      var out: [[Word]] = []
      var shown = 0
      for try await result in transcriber.results {
        var words: [Word] = []
        for run in result.text.runs {
          guard let range = run.audioTimeRange else { continue }
          let t = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
          if !t.isEmpty { words.append(Word(t: t, s: range.start.seconds, e: range.end.seconds)) }
        }
        if !words.isEmpty { out.append(words) }
        let percent = Int(min(1, result.range.end.seconds / seconds) * 100)
        if percent > shown {
          shown = percent
          progress(.listening(Double(percent) / 100))
        }
      }
      return out
    }
    let analyzer: SpeechAnalyzer
    do {
      analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
    } catch {
      collector.cancel()
      throw error
    }
    let heard = try await collector.value
    _ = analyzer
    return heard
  }

  // ---- Names -------------------------------------------------------------------------

  /// The recogniser spells an unfamiliar name a different way nearly every time
  /// it's said (Mulder, Molder, Mueller…). The spellings of one name are grouped
  /// (same first letter, most letters the same, at least one not in the
  /// dictionary), and each group takes its most central spelling: the least
  /// distance from all those heard, counted by times heard. `known` says
  /// whether the dictionary knows a word.
  ///
  /// `names` are names expected in the dialogue (ShowNames: the characters, the
  /// names the user taught). A spelling heard that is nearly one of them
  /// becomes it (`nameFor`), and so does the rest of its group.
  static func settleNames(_ segments: [[Word]], known: (String) -> Bool, names: [String] = []) -> [[Word]] {
    let caps = capitalised(segments, known: known)
    var group = Array(caps.indices)
    func root(_ i: Int) -> Int {
      var i = i
      while group[i] != i { i = group[i] }
      return i
    }
    for i in caps.indices {
      for j in caps.indices where j > i && sameName(caps[i].0, caps[j].0) { group[root(j)] = root(i) }
    }
    var byRoot: [Int: [(String, Int)]] = [:]
    for i in caps.indices { byRoot[root(i), default: []].append(caps[i]) }
    let expected = names.filter { isNameTarget($0) && !known($0) }
    var map: [String: String] = [:]
    for g in byRoot.values {
      // The names its spellings are nearly (a spelling that is a name is that name).
      var to: [String: String] = [:]
      for (s, _) in g {
        if let n = expected.first(where: { $0.lowercased() == s.lowercased() }) ?? nameFor(s, in: expected) { to[s] = n }
      }
      let targets = Set(to.values)
      if targets.count == 1, let n = targets.first {
        for (from, _) in g where from != n && !isTitle(from) { map[from] = n }
      } else if !targets.isEmpty {
        // Two names in one group: each spelling to its own.
        for (from, n) in to where from != n { map[from] = n }
      } else if g.count >= 2 && g.contains(where: { !known($0.0) }) {
        func cost(_ a: String) -> Double { g.reduce(0) { $0 + Double($1.1) * distance(a, $1.0) } }
        let to = g.min { cost($0.0) != cost($1.0) ? cost($0.0) < cost($1.0) : $0.1 > $1.1 }!.0
        for (from, _) in g where from != to { map[from] = to }
      }
    }
    if map.isEmpty { return segments }
    return segments.map { ws in
      ws.map { w in
        let p = parts(w.t)
        guard let to = map[p.core] else { return w }
        return Word(t: p.pre + to + p.post, s: w.s, e: w.e)
      }
    }
  }

  /// Capitalised words (names, mostly): heard mid-sentence, or not in the
  /// dictionary. With how often each is heard anywhere, most first.
  static func capitalised(_ segments: [[Word]], known: (String) -> Bool) -> [(String, Int)] {
    var found = Set<String>()
    for ws in segments {
      for i in ws.indices {
        let c = parts(ws[i].t).core
        guard let f = c.first, f.isUppercase, c != "I", !c.hasPrefix("I'"), !c.hasPrefix("I’"), !isAcronym(c) else { continue }
        let mid = i > 0 && !endsSentence(ws[i - 1].t)
        if mid || !known(c) { found.insert(c) }
      }
    }
    var count: [String: Int] = [:]
    for ws in segments {
      for w in ws {
        let c = parts(w.t).core
        if found.contains(c) { count[c, default: 0] += 1 }
      }
    }
    return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
  }

  /// " Mulder's," → (" ", "Mulder", "'s,")
  static func parts(_ w: String) -> (pre: String, core: String, post: String) {
    let ch = Array(w)
    var a = 0, b = ch.count
    while a < b && !(ch[a].isLetter || ch[a].isNumber) { a += 1 }
    while b > a && !(ch[b - 1].isLetter || ch[b - 1].isNumber) { b -= 1 }
    var core = String(ch[a..<b]), post = String(ch[b...])
    for s in ["'s", "’s"] where core.count > s.count + 1 && core.hasSuffix(s) {
      core.removeLast(s.count)
      post = s + post
    }
    return (String(ch[..<a]), core, post)
  }

  /// How far apart two spellings are, 0 (same letters) to 1. Accents don't count (Brulé, Brule).
  static func distance(_ a: String, _ b: String) -> Double {
    let x = letters(a), y = letters(b)
    return Double(levenshtein(x, y)) / Double(max(1, max(x.count, y.count)))
  }

  /// A word's letters and digits, lower case, without accents.
  static func letters(_ s: String) -> [Character] {
    Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased().filter { $0.isLetter || $0.isNumber })
  }

  static func levenshtein(_ x: [Character], _ y: [Character]) -> Int {
    if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
    var prev = Array(0...y.count), cur = prev
    for i in 1...x.count {
      cur[0] = i
      for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
      swap(&prev, &cur)
    }
    return prev[y.count]
  }

  /// Two spellings of one name: the same first letter and most letters the same.
  static func sameName(_ a: String, _ b: String) -> Bool {
    letters(a).first == letters(b).first && distance(a, b) <= 0.4
  }

  /// The expected name a heard spelling is nearly (`sameName`), the nearest;
  /// nil when two are as near, or for a title.
  static func nameFor(_ s: String, in names: [String]) -> String? {
    guard !isTitle(s) else { return nil }
    var best: (d: Double, n: String)?
    var tie = false
    for n in names where sameName(s, n) {
      let d = distance(s, n)
      if best == nil || d < best!.d {
        best = (d, n)
        tie = false
      } else if d == best!.d && n != best!.n {
        tie = true
      }
    }
    return tie ? nil : best?.n
  }

  /// Words said before a name (Agent Mulder, Mrs. Budahas): never respelt as one.
  static let titles: Set<String> = [
    "mr", "mrs", "ms", "dr", "agent", "colonel", "captain", "detective", "officer", "sir", "miss", "doctor", "lieutenant",
    "sergeant", "general", "major", "lt", "col", "sgt", "capt", "chief", "sheriff", "special", "assistant", "director",
    "section", "deputy", "inspector", "professor", "prof", "judge",
  ]

  static func isTitle(_ w: String) -> Bool { titles.contains(w.lowercased()) }

  /// A name worth respelling others as: 4 letters or more (not a fragment), not a title.
  static func isNameTarget(_ n: String) -> Bool { letters(n).count >= 4 && !isTitle(n) }

  static func isAcronym(_ w: String) -> Bool { w.count <= 5 && w.allSatisfy { $0.isUppercase || $0.isNumber } }

  /// Whether macOS's spell checker knows a word (main thread: AppKit).
  @MainActor
  static func dictionaryKnows(_ w: String) -> Bool {
    NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
      .location == NSNotFound
  }

  // ---- Cues --------------------------------------------------------------------------

  // At most 2 lines of 42 characters and 7 s; shown from the first word to 0.4 s
  // after the last, at least 5/6 s when the next cue allows; 2 frames apart.
  static let maxLine = 42
  static let maxChars = 2 * maxLine
  static let maxDur = 7.0
  static let minDur = 5.0 / 6
  static let linger = 0.4
  static let gap = 2.0 / 24
  static let fillers: Set<String> = ["uh", "um", "uhm", "erm", "er", "hm", "mm"]
  static let conjunctions: Set<String> = [
    "and", "but", "or", "so", "because", "that", "which", "who", "when", "if", "then", "while", "where", "to", "for",
    "with", "from", "of", "in", "on", "at", "about", "like", "until", "since", "than", "though", "although",
  ]
  /// Words that belong with the word after them: never the last on a line.
  static let glue: Set<String> = ["a", "an", "the", "my", "your", "his", "her", "our", "their", "its", "mr.", "mrs.", "ms.", "dr.", "agent"]
  private static let stops: Set<Character> = [".", "?", "!", "…"]

  /// The cues for what was heard: fillers (uh, um) left out; a cue is one
  /// sentence, or a piece of a long one broken at a comma, a pause or before a
  /// conjunction; a quick exchange shares a two-line cue.
  static func cues(_ segments: [[Word]]) -> [Cue] {
    var parts: [([Word], [String]?)] = []
    for seg in segments {
      for sentence in sentences(dropFillers(seg)) where !sentence.isEmpty {
        for part in fits(sentence) ? [sentence] : split(sentence) { parts.append((part, nil)) }
      }
    }
    parts = mergeQuick(parts)
    var out: [Cue] = []
    for (k, (ws, lines)) in parts.enumerated() {
      let s = start(ws)
      let next = k + 1 < parts.count ? start(parts[k + 1].0) : .infinity
      var e = min(ws.last!.e + linger, next - gap)
      e = max(e, min(s + minDur, next - gap))
      e = max(e, ws.last!.e)  // never cut the last word, even if that means touching the next cue
      let t = text(ws)
      out.append(Cue(start: s, end: e, lines: lines ?? twoLines(t) ?? [t]))
    }
    return out
  }

  static func vtt(_ cues: [Cue]) -> String {
    var out = "WEBVTT\n\n"
    for c in cues { out += "\(stamp(c.start)) --> \(stamp(c.end))\n" + c.lines.joined(separator: "\n") + "\n\n" }
    return out
  }

  static func stamp(_ t: Double) -> String {
    let ms = Int((max(0, t) * 1000).rounded())
    return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
  }

  /// Lower case letters, digits, apostrophes and hyphens: what a word is looked up by.
  static func bare(_ w: String) -> String {
    String(w.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "'" || $0 == "-" }).lowercased()
  }

  static func text(_ ws: [Word]) -> String { ws.map(\.t).joined(separator: " ") }

  /// Ends with . ? ! or …, maybe then a closing quote; not a title's full stop ("Mrs. Budahas").
  static func endsSentence(_ t: String) -> Bool {
    var t = Substring(t)
    if t.last == "\"" || t.last == "”" { t = t.dropLast() }
    guard let last = t.last, stops.contains(last) else { return false }
    return !abbreviations.contains(t.lowercased())
  }

  /// Titles written with a full stop, which is not the end of a sentence.
  static let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "lt.", "col.", "sgt.", "capt.", "gen.", "rev."]

  /// "Uh, I think" → "I think"; a filler ending a sentence passes its full stop back.
  static func dropFillers(_ ws: [Word]) -> [Word] {
    var out: [Word] = []
    var capNext = false
    for var w in ws {
      if fillers.contains(bare(w.t)) {
        if w.t.first?.isUppercase == true { capNext = true }
        let end = String(w.t.reversed().prefix { stops.contains($0) }.reversed())
        if !end.isEmpty, let last = out.last, !(last.t.last.map(stops.contains) ?? false) {
          var t = last.t
          if let c = t.last, c == "," || c == ";" || c == ":" { t.removeLast() }
          out[out.count - 1].t = t + end
          capNext = true
        }
        continue
      }
      if capNext, let f = w.t.first {
        w.t = f.uppercased() + w.t.dropFirst()
        capNext = false
      }
      out.append(w)
    }
    return out
  }

  static func sentences(_ ws: [Word]) -> [[Word]] {
    var out: [[Word]] = [], cur: [Word] = []
    for w in ws {
      cur.append(w)
      if endsSentence(w.t) {
        out.append(cur)
        cur = []
      }
    }
    if !cur.isEmpty { out.append(cur) }
    return out
  }

  static func fits(_ ws: [Word]) -> Bool {
    let t = text(ws)
    return t.count <= maxChars && ws.last!.e - ws.first!.s <= maxDur && twoLines(t) != nil
  }

  /// The cost of breaking before ws[i] (lower is better).
  static func breakCost(_ ws: [Word], _ i: Int) -> Int {
    let prev = ws[i - 1], next = ws[i]
    var c = 10
    if let l = prev.t.last, ",;:—-".contains(l) { c -= 6 }
    if next.s - prev.e >= 0.3 { c -= 4 }
    if conjunctions.contains(bare(next.t)) { c -= 3 }
    if glue.contains(bare(prev.t)) { c += 20 }
    return c
  }

  /// A sentence too long for one cue: the cheapest set of breaks giving cues that fit.
  static func split(_ ws: [Word]) -> [[Word]] {
    let n = ws.count
    // best[j]: the least cost of cues covering ws[..<j], and where its last cue starts.
    var best: [(cost: Int, from: Int)?] = Array(repeating: nil, count: n + 1)
    best[0] = (0, 0)
    for j in 1...max(1, n) where n > 0 {
      for i in stride(from: j - 1, through: 0, by: -1) {
        guard let b = best[i] else { continue }
        let part = Array(ws[i..<j])
        if !fits(part) {
          if text(part).count > maxChars { break }
          continue
        }
        let cost = b.cost + (j < n ? breakCost(ws, j) : 0) + 1
        if best[j] == nil || cost < best[j]!.cost { best[j] = (cost, i) }
      }
    }
    if n > 0, best[n] != nil {
      var out: [[Word]] = []
      var j = n
      while j > 0 {
        let i = best[j]!.from
        out.insert(Array(ws[i..<j]), at: 0)
        j = i
      }
      return out
    }
    // Words that can't fit at all (a run-on with no time gaps): hard cuts by size.
    var out: [[Word]] = [], cur: [Word] = []
    for w in ws {
      if !cur.isEmpty && !fits(cur + [w]) {
        out.append(cur)
        cur = []
      }
      cur.append(w)
    }
    if !cur.isEmpty { out.append(cur) }
    return out
  }

  /// The text on one line, or two (the best place to break), or nil when it can't fit.
  static func twoLines(_ t: String) -> [String]? {
    if t.count <= maxLine { return [t] }
    let words = t.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    var best: (cost: Int, lines: [String])?
    for k in 1..<max(1, words.count) {
      let a = words[..<k].joined(separator: " "), b = words[k...].joined(separator: " ")
      if a.count > maxLine || b.count > maxLine { continue }
      var cost = abs(a.count - b.count)
      if let l = words[k - 1].last, ",.;:?!".contains(l) { cost -= 12 }
      if conjunctions.contains(words[k].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",."))) { cost -= 6 }
      if glue.contains(words[k - 1].lowercased()) { cost += 30 }
      if a.count > b.count { cost += 2 }  // bottom-heavy reads better
      if best == nil || cost < best!.cost { best = (cost, [a, b]) }
    }
    return best?.lines
  }

  /// When a word is said. The recogniser's word ranges are contiguous, so a
  /// cue's first word also holds the silence before it: its start is estimated
  /// from its length.
  static func onset(_ w: Word) -> Double {
    max(w.s, w.e - (0.12 + 0.07 * Double(bare(w.t).count)))
  }

  static func start(_ ws: [Word]) -> Double { onset(ws[0]) }

  /// A quick exchange (a cue with less than 5/6 s before the next one starts)
  /// shares one cue with its neighbour, a line each, when both fit on one line
  /// and are said within 7 s. No speaker dashes: the recogniser doesn't tell
  /// speakers apart.
  static func mergeQuick(_ cues: [([Word], [String]?)]) -> [([Word], [String]?)] {
    func room(_ i: Int) -> Double {
      (i + 1 < cues.count ? start(cues[i + 1].0) : .infinity) - start(cues[i].0) - gap
    }
    var out: [([Word], [String]?)] = []
    var k = 0
    while k < cues.count {
      let a = cues[k].0
      if k + 1 < cues.count, cues[k].1 == nil, cues[k + 1].1 == nil {
        let b = cues[k + 1].0
        let ta = text(a), tb = text(b)
        if (room(k) < minDur || room(k + 1) < minDur) && ta.count <= maxLine && tb.count <= maxLine
          && b.last!.e - start(a) <= maxDur && b[0].s - a.last!.e < 1.0
        {
          out.append((a + b, [ta, tb]))
          k += 2
          continue
        }
      }
      out.append(cues[k])
      k += 1
    }
    return out
  }
}

/// Makes subtitles one video at a time (speech recognition is heavy), and each
/// audio track once even when asked twice.
@MainActor
final class SubtitleMaker {
  private let limit = Limiter(1)
  private var inflight: [String: Task<SubtitleTrack, Error>] = [:]

  /// Makes WebVTT for audio track `audio` of `f` and hands it to `keep` with the
  /// names it expected, once; `names` gives the names expected in the dialogue
  /// (asked for once the dialogue is heard), `progress` hears how far it has got
  /// (a second caller of a track already being made only gets the result).
  func make(
    _ f: LibraryFile, audio: Int, names: @escaping @MainActor () async -> ShowNames.Found,
    progress: @escaping @MainActor (MadeSubs.Step) -> Void,
    keep: @escaping @MainActor (String, ShowNames.Found) throws -> SubtitleTrack
  ) async throws -> SubtitleTrack {
    let key = "\(f.id)|\(audio)"
    if let running = inflight[key] { return try await running.value }
    let path = f.path
    let task = Task { () throws -> SubtitleTrack in
      defer { inflight[key] = nil }
      let (vtt, found) = try await limit.run {
        let t0 = Date()
        // The main queue keeps the steps in order (separate tasks might not).
        let heard = try await MadeSubs.hear(path, audio: audio) { step in
          DispatchQueue.main.async { MainActor.assumeIsolated { progress(step) } }
        }
        let found = await names()
        let named = MadeSubs.settleNames(heard, known: MadeSubs.dictionaryKnows, names: found.names)
        let cues = MadeSubs.cues(named)
        guard !cues.isEmpty else { throw MadeSubs.Failure(message: "No speech was heard in this audio track") }
        logLine("[subs] made \(f.name) (audio \(audio)): \(heard.reduce(0) { $0 + $1.count }) words, \(cues.count) cues in "
          + "\(toFixed(Date().timeIntervalSince(t0), 1)) s; \(found.names.count) names expected\(found.fromTVmaze ? " (TVmaze)" : "")")
        return (MadeSubs.vtt(cues), found)
      }
      return try keep(vtt, found)
    }
    inflight[key] = task
    return try await task.value
  }
}
