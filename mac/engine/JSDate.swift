import Foundation

// Date.parse, ported step for step from V8 14.6 (the engine in Node 26):
// src/date/dateparser.h, dateparser-inl.h, dateparser.cc and date.cc. The
// ECMAScript date-time format is tried first ("2030-01-01T00:00:00.000Z");
// whatever else the string holds goes to V8's legacy parser ("Jan 2 2030
// 10:00 PM", "2030/06/15 GMT+2"), quirks included: days up to 31 in any month,
// two-digit years, a NUL ending the string. Date-times without an offset are
// local time, resolved through ICU the way V8 does it.

/// Date.parse(s): milliseconds since 1970, or nil where JavaScript gives NaN.
func jsDateParse(_ s: String) -> Double? {
  var parser = V8DateParser(Array(s.utf16))
  guard let out = parser.parse() else { return nil }
  let day = V8DateParser.makeDay(Double(out.year), Double(out.month), Double(out.day))
  let time = V8DateParser.makeTime(Double(out.hour), Double(out.minute), Double(out.second), Double(out.millisecond))
  var date = V8DateParser.makeDate(day, time)
  if let offset = out.utcOffset {
    date -= Double(offset) * 1000
  } else {
    let limit = Double(V8DateParser.maxTimeInMs + V8DateParser.msPerMonth)
    guard date >= -limit && date <= limit else { return nil }
    let local = Int64(date)
    date = Double(local - Int64(localOffsetFromLocal(local)))
  }
  guard -Double(V8DateParser.maxTimeInMs) <= date && date <= Double(V8DateParser.maxTimeInMs) else { return nil }
  return (date > 0 ? date.rounded(.down) : date.rounded(.up)) + 0.0
}

/// The offset (ms) of the default time zone at a local wall-clock time: in a
/// gap or an overlap, the offset in force before the change (ICU's
/// UCAL_TZ_LOCAL_FORMER, as V8 asks for).
private func localOffsetFromLocal(_ localMs: Int64) -> Int {
  var status: UErrorCode = 0
  guard let cal = ucal_open(nil, 0, nil, 1 /* UCAL_GREGORIAN */, &status), status <= 0 else { return 0 }
  defer { ucal_close(cal) }
  ucal_setMillis(cal, Double(localMs), &status)
  var raw: Int32 = 0, dst: Int32 = 0
  ucal_getTimeZoneOffsetFromLocal(cal, 0x04, 0x04, &raw, &dst, &status)  // UCAL_TZ_LOCAL_FORMER twice
  return status > 0 ? 0 : Int(raw) + Int(dst)
}

private struct V8DateParser {
  static let maxTimeInMs: Int64 = 864_000_000 * 10_000_000
  static let msPerMonth: Int64 = 86_400_000 * 30

  struct Output {
    var year = 0, month = 0, day = 0
    var hour = 0, minute = 0, second = 0, millisecond = 0
    /// Seconds east of UTC; nil when the string named no time zone.
    var utcOffset: Int?
  }

  static let kNone = Int(Int32.max)
  static let kMaxSignificantDigits = 9

  static func between(_ x: Int, _ lo: Int, _ hi: Int) -> Bool { lo <= x && x <= hi }

  // ---- InputReader --------------------------------------------------------------------

  private let buffer: [UInt16]
  private var index = 0
  private var ch: UInt32 = 0

  init(_ s: [UInt16]) {
    buffer = s
    nextToken = .endOfInput
    next()
    nextToken = scan()
  }

  private var position: Int { index }

  private mutating func next() {
    ch = index < buffer.count ? UInt32(buffer[index]) : 0
    index += 1
  }

  /// A string of digits as an unsigned number: up to 9 significant digits
  /// count, the rest are skipped.
  private mutating func readUnsignedNumeral() -> Int {
    var n = 0
    var i = 0
    while ch == 0x30 { next() }
    while isAsciiDigit {
      if i < V8DateParser.kMaxSignificantDigits { n = n * 10 + Int(ch) - 0x30 }
      i += 1
      next()
    }
    return n
  }

