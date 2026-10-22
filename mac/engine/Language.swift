import Foundation

// Language names in English, as `new Intl.DisplayNames(['en'], {type:
// 'language'})` gave them in the pages, which ran in WebKit: the code is
// checked and canonicalized the way JavaScriptCore does it, and the names come
// from the system's ICU. Matched JavaScriptCore on 150k codes. (Node, which
// named downloaded subtitles, ships its own ICU; of the subtitle languages,
// four names differ: zh-CN was "Chinese (China)", now "Chinese (China
// mainland)"; zh-HK "Chinese (Hong Kong SAR China)", now "Chinese (Hong
// Kong)"; se "Northern Sami", now "North Sámi"; und "root", now "Unknown language".)

/// `displayNames.of(code) || code`, and the code itself where that throws.
func languageName(_ code: String) -> String {
  guard let name = LanguageNames.shared.of(code), !name.isEmpty else { return code }
  return name
}

final class LanguageNames: @unchecked Sendable {
  static let shared = LanguageNames()

  private let lock = NSLock()
  private var cache: [String: String?] = [:]
  private let names: OpaquePointer?

  private init() {
    // UDISPCTX_DIALECT_NAMES, _CAPITALIZATION_FOR_STANDALONE, _LENGTH_FULL, _NO_SUBSTITUTE
    var contexts: [Int32] = [0x001, 0x104, 0x200, 0x301]
    var status: UErrorCode = 0
    let names = uldn_openForContext("en", &contexts, Int32(contexts.count), &status)
    self.names = status <= 0 ? names : nil
  }

  /// Intl.DisplayNames' of(code): nil where it throws.
  func of(_ code: String) -> String? {
    // Only ASCII codes are valid, and for those Swift's string keys compare as JavaScript's do.
    guard code.utf8.allSatisfy({ $0 < 0x80 }), LanguageNames.isLanguageId(code) else { return nil }
    lock.lock()
    defer { lock.unlock() }
    if let hit = cache[code] { return hit }
    let name = lookUp(code)
    cache[code] = name
    return name
  }

  private func lookUp(_ code: String) -> String? {
    guard let names, let canonical = LanguageNames.canonicalize(code) else { return nil }
    var cap: Int32 = 128
    while true {
      var buf = [UChar](repeating: 0, count: Int(cap))
      var status: UErrorCode = 0
      let n = uldn_localeDisplayName(names, canonical, &buf, cap, &status)
      if status == 15 /* U_BUFFER_OVERFLOW_ERROR */ && n > cap {
        cap = n
        continue
      }
      // No name for it: the canonical code stands in (fallback "code").
      if status == 1 /* U_ILLEGAL_ARGUMENT_ERROR */ { return canonical }
      guard status <= 0 else { return nil }
      return String(decoding: buf[..<Int(min(n, cap))], as: UTF16.self)
    }
  }

  /// CanonicalizeUnicodeLocaleId as JavaScriptCore does it on Apple systems:
  /// tag to ICU locale ID (all of it must parse), Apple's canonical form, back to a tag.
  private static func canonicalize(_ tag: String) -> String? {
    var parsed: Int32 = 0
    guard let id = icuString({ uloc_forLanguageTag(tag, $0, $1, &parsed, $2) }), parsed == Int32(tag.utf8.count),
      let canonical = icuString({ ualoc_canonicalForm(id, $0, $1, $2) })
    else { return nil }
    return icuString({ uloc_toLanguageTag(canonical, $0, $1, 0, $2) })
  }

  /// An ICU call that fills a char buffer, with a bigger buffer when it asks for one.
  private static func icuString(_ call: (UnsafeMutablePointer<CChar>, Int32, UnsafeMutablePointer<UErrorCode>) -> Int32) -> String? {
    var cap: Int32 = 64
    while true {
      var buf = [CChar](repeating: 0, count: Int(cap) + 1)
      var status: UErrorCode = 0
      let n = buf.withUnsafeMutableBufferPointer { call($0.baseAddress!, cap, &status) }
      if status == 15 /* U_BUFFER_OVERFLOW_ERROR */ && n > cap {
        cap = n
        continue
      }
      guard status <= 0 else { return nil }
      return String(cString: buf)
    }
  }

  /// The unicode_language_id production, as ECMA-402 restricts it (a language
  /// subtag first, "-" only, no "root"), with no variant twice.
  static func isLanguageId(_ code: String) -> Bool {
    func isAlpha(_ b: UInt8) -> Bool { (b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A }
    func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    let subtags = code.utf8.split(separator: 0x2D, omittingEmptySubsequences: false).map(Array.init)
    let first = subtags[0]
    guard [2, 3, 5, 6, 7, 8].contains(first.count), first.allSatisfy(isAlpha) else { return false }
    var i = 1
    if i < subtags.count, subtags[i].count == 4, subtags[i].allSatisfy(isAlpha) { i += 1 }
    if i < subtags.count,
      (subtags[i].count == 2 && subtags[i].allSatisfy(isAlpha)) || (subtags[i].count == 3 && subtags[i].allSatisfy(isDigit))
    {
      i += 1
    }
    var variants: Set<[UInt8]> = []
    while i < subtags.count {
      let v = subtags[i]
      guard v.allSatisfy({ isAlpha($0) || isDigit($0) }), (5...8).contains(v.count) || (v.count == 4 && isDigit(v[0])) else { return false }
      guard variants.insert(v.map { isAlpha($0) ? $0 | 0x20 : $0 }).inserted else { return false }
      i += 1
    }
    return true
  }
}
