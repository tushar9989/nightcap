import Foundation

// The engine was first written in JavaScript, and its file formats, ids and
// name parsing must stay exactly as they were. These helpers give Swift the
// same string semantics: UTF-16 offsets, JavaScript's regular expression
// calls, trim(), startsWith() and friends.

/// A regular expression that behaves exactly like the JavaScript literal it
/// was written as. Patterns use JavaScript syntax (without the u flag); flags:
/// "i" ignore case, "m" ^ and $ match at line breaks, "s" . matches line breaks.
/// They are translated for ICU (NSRegularExpression), whose \s, \w, \b, ., $
/// and case-insensitive matching all differ from JavaScript's.
final class Re: @unchecked Sendable {
  let source: String
  let regex: NSRegularExpression

  init(_ pattern: String, _ flags: String = "") {
    source = pattern
    var translator = JSRegexTranslator(
      Array(pattern.utf16), ignoreCase: flags.contains("i"), multiline: flags.contains("m"), dotAll: flags.contains("s"))
    let icu = translator.translate()
    do {
      regex = try NSRegularExpression(pattern: icu, options: [])
    } catch {
      fatalError("bad pattern \(pattern) -> \(icu): \(error)")
    }
  }

  struct Match {
    let source: NSString
    let result: NSTextCheckingResult
    /// UTF-16 offset of the match, like match.index.
    var index: Int { result.range.location }
    var length: Int { result.range.length }
    var end: Int { result.range.location + result.range.length }
    var groupCount: Int { result.numberOfRanges - 1 }
    /// m[0], m[1] … (nil for a group that did not take part).
    subscript(_ i: Int) -> String? {
      guard i < result.numberOfRanges else { return nil }
      let r = result.range(at: i)
      return r.location == NSNotFound ? nil : source.substring(with: r)
    }
  }

  /// JavaScript matches code units; ICU matches code points. Surrogates are
  /// swapped for stand-ins (same length; nothing in the patterns matches them
  /// specially) so that both see one unit at a time. Results always come
  /// from the original text.
  private func target(_ s: String) -> (original: NSString, matchOn: String) {
    let ns = s as NSString
    var hasSurrogate = false
    for u in s.utf16 where u & 0xF800 == 0xD800 {
      hasSurrogate = true
      break
    }
    guard hasSurrogate else { return (ns, s) }
    let units = s.utf16.map { u -> UInt16 in u & 0xF800 == 0xD800 ? (u < 0xDC00 ? 0xE000 : 0xE001) : u }
    return (ns, String(decoding: units, as: UTF16.self))
  }

  private func all(_ s: String) -> (NSString, [NSTextCheckingResult]) {
    let (ns, on) = target(s)
    return (ns, regex.matches(in: on, range: NSRange(location: 0, length: ns.length)))
  }

  func test(_ s: String) -> Bool { match(s) != nil }