  /// A word (characters >= "A"): fills `prefix` with its first characters,
  /// "lower-cased" (| 0x20), zero-padded. Returns the word's length.
  private mutating func readWord(_ prefix: inout [UInt32]) -> Int {
    var len = 0
    while isAsciiAlphaOrAbove && !isWhiteSpaceChar {
      if len < prefix.count { prefix[len] = ch | 0x20 }
      next()
      len += 1
    }
    var i = len
    while i < prefix.count {
      prefix[i] = 0
      i += 1
    }
    return len
  }

  private mutating func skip(_ c: UInt32) -> Bool {
    if ch == c {
      next()
      return true
    }
    return false
  }

  private mutating func skipWhiteSpace() -> Bool {
    if V8DateParser.isWhiteSpaceOrLineTerminator(ch) {
      next()
      return true
    }
    return false
  }

  private mutating func skipParentheses() -> Bool {
    if ch != 0x28 { return false }
    var balance = 0
    repeat {
      if ch == 0x29 {
        balance -= 1
      } else if ch == 0x28 {
        balance += 1
      }
      next()
    } while balance > 0 && ch != 0
    return true
  }

  private var isEnd: Bool { ch == 0 }
  private var isAsciiDigit: Bool { ch >= 0x30 && ch <= 0x39 }
  private var isAsciiAlphaOrAbove: Bool { ch >= 0x41 }
  private var isWhiteSpaceChar: Bool { V8DateParser.isWhiteSpace(ch) }

  /// ECMAScript WhiteSpace: tab, VT, FF, space, U+FEFF and the Zs characters.
  static func isWhiteSpace(_ c: UInt32) -> Bool {
    switch c {
    case 0x09, 0x0B, 0x0C, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
    default: return false
    }
  }

  static func isWhiteSpaceOrLineTerminator(_ c: UInt32) -> Bool {
    isWhiteSpace(c) || c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029
  }

  // ---- Tokens ---------------------------------------------------------------------------

  enum KeywordType: Int { case invalid = 0, monthName, timeZoneName, timeSeparator, amPm }

  struct DateToken {
    static let invalidTag = -6, unknownTag = -5, whiteSpaceTag = -4, numberTag = -3, symbolTag = -2, endOfInputTag = -1

    var tag: Int
    var length: Int
    var value: Int

    var isInvalid: Bool { tag == DateToken.invalidTag }
    var isNumber: Bool { tag == DateToken.numberTag }
    var isSymbol: Bool { tag == DateToken.symbolTag }
    var isWhiteSpace: Bool { tag == DateToken.whiteSpaceTag }
    var isEndOfInput: Bool { tag == DateToken.endOfInputTag }
    var isKeyword: Bool { tag >= 0 }
    var number: Int { value }
    var keywordType: KeywordType { KeywordType(rawValue: tag)! }
    var keywordValue: Int { value }
    func isSymbol(_ c: Character) -> Bool { isSymbol && value == Int(c.asciiValue!) }
    func isKeywordType(_ t: KeywordType) -> Bool { tag == t.rawValue }
    func isFixedLengthNumber(_ n: Int) -> Bool { isNumber && length == n }
    var isAsciiSign: Bool { tag == DateToken.symbolTag && (value == 0x2D || value == 0x2B) }
    var asciiSign: Int { 44 - value }
    var isKeywordZ: Bool { isKeywordType(.timeZoneName) && length == 1 && value == 0 }

    static func keyword(_ type: KeywordType, _ value: Int, _ length: Int) -> DateToken { DateToken(tag: type.rawValue, length: length, value: value) }
    static func number(_ value: Int, _ length: Int) -> DateToken { DateToken(tag: numberTag, length: length, value: value) }
    static func symbol(_ c: UInt32) -> DateToken { DateToken(tag: symbolTag, length: 1, value: Int(c)) }
    static let endOfInput = DateToken(tag: endOfInputTag, length: 0, value: -1)
    static func whiteSpace(_ length: Int) -> DateToken { DateToken(tag: whiteSpaceTag, length: length, value: -1) }
    static let unknown = DateToken(tag: unknownTag, length: 1, value: -1)
    static let invalid = DateToken(tag: invalidTag, length: 0, value: -1)
  }

