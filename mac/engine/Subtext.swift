import Foundation

// Subtitle text helpers: decoding, SRT -> WebVTT, and removing the adverts and
// credits that uploaders and torrent groups put into subtitle files.

enum Subtext {
  /// Bytes to text: UTF-16 with a byte order mark, UTF-8, else Windows-1252.
  static func decodeText(_ data: Data) -> String {
    let bytes = [UInt8](data)
    if bytes.count >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe { return utf16(bytes[2...], littleEndian: true) }
    if bytes.count >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff { return utf16(bytes[2...], littleEndian: false) }
    let body = bytes.count >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf ? Array(bytes[3...]) : bytes
    if let s = String(bytes: body, encoding: .utf8) { return s }
    return windows1252(bytes)
  }

  private static func utf16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> String {
    var units: [UInt16] = []
    units.reserveCapacity(bytes.count / 2)
    var i = bytes.startIndex
    while i + 1 < bytes.endIndex {
      let a = UInt16(bytes[i]), b = UInt16(bytes[i + 1])
      units.append(littleEndian ? a | b << 8 : a << 8 | b)
      i += 2
    }
    var s = String(decoding: units, as: UTF16.self)
    if i < bytes.endIndex { s += "\u{FFFD}" }  // a trailing half code unit
    return s
  }

  /// The WHATWG windows-1252 decoder (what TextDecoder does).
  private static let cp1252: [UInt32] = [
    0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
    0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
  ]
  private static func windows1252(_ bytes: [UInt8]) -> String {
    var s = String.UnicodeScalarView()
    for b in bytes {
      let v = b >= 0x80 && b < 0xa0 ? cp1252[Int(b) - 0x80] : UInt32(b)
      s.append(Unicode.Scalar(v)!)
    }
    return String(s)
  }