  /// str.match(re) without the g flag.
  func match(_ s: String) -> Match? {
    let (ns, on) = target(s)
    guard let r = regex.firstMatch(in: on, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return Match(source: ns, result: r)
  }

  /// str.matchAll(re).
  func matches(_ s: String) -> [Match] {
    let (ns, results) = all(s)
    return results.map { Match(source: ns, result: $0) }
  }

  /// str.search(re): the UTF-16 offset of the first match, or -1.
  func search(_ s: String) -> Int { match(s)?.index ?? -1 }

  /// str.replace(re, template); `global` is the g flag. Templates are
  /// JavaScript's: $1, $&, $$, $` and $'.
  func replace(_ s: String, _ template: String, global: Bool = true) -> String {
    let t = Array(template.utf16)
    return replace(s, global: global) { m in Re.substitute(t, m) }
  }

  /// str.replace(re, fn).
  func replace(_ s: String, global: Bool = true, _ fn: (Match) -> String) -> String {
    let (ns, results) = all(s)
    var out = ""
    var last = 0
    for r in global ? results : Array(results.prefix(1)) {
      out += ns.substring(with: NSRange(location: last, length: r.range.location - last))
      out += fn(Match(source: ns, result: r))
      last = r.range.location + r.range.length
    }
    out += ns.substring(from: last)
    return out
  }

  /// GetSubstitution: what a replacement template expands to for one match.
  private static func substitute(_ t: [UInt16], _ m: Match) -> String {
    let dollar: UInt16 = 0x24
    guard t.contains(dollar) else { return String(decoding: t, as: UTF16.self) }
    func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
    var out: [UInt16] = []
    var i = 0
    while i < t.count {
      let c = t[i]
      guard c == dollar, i + 1 < t.count else {
        out.append(c)
        i += 1
        continue
      }
      let n = t[i + 1]
      switch n {
      case dollar:
        out.append(dollar)
        i += 2
      case 0x26:  // $&
        out += Array((m[0] ?? "").utf16)
        i += 2
      case 0x60:  // $`
        out += Array(m.source.substring(to: m.index).utf16)
        i += 2
      case 0x27:  // $'
        out += Array(m.source.substring(from: m.end).utf16)
        i += 2
      case _ where isDigit(n):
        // Two digits when that names a group, else one; $0 and unknown groups stay as written.
        let one = Int(n - 0x30)
        if i + 2 < t.count, isDigit(t[i + 2]) {
          let two = one * 10 + Int(t[i + 2] - 0x30)
          if two >= 1 && two <= m.groupCount {
            out += Array((m[two] ?? "").utf16)
            i += 3
            continue
          }
        }
        if one >= 1 && one <= m.groupCount {
          out += Array((m[one] ?? "").utf16)
          i += 2
        } else {
          out.append(c)
          i += 1
        }
      default:
        out.append(c)
        i += 1
      }
    }
    return String(decoding: out, as: UTF16.self)
  }

  /// str.split(re), for patterns that cannot match an empty string and have
  /// no groups (what the engine uses).
  func split(_ s: String) -> [String] {
    let (ns, results) = all(s)
    if ns.length == 0 { return results.isEmpty ? [""] : [] }
    var out: [String] = []
    var last = 0
    for r in results where r.range.length > 0 {
      // A match at the very end is not a separator (JavaScript stops before it).
      if r.range.location >= ns.length { break }
      out.append(ns.substring(with: NSRange(location: last, length: r.range.location - last)))
      last = r.range.location + r.range.length
    }
    out.append(ns.substring(from: last))
    return out
  }
}

/// Rewrites a JavaScript (non-unicode) regular expression as an ICU one with
/// the same meaning: JavaScript's \s, \w, \b, \d, ., ^ and $, and its case
/// folding (Canonicalize: toUpperCase, never mapping non-ASCII to ASCII), so
/// "ſ", "K" (Kelvin) or "ß" never match "s", "k" or "ss" the way ICU's would.
/// Everything is matched case-sensitively; case-insensitive letters become sets.
struct JSRegexTranslator {
  let src: [UInt16]
  let ignoreCase: Bool
  let multiline: Bool
  let dotAll: Bool
  private var i = 0
  private var out = ""

  init(_ src: [UInt16], ignoreCase: Bool, multiline: Bool, dotAll: Bool) {
    self.src = src
    self.ignoreCase = ignoreCase
    self.multiline = multiline
    self.dotAll = dotAll
  }

  /// JavaScript's WhiteSpace and LineTerminator characters (\s).
  static let space: [ClosedRange<UInt16>] = [
    0x09...0x0D, 0x20...0x20, 0xA0...0xA0, 0x1680...0x1680, 0x2000...0x200A, 0x2028...0x2029, 0x202F...0x202F,
    0x205F...0x205F, 0x3000...0x3000, 0xFEFF...0xFEFF,
  ]
  static let word: [ClosedRange<UInt16>] = [0x30...0x39, 0x41...0x5A, 0x5F...0x5F, 0x61...0x7A]
  static let digit: [ClosedRange<UInt16>] = [0x30...0x39]
  static let lineTerminator: [ClosedRange<UInt16>] = [0x0A...0x0A, 0x0D...0x0D, 0x2028...0x2029]

  static func hex(_ u: UInt16) -> String { "\\x{\(String(u, radix: 16))}" }
  static func set(_ ranges: [ClosedRange<UInt16>], negated: Bool = false) -> String {
    "[" + (negated ? "^" : "") + members(ranges) + "]"
  }
  static func members(_ ranges: [ClosedRange<UInt16>]) -> String {
    ranges.map { $0.lowerBound == $0.upperBound ? hex($0.lowerBound) : "\(hex($0.lowerBound))-\(hex($0.upperBound))" }.joined()
  }
  static let wordSet = set(word)
  static let boundary = "(?:(?<=\(wordSet))(?!\(wordSet))|(?<!\(wordSet))(?=\(wordSet)))"
  static let nonBoundary = "(?:(?<=\(wordSet))(?=\(wordSet))|(?<!\(wordSet))(?!\(wordSet)))"

  private func peek(_ k: Int = 0) -> UInt16? { i + k < src.count ? src[i + k] : nil }
  private static func isHex(_ u: UInt16?) -> Bool {
    guard let u else { return false }
    return (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66)
  }
  private static func isDigit(_ u: UInt16?) -> Bool { u.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }
  private static func isLetter(_ u: UInt16) -> Bool { (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) }

  /// Reads `n` hex digits at i (already checked).
  private mutating func readHex(_ n: Int) -> UInt16 {
    let s = String(decoding: src[i..<(i + n)], as: UTF16.self)
    i += n
    return UInt16(s, radix: 16)!
  }