  /// Month names, time zones, am/pm and "t", by their first three letters.
  static let keywords: [(prefix: [UInt32], type: KeywordType, value: Int)] = [
    ("jan", .monthName, 1), ("feb", .monthName, 2), ("mar", .monthName, 3), ("apr", .monthName, 4), ("may", .monthName, 5),
    ("jun", .monthName, 6), ("jul", .monthName, 7), ("aug", .monthName, 8), ("sep", .monthName, 9), ("oct", .monthName, 10),
    ("nov", .monthName, 11), ("dec", .monthName, 12), ("am", .amPm, 0), ("pm", .amPm, 12), ("ut", .timeZoneName, 0),
    ("utc", .timeZoneName, 0), ("z", .timeZoneName, 0), ("gmt", .timeZoneName, 0), ("cdt", .timeZoneName, -5),
    ("cst", .timeZoneName, -6), ("edt", .timeZoneName, -4), ("est", .timeZoneName, -5), ("mdt", .timeZoneName, -6),
    ("mst", .timeZoneName, -7), ("pdt", .timeZoneName, -7), ("pst", .timeZoneName, -8), ("t", .timeSeparator, 0),
  ].map { (name: String, type: KeywordType, value: Int) in
    var p = name.unicodeScalars.map { $0.value }
    while p.count < 3 { p.append(0) }
    return (p, type, value)
  }

  /// The keyword a word is (an invalid one when none): words longer than
  /// three letters only count as month names.
  static func lookup(_ pre: [UInt32], _ len: Int) -> (type: KeywordType, value: Int) {
    for k in keywords where k.prefix == pre && (len <= 3 || k.type == .monthName) {
      return (k.type, k.value)
    }
    return (.invalid, 0)
  }

  private var nextToken: DateToken

  private mutating func scan() -> DateToken {
    let prePos = position
    if isEnd { return .endOfInput }
    if isAsciiDigit {
      let n = readUnsignedNumeral()
      return .number(n, position - prePos)
    }
    for c: UInt32 in [0x3A, 0x2D, 0x2B, 0x2E, 0x29] where skip(c) {  // : - + . )
      return .symbol(c)
    }
    if isAsciiAlphaOrAbove && !isWhiteSpaceChar {
      var buffer: [UInt32] = [0, 0, 0]
      let length = readWord(&buffer)
      let k = V8DateParser.lookup(buffer, length)
      return .keyword(k.type, k.value, length)
    }
    if skipWhiteSpace() { return .whiteSpace(position - prePos) }
    if skipParentheses() { return .unknown }
    next()
    return .unknown
  }

  /// The next token, moving past it.
  private mutating func take() -> DateToken {
    let result = nextToken
    nextToken = scan()
    return result
  }

  private var peek: DateToken { nextToken }

  private mutating func skipSymbol(_ c: Character) -> Bool {
    if nextToken.isSymbol(c) {
      nextToken = scan()
      return true
    }
    return false
  }

  static func readMilliseconds(_ token: DateToken) -> Int {
    var number = token.number
    var length = token.length
    if length < 3 {
      if length == 1 {
        number *= 100
      } else if length == 2 {
        number *= 10
      }
    } else if length > 3 {
      if length > kMaxSignificantDigits { length = kMaxSignificantDigits }
      var factor = 1
      repeat {
        factor *= 10
        length -= 1
      } while length > 3
      number /= factor
    }
    return number
  }

  // ---- Composers --------------------------------------------------------------------------

  struct TimeZoneComposer {
    var sign = kNone, hour = kNone, minute = kNone

    mutating func set(_ offsetInHours: Int) {
      sign = offsetInHours < 0 ? -1 : 1
      hour = offsetInHours * sign
      minute = 0
    }
    mutating func setSign(_ s: Int) { sign = s < 0 ? -1 : 1 }
    func isExpecting(_ n: Int) -> Bool { hour != kNone && minute == kNone && TimeComposer.isMinute(n) }
    var isUTC: Bool { hour == 0 && minute == 0 }
    var isEmpty: Bool { hour == kNone }

    mutating func write(_ out: inout Output) -> Bool {
      if sign != kNone {
        if hour == kNone { hour = 0 }
        if minute == kNone { minute = 0 }
        // Unsigned 32-bit arithmetic, wrapping, as in V8.
        let total = UInt32(truncatingIfNeeded: hour) &* 3600 &+ UInt32(truncatingIfNeeded: minute) &* 60
        if total > UInt32(Int32.max) { return false }
        out.utcOffset = sign < 0 ? -Int(total) : Int(total)
      } else {
        out.utcOffset = nil
      }
      return true
    }
  }

