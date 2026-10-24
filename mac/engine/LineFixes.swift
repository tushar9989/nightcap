import Foundation

// Fixes the user makes to subtitles made on this Mac (MadeSubs): the line is
// changed in its track and kept in a log; a name it corrects is learned for the
// title (ShowNames), so subtitles made later spell it right, and the same
// misheard spelling elsewhere in the track is fixed with it.
//
// On disk (DATA_DIR):
//   subs-corrections.json   every fix: the video, the track, the cue, the line before and after, when

struct LineFix: Codable, Equatable {
  /// The video (file id), its name then, and the track (the n of d<n>).
  var file: String
  var video: String
  var track: Int
  var start: Double
  var end: Double
  var before: String
  /// Empty: the line was taken out.
  var after: String
  /// Names it taught for the title.
  var learned: [String]
  /// Other lines of the track respelt with it.
  var elsewhere: Int
  var at: Int64
}

struct LineFixLog: Codable {
  var fixes: [LineFix] = []

  init() {}
  init(from d: Decoder) throws {
    fixes = try d.container(keyedBy: CodingKeys.self).lenientArray(.fixes)
  }
}

enum LineFixes {
  /// The lines of a cue as typed: each trimmed, spaces made one, empty lines
  /// out; one line too long for the screen broken in two as made cues are.
  static func lines(_ text: String) -> [String] {
    let lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n").map {
      $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }.filter { !$0.isEmpty }
    if lines.count == 1, lines[0].count > MadeSubs.maxLine, let two = MadeSubs.twoLines(lines[0]) { return two }
    return lines
  }

  /// Text compared with its spaces and line breaks made one space.
  private static func flat(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

  private static func at(_ b: Subtext.Block, _ start: Double, _ end: Double) -> Bool {
    abs(b.start - start) < 0.0005 && abs(b.end - end) < 0.0005
  }

  /// A cue block written back: its head, its timing line as it was, the lines.
  private static func block(_ b: Subtext.Block, _ lines: [String]) -> String {
    let timing = b.raw.split(separator: "\n", omittingEmptySubsequences: false).first { $0.contains("-->") }.map(String.init) ?? ""
    return (b.head + [timing] + lines).joined(separator: "\n")
  }

  private static func joined(_ blocks: [String]) -> String {
    blocks.joined(separator: "\n\n").trimmingCharacters(in: .newlines) + "\n\n"
  }

  /// `vtt` with the cue from `start` to `end` that reads `before` reading
  /// `lines` instead (taken out when empty); nil when there is no such cue.
  static func replace(_ vtt: String, start: Double, end: Double, before: String, with lines: [String]) -> String? {
    let blocks = Subtext.blocks(vtt)
    guard let i = blocks.firstIndex(where: { b in b.text.map { at(b, start, end) && flat($0) == flat(before) } ?? false }) else {
      return nil
    }
    var out = blocks.map(\.raw)
    if lines.isEmpty { out.remove(at: i) } else { out[i] = block(blocks[i], lines) }
    return joined(out)
  }

  /// A word as heard and as fixed.
  struct Respelling: Equatable {
    /// The word it replaced (nil: it replaced several words, or none).
    var heard: String?
    var name: String
  }

  /// The names a fix teaches: the words it changed that became a name the
  /// dictionary doesn't know (capitalised, 4 letters or more, not a title),
  /// with the word each replaced when that is clear (one for one, in order).
  static func taught(before: String, after: String, known: (String) -> Bool) -> [Respelling] {
    let a = words(before), b = words(after)
    // The longest run of words both have, in order; the rest changed.
    let n = a.count, m = b.count
    var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
      for j in stride(from: m - 1, through: 0, by: -1) {
        lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
      }
    }
    var out: [Respelling] = []
    var gapA: [String] = [], gapB: [String] = []
    func close() {
      for (k, w) in gapB.enumerated() where isName(w, known: known) && !out.contains(where: { $0.name == w }) {
        let heard = gapA.count == gapB.count && gapA[k] != w ? gapA[k] : nil
        out.append(Respelling(heard: heard, name: w))
      }
      gapA = []
      gapB = []
    }
    var i = 0, j = 0
    while i < n || j < m {
      if i < n, j < m, a[i] == b[j] {
        close()
        i += 1
        j += 1
      } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
        gapB.append(b[j])
        j += 1
      } else {
        gapA.append(a[i])
        i += 1
      }
    }
    close()
    return out
  }

  /// The words of a line, without the punctuation around them.
  static func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map { MadeSubs.parts(String($0)).core }.filter { !$0.isEmpty }
  }

  static func isName(_ w: String, known: (String) -> Bool) -> Bool {
    guard let f = w.first, f.isUppercase, !MadeSubs.isAcronym(w) else { return false }
    return MadeSubs.isNameTarget(w) && !known(w)
  }

  /// `vtt` with the word `heard` (exactly, punctuation aside) spelt as `name`
  /// in every other cue, and how many cues changed. A word the dictionary knows
  /// is respelt only in the middle of a sentence ("Will you…" stays when Will
  /// was fixed to Weil).
  static func respell(
    _ vtt: String, heard: String, as name: String, except: (start: Double, end: Double), known: (String) -> Bool
  ) -> (vtt: String, cues: Int) {
    let anywhere = !known(heard)
    var changed = 0
    let out = Subtext.blocks(vtt).map { b -> String in
      guard let text = b.text, !at(b, except.start, except.end) else { return b.raw }
      var hit = false
      var sentenceStart = true
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        line.split(separator: " ", omittingEmptySubsequences: false).map { raw -> String in
          let w = String(raw)
          defer { if !w.isEmpty { sentenceStart = MadeSubs.endsSentence(w) } }
          let p = MadeSubs.parts(w)
          guard p.core == heard, anywhere || !sentenceStart else { return w }
          hit = true
          return p.pre + name + p.post
        }.joined(separator: " ")
      }
      guard hit else { return b.raw }
      changed += 1
      return block(b, lines)
    }
    return (joined(out), changed)
  }
}