  mutating func translate() -> String {
    while i < src.count {
      let c = src[i]
      i += 1
      switch c {
      case 0x5C: escapeOutside()  // \
      case 0x2E:  // .
        out += dotAll ? "[\\x{0}-\\x{10ffff}]" : JSRegexTranslator.set(JSRegexTranslator.lineTerminator, negated: true)
      case 0x5E:  // ^
        out += multiline ? "(?:\\A|(?<=\(JSRegexTranslator.set(JSRegexTranslator.lineTerminator))))" : "\\A"
      case 0x24:  // $
        out += multiline ? "(?:\\z|(?=\(JSRegexTranslator.set(JSRegexTranslator.lineTerminator))))" : "\\z"
      case 0x5B: charClass()  // [
      case 0x28:  // (
        out += "("
        if peek() == 0x3F {  // (?
          out += "?"
          i += 1
          if peek() == 0x3C, let n = peek(1), n != 0x3D && n != 0x21 {
            // (?<name>: copy the name as written.
            while let u = peek(), u != 0x3E {
              out += String(decoding: [u], as: UTF16.self)
              i += 1
            }
          }
        }
      case 0x7B:  // {
        if let q = quantifier() { out += q } else { out += JSRegexTranslator.hex(c) }
      case 0x29, 0x7C, 0x2A, 0x2B, 0x3F, 0x3C, 0x3E, 0x3D, 0x21, 0x3A:  // ) | * + ? < > = ! :
        out += String(decoding: [c], as: UTF16.self)
      default:
        literal(c)
      }
    }
    return out
  }

  /// {n}, {n,} or {n,m} at i (after the brace); nil when the brace is a literal.
  private mutating func quantifier() -> String? {
    var j = i
    var text = "{"
    var digits = 0
    while j < src.count, JSRegexTranslator.isDigit(src[j]) { text += String(UnicodeScalar(UInt8(src[j]))); j += 1; digits += 1 }
    guard digits > 0, j < src.count else { return nil }
    if src[j] == 0x2C {  // ,
      text += ","
      j += 1
      while j < src.count, JSRegexTranslator.isDigit(src[j]) { text += String(UnicodeScalar(UInt8(src[j]))); j += 1 }
    }
    guard j < src.count, src[j] == 0x7D else { return nil }
    i = j + 1
    return text + "}"
  }

  private mutating func literal(_ c: UInt16) {
    if ignoreCase {
      let eq = JSCase.equivalents(c)
      if eq.count > 1 {
        out += "[" + eq.map(JSRegexTranslator.hex).joined() + "]"
        return
      }
    }
    if JSRegexTranslator.isLetter(c) || JSRegexTranslator.isDigit(c) {
      out += String(UnicodeScalar(UInt8(c)))
    } else {
      out += JSRegexTranslator.hex(c)
    }
  }

  private mutating func escapeOutside() {
    guard let e = peek() else {
      out += "\\\\"  // a trailing backslash: JavaScript rejects it; keep ICU's error
      return
    }
    i += 1
    switch e {
    case 0x64: out += JSRegexTranslator.set(JSRegexTranslator.digit)  // d
    case 0x44: out += JSRegexTranslator.set(JSRegexTranslator.digit, negated: true)  // D
    case 0x77: out += JSRegexTranslator.set(JSRegexTranslator.word)  // w
    case 0x57: out += JSRegexTranslator.set(JSRegexTranslator.word, negated: true)  // W
    case 0x73: out += JSRegexTranslator.set(JSRegexTranslator.space)  // s
    case 0x53: out += JSRegexTranslator.set(JSRegexTranslator.space, negated: true)  // S
    case 0x62: out += JSRegexTranslator.boundary  // b
    case 0x42: out += JSRegexTranslator.nonBoundary  // B
    case 0x31...0x39:  // \1 … backreferences
      out += "\\" + String(UnicodeScalar(UInt8(e)))
      while let d = peek(), JSRegexTranslator.isDigit(d) {
        out += String(UnicodeScalar(UInt8(d)))
        i += 1
      }
    case 0x6B where peek() == 0x3C:  // \k<name>: copy the name as written
      out += "\\k"
      while let u = peek() {
        out += String(decoding: [u], as: UTF16.self)
        i += 1
        if u == 0x3E { break }
      }
    default:
      if let u = escapedUnit(e) { literal(u) }
    }
  }