  struct TimeComposer {
    static let size = 4
    var comp = [Int](repeating: 0, count: size)
    var index = 0
    var hourOffset = kNone

    var isEmpty: Bool { index == 0 }
    func isExpecting(_ n: Int) -> Bool {
      (index == 1 && TimeComposer.isMinute(n)) || (index == 2 && TimeComposer.isSecond(n)) || (index == 3 && TimeComposer.isMillisecond(n))
    }
    @discardableResult mutating func add(_ n: Int) -> Bool {
      guard index < TimeComposer.size else { return false }
      comp[index] = n
      index += 1
      return true
    }
    @discardableResult mutating func addFinal(_ n: Int) -> Bool {
      if !add(n) { return false }
      while index < TimeComposer.size {
        comp[index] = 0
        index += 1
      }
      return true
    }

    static func isMinute(_ x: Int) -> Bool { between(x, 0, 59) }
    static func isHour(_ x: Int) -> Bool { between(x, 0, 23) }
    static func isSecond(_ x: Int) -> Bool { between(x, 0, 59) }
    static func isHour12(_ x: Int) -> Bool { between(x, 0, 12) }
    static func isMillisecond(_ x: Int) -> Bool { between(x, 0, 999) }

    mutating func write(_ out: inout Output) -> Bool {
      while index < TimeComposer.size {
        comp[index] = 0
        index += 1
      }
      var hour = comp[0]
      let minute = comp[1], second = comp[2], millisecond = comp[3]
      if hourOffset != kNone {
        if !TimeComposer.isHour12(hour) { return false }
        hour %= 12
        hour += hourOffset
      }
      if !TimeComposer.isHour(hour) || !TimeComposer.isMinute(minute) || !TimeComposer.isSecond(second)
        || !TimeComposer.isMillisecond(millisecond)
      {
        // A 24th hour is allowed if minutes, seconds, and milliseconds are 0.
        if hour != 24 || minute != 0 || second != 0 || millisecond != 0 { return false }
      }
      out.hour = hour
      out.minute = minute
      out.second = second
      out.millisecond = millisecond
      return true
    }
  }

  struct DayComposer {
    static let size = 3
    var comp = [Int](repeating: 0, count: size)
    var index = 0
    var namedMonth = kNone
    /// Always year-month-day.
    var isISODate = false

    var isEmpty: Bool { index == 0 }
    mutating func add(_ n: Int) -> Bool {
      guard index < DayComposer.size else { return false }
      comp[index] = n
      index += 1
      return true
    }
    static func isMonth(_ x: Int) -> Bool { between(x, 1, 12) }
    static func isDay(_ x: Int) -> Bool { between(x, 1, 31) }

    mutating func write(_ out: inout Output) -> Bool {
      if index < 1 { return false }
      // Day and month default to 1.
      while index < DayComposer.size {
        comp[index] = 1
        index += 1
      }
      var year = 0  // 0 (=> 2000) by default, for KJS compatibility
      var month = kNone
      var day = kNone
      if namedMonth == kNone {
        if isISODate || (index == 3 && !DayComposer.isDay(comp[0])) {
          year = comp[0]
          month = comp[1]
          day = comp[2]
        } else {
          month = comp[0]
          day = comp[1]
          if index == 3 { year = comp[2] }
        }
      } else {
        month = namedMonth
        if index == 1 {
          day = comp[0]
        } else if !DayComposer.isDay(comp[0]) {
          year = comp[0]
          day = comp[1]
        } else {
          day = comp[0]
          year = comp[1]
        }
      }
      if !isISODate {
        if between(year, 0, 49) {
          year += 2000
        } else if between(year, 50, 99) {
          year += 1900
        }
      }
      if !DayComposer.isMonth(month) || !DayComposer.isDay(day) { return false }
      out.year = year
      out.month = month - 1
      out.day = day
      return true
    }
  }

  // ---- Parsing ----------------------------------------------------------------------------