  private static let bomRe = Re("^\u{FEFF}")
  private static let crlfRe = Re(#"\r\n?"#)
  private static let srtTimeRe = Re("([0-9]{1,2}:[0-9]{2}:[0-9]{2}),([0-9]{3})")

  static func srtToVtt(_ text: String) -> String {
    "WEBVTT\n\n" + srtTimeRe.replace(crlfRe.replace(bomRe.replace(text, "", global: false), "\n"), "$1.$2")
  }

  /// A leading byte order mark removed (text.replace(/^\uFEFF/, '')).
  static func dropBOM(_ text: String) -> String { bomRe.replace(text, "", global: false) }

  private static let crRe = Re(#"\r"#)
  private static let sniffers: [(Re, String)] = [
    (Re("^WEBVTT"), "vtt"),
    (Re(#"^[0-9]{1,2}:[0-9]{2}:[0-9]{2}[,.][0-9]{1,3}[ \t]*-->"#, "m"), "srt"),
    (Re(#"^\[Script Info\]"#, "i"), "ass"),
    (Re(#"^\{[0-9]+\}\{[0-9]*\}"#), "microdvd"),
    (Re("^<SAMI>", "i"), "sami"),
    (Re(#"^\[[0-9]+\]\[[0-9]+\]"#), "mpl2"),
  ]

  /// What kind of subtitle text this is, from its content. Names are ffmpeg's
  /// demuxers, so a downloaded file is never left to ffmpeg's format guessing.
  static func sniffFormat(_ text: String) -> String? {
    let t = crRe.replace(dropBOM(text), "").jsTrimmedStart
    for (i, (re, name)) in sniffers.enumerated() {
      if re.test(i == 1 ? t.jsSlice(0, 2000) : t) { return name }
    }
    return nil
  }

  private static let timeRe = Re(#"^(?:([0-9]+):)?([0-9]{1,2}):([0-9]{1,2}(?:[.,][0-9]+)?)"#)

  static func parseTime(_ s: String) -> Double {
    guard let m = timeRe.match(s.jsTrimmed) else { return .nan }
    let h = m[1].map(jsNumberValue) ?? 0
    return h * 3600 + jsNumberValue(m[2]!) * 60 + jsNumberValue(m[3]!.replacingOccurrences(of: ",", with: "."))
  }

  /// In doubles, as JavaScript computed it, so absurd or broken times print as they did.
  static func fmtTime(_ t: Double) -> String {
    let ms = jsMax(0, jsRound(t * 1000))
    let h = (ms / 3_600_000).rounded(.down)
    let m = (ms / 60000).rounded(.down).truncatingRemainder(dividingBy: 60)
    let s = (ms / 1000).rounded(.down).truncatingRemainder(dividingBy: 60)
    func pad(_ n: Double, _ w: Int = 2) -> String { jsNumber(n).padStart(w, "0") }
    return "\(pad(h)):\(pad(m)):\(pad(s)).\(pad(ms.truncatingRemainder(dividingBy: 1000), 3))"
  }

  struct Block {
    var raw: String
    var head: [String] = []
    var start = Double.nan
    var end = Double.nan
    var settings = ""
    /// nil for blocks that are not cues (the header, notes, styles).
    var text: String?
  }

  private static let blankLinesRe = Re(#"\n{2,}"#)
  private static let spaceRunRe = Re(#"\s+"#)

  /// Splits WebVTT into blocks; cue blocks get start, end, timing and text.
  static func blocks(_ vtt: String) -> [Block] {
    blankLinesRe.split(crRe.replace(vtt, "")).map { raw in
      let lines = raw.jsSplit("\n")
      guard let i = lines.firstIndex(where: { $0.jsIncludes("-->") }) else { return Block(raw: raw) }
      let parts = lines[i].jsSplit("-->")
      let a = parts[0], b = parts.count > 1 ? parts[1] : ""
      let fields = spaceRunRe.split(b.jsTrimmed)
      return Block(
        raw: raw, head: Array(lines[..<i]), start: parseTime(a), end: parseTime(fields[0]),
        settings: fields.dropFirst().joined(separator: " "), text: lines[(i + 1)...].joined(separator: "\n"))
    }
  }

  // Removed wherever they appear: provider and uploader adverts.
  private static let always = [
    Re(#"open-?subtitles|osdb\.link"#, "i"),
    Re("advertise your (?:product|brand)|become (?:a )?vip member|rate this subtitle|free browser extension", "i"),
    Re("clearway law|leave reviews for lawyers", "i"),
    Re(#"addic7ed|subscene|podnapisi|yifysubtitles|subdl\.com|tvsubtitles|subtitlecat|subs?hub|explosiveskull|sub-?scene"#, "i"),
  ]
  // Credits and links: only removed near the start or the end, where uploaders put them.
  private static let atEdges = [
    Re(#"\b(?:subtitles?|subs|captions?|captioned|captioning|synced|synchroni[sz]ed|re-?sync(?:ed)?|corrections?|corrected|transcript)\b(?:\s+(?:and|&)\s+\w+)?\s+by\b"#, "i"),
    Re(#"\bwww\.|https?:\/\/|\b[a-z0-9-]+\.(?:com|org|net|info|tv|io|me|ru|ro|to|cc)\b"#, "i"),
  ]
  private static let edgeSeconds = 240.0
  private static let tagsRe = Re(#"<[^>]+>|\{\\[^}]*\}"#)
  private static let trailingNewlinesRe = Re(#"\n*$"#)

  static func stripAds(_ vtt: String) -> (vtt: String, removed: [String]) {
    let all = blocks(vtt)
    let lastEnd = Swift.max(0, all.filter { $0.text != nil && $0.end.isFinite }.map(\.end).max() ?? 0)
    var removed: [String] = []
    let kept = all.filter { b in
      guard let bt = b.text else { return true }
      let text = tagsRe.replace(bt, " ")
      let nearEdge = b.start < edgeSeconds || b.start > lastEnd - edgeSeconds
      let ad = always.contains { $0.test(text) } || (nearEdge && atEdges.contains { $0.test(text) })
      if ad { removed.append(spaceRunRe.replace(bt, " ").jsTrimmed) }
      return !ad
    }
    return (trailingNewlinesRe.replace(kept.map(\.raw).joined(separator: "\n\n"), "\n", global: false), removed)
  }

  /// Moves every cue: t -> t * scale + offset (fixes subtitles timed for another
  /// release, e.g. a constant delay or 25 vs 23.976 fps), each part of subtitles
  /// timed for another cut by its own offset.
  static func retime(_ vtt: String, _ timing: SubTiming?) -> String {
    let offset = timing?.offset ?? 0, scale = timing?.scale ?? 1
    if (offset == 0 || offset.isNaN) && scale == 1 && (timing?.parts.count ?? 0) < 2 { return vtt }
    let out = blocks(vtt).compactMap { b -> String? in
      guard let text = b.text else { return b.raw }
      var shift = timing?.offset(at: b.start) ?? 0
      if shift.isNaN { shift = 0 }
      let s = b.start * scale + shift
      let e = b.end * scale + shift
      if e <= 0 { return nil }
      let timingLine = "\(fmtTime(jsMax(0, s))) --> \(fmtTime(e))\(b.settings.isEmpty ? "" : " \(b.settings)")"
      return (b.head + [timingLine, text]).joined(separator: "\n")
    }
    return trailingNewlinesRe.replace(out.joined(separator: "\n\n"), "\n", global: false)
  }

  /// Cue intervals in seconds, for syncing against the audio.
  static func cueTimes(_ vtt: String) -> [(Double, Double)] {
    blocks(vtt).compactMap { b in
      guard let text = b.text, !text.jsTrimmed.isEmpty, b.end > b.start else { return nil }
      return (b.start, b.end)
    }
  }
}