  /// The code unit an escape stands for (\t, \u0041, \x41, \cJ, \0, or an
  /// identity escape such as \. or \-). Used inside and outside classes.
  private mutating func escapedUnit(_ e: UInt16) -> UInt16? {
    switch e {
    case 0x74: return 0x09  // t
    case 0x6E: return 0x0A  // n
    case 0x76: return 0x0B  // v
    case 0x66: return 0x0C  // f
    case 0x72: return 0x0D  // r
    case 0x30 where !JSRegexTranslator.isDigit(peek()): return 0  // \0
    case 0x75 where (0..<4).allSatisfy({ JSRegexTranslator.isHex(peek($0)) }): return readHex(4)  // \uXXXX
    case 0x78 where JSRegexTranslator.isHex(peek()) && JSRegexTranslator.isHex(peek(1)): return readHex(2)  // \xXX
    case 0x63 where peek().map(JSRegexTranslator.isLetter) ?? false:  // \cJ
      let l = peek()!
      i += 1
      return l % 32
    case 0x63:  // \c not followed by a letter: a backslash and a "c"
      literal(0x5C)
      return 0x63
    default: return e  // identity escape (\u or \x without hex digits mean "u", "x")
    }
  }

  /// [ … ] at i (after the bracket).
  private mutating func charClass() {
    var negated = false
    if peek() == 0x5E {
      negated = true
      i += 1
    }
    var ranges: [ClosedRange<UInt16>] = []
    var nested: [String] = []  // \D, \W, \S inside the class
    // One class atom: a code unit, or a class escape (nil, appended to nested/ranges).
    func atom(_ t: inout JSRegexTranslator) -> UInt16? {
      let c = t.src[t.i]
      t.i += 1
      guard c == 0x5C, let e = t.peek() else { return c }
      t.i += 1
      switch e {
      case 0x64: ranges += JSRegexTranslator.digit
      case 0x44: nested.append(JSRegexTranslator.set(JSRegexTranslator.digit, negated: true))
      case 0x77: ranges += JSRegexTranslator.word
      case 0x57: nested.append(JSRegexTranslator.set(JSRegexTranslator.word, negated: true))
      case 0x73: ranges += JSRegexTranslator.space
      case 0x53: nested.append(JSRegexTranslator.set(JSRegexTranslator.space, negated: true))
      case 0x62: return 0x08  // \b is a backspace in a class
      case 0x2D: return 0x2D
      case 0x63 where !(t.peek().map(JSRegexTranslator.isLetter) ?? false): t.i -= 1; return 0x5C  // "\c…" is a backslash
      default: return t.escapedUnit(e)
      }
      return nil
    }
    while i < src.count, src[i] != 0x5D {
      let a = atom(&self)
      // A range a-b when both ends are single characters (otherwise "-" is literal).
      if let a, peek() == 0x2D, let n = peek(1), n != 0x5D {
        let save = i
        i += 1
        if let b = atom(&self) {
          precondition(a <= b, "JavaScript would reject the range in \(String(decoding: src, as: UTF16.self))")
          ranges.append(a...b)
          continue
        }
        i = save
      }
      if let a { ranges.append(a...a) }
    }
    i += 1  // ]
    if ignoreCase { ranges = JSCase.close(ranges) }
    if ranges.isEmpty && nested.isEmpty {
      // [] matches nothing, [^] anything.
      out += negated ? "[\\x{0}-\\x{10ffff}]" : "(?!)"
      return
    }
    out += "[" + (negated ? "^" : "") + JSRegexTranslator.members(ranges) + nested.joined() + "]"
  }
}

/// JavaScript's case-insensitive matching (Canonicalize without the u flag).
enum JSCase {
  /// Two characters match when their canonical forms are equal.
  static func canonical(_ u: UInt16) -> UInt16 {
    if u < 0x80 { return u >= 0x61 && u <= 0x7A ? u - 0x20 : u }
    guard let scalar = Unicode.Scalar(u) else { return u }  // a surrogate
    let upper = Array(String(scalar).uppercased().utf16)
    // Multi-character uppercase (ß -> SS) or non-ASCII to ASCII (ſ -> S) keep the character.
    if upper.count != 1 || upper[0] < 0x80 { return u }
    return upper[0]
  }

  /// The code units of each canonical form shared by more than one; built
  /// once, the first time a pattern needs a non-ASCII letter.
  private static let classes: [UInt16: [UInt16]] = {
    var map: [UInt16: [UInt16]] = [:]
    for u in 0...0xFFFF { map[canonical(UInt16(u)), default: []].append(UInt16(u)) }
    return map.filter { $0.value.count > 1 }
  }()

  /// The characters that match `u` case-insensitively (including u).
  static func equivalents(_ u: UInt16) -> [UInt16] {
    if u < 0x80 {
      if u >= 0x61 && u <= 0x7A { return [u - 0x20, u] }
      if u >= 0x41 && u <= 0x5A { return [u, u + 0x20] }
      return [u]
    }
    // Characters without case (spaces, digits, punctuation, most scripts) match only themselves.
    if let scalar = Unicode.Scalar(u) {
      let p = scalar.properties
      if !p.changesWhenUppercased && !p.changesWhenLowercased && !p.changesWhenCaseFolded { return [u] }
    }
    return classes[canonical(u)] ?? [u]
  }