  mutating func parse() -> Output? {
    var tz = TimeZoneComposer()
    var time = TimeComposer()
    var day = DayComposer()

    // As far as possible as an ES5 date-time string, then the legacy parser.
    let nextUnhandled = parseES5DateTime(&day, &time, &tz)
    if nextUnhandled.isInvalid { return nil }
    var hasReadNumber = !day.isEmpty
    var token = nextUnhandled
    while !token.isEndOfInput {
      if token.isNumber {
        hasReadNumber = true
        let n = token.number
        if skipSymbol(":") {
          if skipSymbol(":") {
            // n + "::"
            if !time.isEmpty { return nil }
            time.add(n)
            time.add(0)
          } else {
            // n + ":"
            if !time.add(n) { return nil }
            if peek.isSymbol(".") { _ = take() }
          }
        } else if skipSymbol("."), time.isExpecting(n) {
          time.add(n)
          if !peek.isNumber { return nil }
          let ms = V8DateParser.readMilliseconds(take())
          if ms < 0 { return nil }
          time.addFinal(ms)
        } else if tz.isExpecting(n) {
          tz.minute = n
        } else if time.isExpecting(n) {
          time.addFinal(n)
          // Require end, white space, "Z", "+" or "-" immediately after finalizing time.
          let p = peek
          if !p.isEndOfInput && !p.isWhiteSpace && !p.isKeywordZ && !p.isAsciiSign { return nil }
        } else {
          if !day.add(n) { return nil }
          _ = skipSymbol("-")
        }
      } else if token.isKeyword {
        // A word (characters >= "A").
        let type = token.keywordType
        let value = token.keywordValue
        if type == .amPm && !time.isEmpty {
          time.hourOffset = value
        } else if type == .monthName {
          day.namedMonth = value
          _ = skipSymbol("-")
        } else if type == .timeZoneName && hasReadNumber {
          tz.set(value)
        } else {
          // Garbage words are illegal if a number has been read.
          if hasReadNumber { return nil }
          // The first number has to be separated from garbage words by whitespace or other separators.
          if peek.isNumber { return nil }
        }
      } else if token.isAsciiSign && (tz.isUTC || !time.isEmpty) {
        // A UTC offset (only after UTC or a time).
        tz.setSign(token.asciiSign)
        // The following number may be empty.
        var n = 0
        var length = 0
        if peek.isNumber {
          let t = take()
          length = t.length
          n = t.number
        }
        hasReadNumber = true
        if peek.isSymbol(":") {
          tz.hour = n
          tz.minute = V8DateParser.kNone
        } else if length == 2 || length == 1 {
          // Time zones like GMT-8
          tz.hour = n
          tz.minute = 0
        } else if length == 4 || length == 3 {
          // hhmm
          tz.hour = n / 100
          tz.minute = n % 100
        } else {
          // No time zones like GMT-12345
          return nil
        }
      } else if (token.isAsciiSign || token.isSymbol(")")) && hasReadNumber {
        // An extra sign or ")" is illegal once a number has been read.
        return nil
      }
      // Anything else (white space, other characters) is ignored.
      token = take()
    }

    var out = Output()
    guard day.write(&out), time.write(&out), tz.write(&out) else { return nil }
    return out
  }