  /// A set of ranges with every case-insensitive equivalent added.
  static func close(_ ranges: [ClosedRange<UInt16>]) -> [ClosedRange<UInt16>] {
    var extra: [ClosedRange<UInt16>] = []
    for r in ranges {
      // ASCII letters pair only with each other.
      let lower = max(r.lowerBound, 0x61), upper = min(r.upperBound, 0x7A)
      if lower <= upper { extra.append((lower - 0x20)...(upper - 0x20)) }
      let lowerU = max(r.lowerBound, 0x41), upperU = min(r.upperBound, 0x5A)
      if lowerU <= upperU { extra.append((lowerU + 0x20)...(upperU + 0x20)) }
      if r.upperBound >= 0x80 {
        for u in max(r.lowerBound, 0x80)...r.upperBound {
          for e in equivalents(u) where !r.contains(e) { extra.append(e...e) }
        }
      }
    }
    return ranges + extra
  }
}

extension String {
  /// Length in UTF-16 code units, like str.length.
  var jsLength: Int { utf16.count }

  /// str.slice(start, end) in UTF-16 offsets (negative counts from the end).
  func jsSlice(_ start: Int, _ end: Int? = nil) -> String {
    let n = jsLength
    var a = start < 0 ? max(0, n + start) : min(start, n)
    var b = end.map { $0 < 0 ? max(0, n + $0) : min($0, n) } ?? n
    if b < a { b = a }
    a = min(a, n)
    return (self as NSString).substring(with: NSRange(location: a, length: b - a))
  }

  /// str.toLowerCase(): each character's full lower-case mapping, and a capital
  /// sigma that ends a word becomes "ς" (Swift's lowercased() never does that,
  /// and NSString's word-end test differs from ICU's, which JavaScript uses).
  var jsLowercased: String {
    if utf8.allSatisfy({ $0 < 0x80 }) { return lowercased() }
    let scalars = Array(unicodeScalars)
    // ICU's rule: skip case-ignorable characters, then look for a cased one.
    func casedLetter(from start: Int, step: Int) -> Bool {
      var i = start
      while i >= 0 && i < scalars.count {
        let p = scalars[i].properties
        if !p.isCaseIgnorable { return p.isCased }
        i += step
      }
      return false
    }
    var out = String.UnicodeScalarView()
    for (i, s) in scalars.enumerated() {
      if s.value == 0x3A3 && casedLetter(from: i - 1, step: -1) && !casedLetter(from: i + 1, step: 1) {
        out.append(Unicode.Scalar(0x3C2)!)
      } else {
        out.append(contentsOf: s.properties.lowercaseMapping.unicodeScalars)
      }
    }
    return String(out)
  }

  /// str.trim(): JavaScript's whitespace, which includes the byte order mark.
  var jsTrimmed: String {
    let scalars = unicodeScalars
    var lo = scalars.startIndex
    var hi = scalars.endIndex
    while lo < hi, isJSSpace(scalars[lo]) { lo = scalars.index(after: lo) }
    while hi > lo, isJSSpace(scalars[scalars.index(before: hi)]) { hi = scalars.index(before: hi) }
    return String(scalars[lo..<hi])
  }

  /// str.trimStart().
  var jsTrimmedStart: String {
    let scalars = unicodeScalars
    var lo = scalars.startIndex
    while lo < scalars.endIndex, isJSSpace(scalars[lo]) { lo = scalars.index(after: lo) }
    return String(scalars[lo...])
  }

  /// str.startsWith(prefix), comparing code units.
  func jsStartsWith(_ prefix: String) -> Bool { utf16.starts(with: prefix.utf16) }

  /// str.includes(part), comparing code units.
  func jsIncludes(_ part: String) -> Bool {
    if part.isEmpty { return true }
    return (self as NSString).range(of: part, options: .literal).location != NSNotFound
  }

  /// str.padStart(width, fill) for short ASCII fills.
  func padStart(_ width: Int, _ fill: Character = " ") -> String {
    jsLength >= width ? self : String(repeating: fill, count: width - jsLength) + self
  }

  /// str.split(separator) with a string separator, comparing code units.
  func jsSplit(_ separator: String) -> [String] {
    let ns = self as NSString
    if separator.isEmpty { return (0..<ns.length).map { ns.substring(with: NSRange(location: $0, length: 1)) } }
    var out: [String] = []
    var from = 0
    while true {
      let r = ns.range(of: separator, options: .literal, range: NSRange(location: from, length: ns.length - from))
      if r.location == NSNotFound { break }
      out.append(ns.substring(with: NSRange(location: from, length: r.location - from)))
      from = r.location + r.length
    }
    out.append(ns.substring(from: from))
    return out
  }

  /// a === b for strings: the same code units (Swift's == also equates
  /// canonically equivalent strings, such as composed and decomposed accents).
  func jsEquals(_ other: String) -> Bool { utf16.elementsEqual(other.utf16) }
}

/// A string as a dictionary or set key the way JavaScript keys a Map or Set:
/// by its code units (a Swift String key equates canonically equivalent
/// spellings, such as composed and decomposed accents).
struct JSKey: Hashable {
  let units: [UInt16]
  init(_ s: String) { units = Array(s.utf16) }
}

/// Math.max / Math.min of two numbers: NaN if either is NaN.
func jsMax(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : Swift.max(a, b) }
func jsMin(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : Swift.min(a, b) }

/// String(number): JavaScript's Number::toString (shortest digits that read
/// back as the same number; exponent form below 1e-6 and from 1e21).
func jsNumber(_ x: Double) -> String {
  if x.isNaN { return "NaN" }
  if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
  if x == 0 { return "0" }
  // Swift's description also gives the shortest round-trip digits; only the layout differs.
  var desc = "\(abs(x))"
  var exp10 = 0
  if let e = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
    exp10 = Int(desc[desc.index(after: e)...])!
    desc = String(desc[..<e])
  }
  var intPart = desc, frac = ""
  if let dot = desc.firstIndex(of: ".") {
    intPart = String(desc[..<dot])
    frac = String(desc[desc.index(after: dot)...])
  }
  // value = 0.digits × 10^n, digits without leading or trailing zeros.
  var digits = Array(intPart + frac)
  var n = intPart.count + exp10
  while digits.first == "0" { digits.removeFirst(); n -= 1 }
  while digits.last == "0" { digits.removeLast() }
  let k = digits.count
  let s = String(digits)
  var out: String
  if k <= n && n <= 21 {
    out = s + String(repeating: "0", count: n - k)
  } else if 0 < n && n <= 21 {
    out = String(digits[..<n]) + "." + String(digits[n...])
  } else if -6 < n && n <= 0 {
    out = "0." + String(repeating: "0", count: -n) + s
  } else {
    let e = n - 1
    out = String(digits[0]) + (k > 1 ? "." + String(digits[1...]) : "") + "e" + (e < 0 ? "-" : "+") + String(abs(e))
  }
  return x < 0 ? "-" + out : out
}

private func isJSSpace(_ c: Unicode.Scalar) -> Bool {
  switch c.value {
  case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
    return true
  default:
    return false
  }
}