  /// Parses an ES5 date-time string as far as it goes: returns the token the
  /// legacy parser goes on with, the end of input when the string was all
  /// read, or an invalid token when it can't be a date.
  private mutating func parseES5DateTime(_ day: inout DayComposer, _ time: inout TimeComposer, _ tz: inout TimeZoneComposer) -> DateToken {
    // The date: [('-'|'+')yy]yyyy[-MM[-DD]]
    if peek.isAsciiSign {
      // Keep the sign token, to pass it back to the legacy parser if not used.
      let signToken = take()
      if !peek.isFixedLengthNumber(6) { return signToken }
      let sign = signToken.asciiSign
      let year = take().number
      if sign < 0 && year == 0 { return signToken }
      _ = day.add(sign * year)
    } else if peek.isFixedLengthNumber(4) {
      _ = day.add(take().number)
    } else {
      return take()
    }
    if skipSymbol("-") {
      if !peek.isFixedLengthNumber(2) || !DayComposer.isMonth(peek.number) { return take() }
      _ = day.add(take().number)
      if skipSymbol("-") {
        if !peek.isFixedLengthNumber(2) || !DayComposer.isDay(peek.number) { return take() }
        _ = day.add(take().number)
      }
    }
    // The time, optional: 'T'HH':'mm[':'ss['.'sss]]Z
    if !peek.isKeywordType(.timeSeparator) {
      if !peek.isEndOfInput { return take() }
    } else {
      _ = take()
      if !peek.isFixedLengthNumber(2) || !V8DateParser.between(peek.number, 0, 24) { return .invalid }
      // 24:00[:00[.000]] is allowed, no other time starting with 24.
      let hourIs24 = peek.number == 24
      time.add(take().number)
      if !skipSymbol(":") { return .invalid }
      if !peek.isFixedLengthNumber(2) || !TimeComposer.isMinute(peek.number) || (hourIs24 && peek.number > 0) { return .invalid }
      time.add(take().number)
      if skipSymbol(":") {
        if !peek.isFixedLengthNumber(2) || !TimeComposer.isSecond(peek.number) || (hourIs24 && peek.number > 0) { return .invalid }
        time.add(take().number)
        if skipSymbol(".") {
          if !peek.isNumber || (hourIs24 && peek.number > 0) { return .invalid }
          // More or less than the mandated three digits are allowed.
          time.add(V8DateParser.readMilliseconds(take()))
        }
      }
      // The time zone, optional: 'Z' | ('+'|'-')hh':'mm
      if peek.isKeywordZ {
        _ = take()
        tz.set(0)
      } else if peek.isSymbol("+") || peek.isSymbol("-") {
        tz.setSign(take().value == 0x2B ? 1 : -1)
        if peek.isFixedLengthNumber(4) {
          // hhmm extension syntax.
          let hourmin = take().number
          let hour = hourmin / 100
          let min = hourmin % 100
          if !TimeComposer.isHour(hour) || !TimeComposer.isMinute(min) { return .invalid }
          tz.hour = hour
          tz.minute = min
        } else {
          // hh:mm standard syntax.
          if !peek.isFixedLengthNumber(2) || !TimeComposer.isHour(peek.number) { return .invalid }
          tz.hour = take().number
          if !skipSymbol(":") { return .invalid }
          if !peek.isFixedLengthNumber(2) || !TimeComposer.isMinute(peek.number) { return .invalid }
          tz.minute = take().number
        }
      }
      if !peek.isEndOfInput { return .invalid }
    }
    // A whole ES5 date-time string. Without an offset, date-only forms are
    // UTC and date-time forms local time.
    if tz.isEmpty && time.isEmpty { tz.set(0) }
    day.isISODate = true
    return .endOfInput
  }

  // ---- Time values (date.cc) ----------------------------------------------------------------

  static func makeDate(_ day: Double, _ time: Double) -> Double {
    day.isFinite && time.isFinite ? time + day * 86_400_000 : .nan
  }

  static func makeDay(_ year: Double, _ month: Double, _ date: Double) -> Double {
    guard -1_000_000 <= year && year <= 1_000_000, -10_000_000 <= month && month <= 10_000_000, date.isFinite else { return .nan }
    var y = Int(year)
    var m = Int(month)
    y += m / 12
    m %= 12
    if m < 0 {
      m += 12
      y -= 1
    }
    let yearDelta = 399_999
    let baseDay = 365 * (1970 + yearDelta) + (1970 + yearDelta) / 4 - (1970 + yearDelta) / 100 + (1970 + yearDelta) / 400
    var dayFromYear = 365 * (y + yearDelta) + (y + yearDelta) / 4 - (y + yearDelta) / 100 + (y + yearDelta) / 400 - baseDay
    if y % 4 != 0 || (y % 100 == 0 && y % 400 != 0) {
      dayFromYear += [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334][m]
    } else {
      dayFromYear += [0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335][m]
    }
    return Double(dayFromYear - 1) + date.rounded(.towardZero)
  }

  static func makeTime(_ hour: Double, _ min: Double, _ sec: Double, _ ms: Double) -> Double {
    guard hour.isFinite, min.isFinite, sec.isFinite, ms.isFinite else { return .nan }
    return hour.rounded(.towardZero) * 3_600_000 + min.rounded(.towardZero) * 60_000 + sec.rounded(.towardZero) * 1000
      + ms.rounded(.towardZero)
  }
}