/// Number(str): JavaScript's StringNumericLiteral (decimal, Infinity, 0x/0o/0b
/// integers); anything else is NaN. Swift's own parser also takes "inf",
/// "nan" and hex fractions, which JavaScript does not.
func jsNumberValue(_ s: String) -> Double {
  let t = s.jsTrimmed
  if t.isEmpty { return 0 }
  if let m = jsRadixLiteral.match(t) {
    let radix = ["x": 16, "o": 8, "b": 2][m[1]!.lowercased()]!
    var value = 0.0
    for c in m[2]! {
      guard let d = Int(String(c), radix: radix) else { return .nan }
      value = value * Double(radix) + Double(d)
    }
    return value
  }
  guard jsDecimalLiteral.test(t) else { return .nan }
  if t.hasSuffix("Infinity") { return t.hasPrefix("-") ? -.infinity : .infinity }
  return Double(t) ?? .nan
}
private let jsRadixLiteral = Re("^0([xXoObB])([0-9a-fA-F]+)$")
private let jsDecimalLiteral = Re(#"^[+-]?(?:Infinity|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)$"#)

// ---- JSON values the way JavaScript sees them --------------------------------------
// (JSON.parse below gives String, NSNumber, NSNull, [Any] and [String: Any], as
// JSONSerialization does; booleans are NSNumbers too.)

enum JSON {
  /// JSON.parse: the value, or nil where JavaScript throws. JSONSerialization
  /// differs: it drops a byte-order mark at the start of strings, rejects lone
  /// surrogates, keeps the first of repeated keys and accepts a leading BOM.
  /// Two things can't match: a lone surrogate becomes U+FFFD (Swift strings
  /// can't hold one), and keys equal only in Swift (é and e + ◌́) merge.
  static func parse(_ text: String) -> Any? {
    var parser = JSONParser(Array(text.utf16))
    return parser.parse()
  }

  /// Object.keys(JSON.parse(text)[member]): the keys of one member of a
  /// top-level object in JavaScript's order (array indices first, ascending,
  /// then the others as first written). Nil where JSON.parse would throw or
  /// the member isn't an object.
  static func memberKeys(_ text: String, _ member: String) -> [String]? {
    guard parse(text) is [String: Any] else { return nil }
    var parser = JSONParser(Array(text.utf16))
    guard let keys = parser.memberKeys(member) else { return nil }
    var seen = Set<JSKey>()
    var indices: [(UInt32, String)] = []
    var names: [String] = []
    for k in keys where seen.insert(JSKey(k)).inserted {
      if let n = arrayIndex(k) { indices.append((n, k)) } else { names.append(k) }
    }
    return indices.sorted { $0.0 < $1.0 }.map(\.1) + names
  }

  /// The number a key stands for when it is an array index ("0", "17"; not "017" or 2³²−1).
  private static func arrayIndex(_ k: String) -> UInt32? {
    let u = Array(k.utf16)
    guard !u.isEmpty, u.count <= 10, u.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), u[0] != 0x30 || u.count == 1,
      let n = UInt64(k), n < 0xFFFF_FFFF
    else { return nil }
    return UInt32(n)
  }

  /// Response.json() of fetch: the body decoded as UTF-8 (up to two leading
  /// byte-order marks dropped, bad bytes replaced), then parsed.
  static func parse(body: Data) -> Any? {
    var bytes = body[...]
    for _ in 0..<2 where bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
    return parse(String(decoding: bytes, as: UTF8.self))
  }

  static func isBool(_ v: Any?) -> Bool {
    guard let n = v as? NSNumber else { return false }
    return CFGetTypeID(n) == CFBooleanGetTypeID()
  }

  /// A number (not a boolean) as a Double.
  static func number(_ v: Any?) -> Double? {
    guard let n = v as? NSNumber, !isBool(n) else { return nil }
    return n.doubleValue
  }

  /// A whole number (not a boolean).
  static func int(_ v: Any?) -> Int? { number(v).flatMap { Int(exactly: $0) } }

  /// !!v
  static func truthy(_ v: Any?) -> Bool {
    guard let v, !(v is NSNull) else { return false }
    if let n = v as? NSNumber { return isBool(n) ? n.boolValue : n.doubleValue != 0 && !n.doubleValue.isNaN }
    if let s = v as? String { return !s.isEmpty }
    return true
  }

  /// String(v); nil for null and undefined.
  static func string(_ v: Any?) -> String? {
    guard let v, !(v is NSNull) else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return isBool(n) ? (n.boolValue ? "true" : "false") : jsNumber(n.doubleValue) }
    if let a = v as? [Any] { return a.map { string($0) ?? "" }.joined(separator: ",") }
    return "[object Object]"
  }

  /// Number(v).
  static func toNumber(_ v: Any?) -> Double {
    guard let v else { return .nan }
    if v is NSNull { return 0 }
    if let n = v as? NSNumber { return isBool(n) ? (n.boolValue ? 1 : 0) : n.doubleValue }
    return jsNumberValue(string(v)!)
  }

  /// a || b
  static func or(_ a: Any?, _ b: Any?) -> Any? { truthy(a) ? a : b }

  /// a ?? b
  static func nullish(_ a: Any?, _ b: Any?) -> Any? { a == nil || a is NSNull ? b : a }

  /// v?.[key] for an object (anything else has no such property here).
  static func get(_ v: Any?, _ key: String) -> Any? { (v as? [String: Any])?[key] }
}

/// JSON.parse over UTF-16 code units, without recursion (deep nesting is fine).
private struct JSONParser {
  private let s: [UInt16]
  private var i = 0

  init(_ s: [UInt16]) { self.s = s }

  /// An array or object being read.
  private final class Container {
    var array: [Any]?
    var object: [String: Any]?
    var key = ""
    init(array: [Any]) { self.array = array }
    init(object: [String: Any]) { self.object = object }
  }

  mutating func parse() -> Any? {
    var stack: [Container] = []
    while true {
      skipSpace()
      guard i < s.count else { return nil }
      var value: Any
      switch s[i] {
      case 0x7B:  // {
        i += 1
        skipSpace()
        if i < s.count && s[i] == 0x7D {
          i += 1
          value = [String: Any]()
        } else {
          let c = Container(object: [:])
          guard let key = readKey() else { return nil }
          c.key = key
          stack.append(c)
          continue
        }
      case 0x5B:  // [
        i += 1
        skipSpace()
        if i < s.count && s[i] == 0x5D {
          i += 1
          value = [Any]()
        } else {
          stack.append(Container(array: []))
          continue
        }
      case 0x22:
        guard let str = readString() else { return nil }
        value = str
      case 0x2D, 0x30...0x39:
        guard let n = readNumber() else { return nil }
        value = NSNumber(value: n)
      case 0x74:
        guard literal("true") else { return nil }
        value = NSNumber(value: true)
      case 0x66:
        guard literal("false") else { return nil }
        value = NSNumber(value: false)
      case 0x6E:
        guard literal("null") else { return nil }
        value = NSNull()
      default:
        return nil
      }
      // Hand the value to the container it is in, closing those that end here.
      while true {
        guard let top = stack.last else {
          skipSpace()
          return i == s.count ? value : nil
        }
        skipSpace()
        guard i < s.count else { return nil }
        let c = s[i]
        i += 1
        if top.array != nil {
          top.array!.append(value)
          if c == 0x2C { break }  // ,
          guard c == 0x5D else { return nil }  // ]
          value = top.array!
        } else {
          top.object![top.key] = value
          if c == 0x2C {
            skipSpace()
            guard let key = readKey() else { return nil }
            top.key = key
            break
          }
          guard c == 0x7D else { return nil }  // }
          value = top.object!
        }
        stack.removeLast()
      }
    }
  }

  private mutating func skipSpace() {
    while i < s.count, s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0A || s[i] == 0x0D { i += 1 }
  }

  // ---- Keys in order (JSON.memberKeys), on text parse() accepted as an object ----

  /// The keys, as written, of the last `member` of the top-level object; nil
  /// when there is none or it isn't an object.
  mutating func memberKeys(_ member: String) -> [String]? {
    var found: [String]?
    skipSpace()
    i += 1  // {
    skipSpace()
    if s[i] == 0x7D { return nil }
    while true {
      guard let key = readKey() else { return nil }
      skipSpace()
      if key.jsEquals(member) {
        found = s[i] == 0x7B ? objectKeys() : nil
        if found == nil { skipValue() }
      } else {
        skipValue()
      }
      skipSpace()
      guard s[i] == 0x2C else { return found }  // , (else the closing brace)
      i += 1
      skipSpace()
    }
  }

  /// The keys of the object starting here, as written; moves past it.
  private mutating func objectKeys() -> [String] {
    var keys: [String] = []
    i += 1  // {
    skipSpace()
    if s[i] == 0x7D {
      i += 1
      return keys
    }
    while true {
      guard let key = readKey() else { return keys }
      keys.append(key)
      skipValue()
      skipSpace()
      let c = s[i]
      i += 1
      if c != 0x2C { return keys }  // the closing brace
      skipSpace()
    }
  }

  /// Moves past one value.
  private mutating func skipValue() {
    skipSpace()
    switch s[i] {
    case 0x22:
      _ = readString()
    case 0x7B, 0x5B:
      var depth = 0
      repeat {
        switch s[i] {
        case 0x22:
          _ = readString()
        case 0x7B, 0x5B:
          depth += 1
          i += 1
        case 0x7D, 0x5D:
          depth -= 1
          i += 1
        default:
          i += 1
        }
      } while depth > 0
    default:  // a number, true, false or null
      while i < s.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(s[i]) { i += 1 }
    }
  }

  /// A key and its colon.
  private mutating func readKey() -> String? {
    guard i < s.count, s[i] == 0x22, let key = readString() else { return nil }
    skipSpace()
    guard i < s.count, s[i] == 0x3A else { return nil }
    i += 1
    return key
  }

  private mutating func readString() -> String? {
    i += 1  // the opening quote
    var units: [UInt16] = []
    while i < s.count {
      let c = s[i]
      i += 1
      switch c {
      case 0x22:
        return String(decoding: units, as: UTF16.self)
      case 0x5C:
        guard i < s.count else { return nil }
        let e = s[i]
        i += 1
        switch e {
        case 0x22, 0x5C, 0x2F: units.append(e)
        case 0x62: units.append(0x08)
        case 0x66: units.append(0x0C)
        case 0x6E: units.append(0x0A)
        case 0x72: units.append(0x0D)
        case 0x74: units.append(0x09)
        case 0x75:
          guard i + 4 <= s.count else { return nil }
          var v: UInt16 = 0
          for h in s[i..<i + 4] {
            switch h {
            case 0x30...0x39: v = v << 4 | (h - 0x30)
            case 0x41...0x46: v = v << 4 | (h - 0x41 + 10)
            case 0x61...0x66: v = v << 4 | (h - 0x61 + 10)
            default: return nil
            }
          }
          i += 4
          units.append(v)
        default:
          return nil
        }
      case 0..<0x20:
        return nil
      default:
        units.append(c)
      }
    }
    return nil
  }

  /// -?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?
  private mutating func readNumber() -> Double? {
    let start = i
    func digits() -> Int {
      let from = i
      while i < s.count, s[i] >= 0x30 && s[i] <= 0x39 { i += 1 }
      return i - from
    }
    if s[i] == 0x2D { i += 1 }
    guard i < s.count else { return nil }
    if s[i] == 0x30 {
      i += 1
    } else if digits() == 0 {
      return nil
    }
    if i < s.count, s[i] == 0x2E {
      i += 1
      guard digits() > 0 else { return nil }
    }
    if i < s.count, s[i] == 0x65 || s[i] == 0x45 {
      i += 1
      if i < s.count, s[i] == 0x2B || s[i] == 0x2D { i += 1 }
      guard digits() > 0 else { return nil }
    }
    return Double(String(decoding: s[start..<i], as: UTF16.self))
  }

  private mutating func literal(_ word: String) -> Bool {
    let w = Array(word.utf16)
    guard i + w.count <= s.count, Array(s[i..<i + w.count]) == w else { return false }
    i += w.count
    return true
  }
}
