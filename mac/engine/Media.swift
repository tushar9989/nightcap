import Foundation

// What is inside each video (ffprobe, cached), card pictures, and the
// subtitles that come with a file (next to it or inside it).

/// A subtitle track the player can show.
struct SubtitleTrack: Equatable, Identifiable {
  /// x<N> file next to the video, e<N> embedded track, d<N> downloaded.
  var id: String
  var label: String
  /// "file", "embedded" or "online".
  var source: String
  var lang: String? = nil
  var release: String? = nil
  var hashMatch: Bool? = nil
  /// The timing correction in use, if any.
  var sync: SubTiming? = nil
}

@MainActor
final class Media {
  static let probeVersion = 2
  let probeStore = JsonStore(Paths.data("probe.json"), defaults: ProbeData())
  private var inflight: [String: Task<ProbeInfo?, Never>] = [:]
  private let probeLimit = Limiter(3)

  func flush() { probeStore.flush() }

  func cachedProbe(_ f: LibraryFile) -> ProbeInfo? {
    guard let c = probeStore.data.files[f.id], c.sig == fileSig(f), c.v == Media.probeVersion else { return nil }
    return c.info
  }

  /// Codec, duration and track info for a file (cached until the file changes).
  func probe(_ f: LibraryFile) async -> ProbeInfo? {
    if let hit = cachedProbe(f) { return hit }
    guard let ffprobe = Tools.ffprobe else { return nil }
    if let running = inflight[f.id] { return await running.value }
    let task = Task { () -> ProbeInfo? in
      let info = await probeLimit.run { () -> ProbeInfo? in
        guard let r = try? await runTool(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", f.path], timeout: 60),
          r.code == 0
        else { return nil }
        return Media.parseProbe(r.stdout)
      }
      if let info {
        probeStore.data.files[f.id] = ProbeEntry(sig: fileSig(f), v: Media.probeVersion, info: info)
        probeStore.save()
      }
      inflight[f.id] = nil
      return info
    }
    inflight[f.id] = task
    return await task.value
  }

  nonisolated static func parseProbe(_ data: Data) -> ProbeInfo? {
    guard let j = JSON.parse(String(decoding: data, as: UTF8.self)) as? [String: Any] else { return nil }
    let streams = j["streams"] as? [[String: Any]] ?? []
    let format = j["format"] as? [String: Any]
    func str(_ v: Any?) -> String? { v as? String }
    func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    func truthy(_ v: Any?) -> Bool {
      if let n = v as? NSNumber { return n.doubleValue != 0 }
      if let s = v as? String { return !s.isEmpty }
      return v != nil && !(v is NSNull)
    }
    func number(_ v: Any?) -> Double {
      if let n = v as? NSNumber { return n.doubleValue }
      if let s = v as? String { let x = jsNumberValue(s); return x.isNaN ? 0 : x }
      return 0
    }
    func tag(_ s: [String: Any], _ k: String) -> String {
      let tags = s["tags"] as? [String: Any]
      let a = str(tags?[k]) ?? "", b = str(tags?[k.uppercased()]) ?? ""
      return a.isEmpty ? b : a
    }
    let v = streams.first { str($0["codec_type"]) == "video" && !truthy(($0["disposition"] as? [String: Any])?["attached_pic"]) }
    var duration = number(format?["duration"])
    if duration == 0 { duration = number(v?["duration"]) }
    let audio = streams.filter { str($0["codec_type"]) == "audio" }.enumerated().map { i, s in
      ProbeInfo.Audio(
        index: i, codec: str(s["codec_name"]), channels: int(s["channels"]), lang: tag(s, "language"), title: tag(s, "title"),
        default: truthy((s["disposition"] as? [String: Any])?["default"]))
    }
    let subs = streams.filter { str($0["codec_type"]) == "subtitle" }.enumerated().map { i, s in
      ProbeInfo.Sub(
        index: i, codec: str(s["codec_name"]), lang: tag(s, "language"), title: tag(s, "title"),
        forced: truthy((s["disposition"] as? [String: Any])?["forced"]))
    }
    return ProbeInfo(
      duration: duration,
      format: str(format?["format_name"]) ?? "",
      video: v.map {
        ProbeInfo.Video(
          codec: str($0["codec_name"]), profile: str($0["profile"]) ?? "", pixFmt: str($0["pix_fmt"]) ?? "",
          width: int($0["width"]), height: int($0["height"]))
      },
      audio: audio, subs: subs)
  }

  // ---- Thumbnails ------------------------------------------------------------------

  private let thumbDir = ensureDir(Paths.data("thumbs"))
  private let thumbLimit = Limiter(2)
  private var thumbInflight: [String: Task<String?, Never>] = [:]

  /// A frame from `at` (0...1) of the way through the video, `width` wide (a JPEG path).
  func frameThumb(_ f: LibraryFile, at: Double = 0.3, width: Int = 480) async -> String? {
    let out = join(thumbDir, "\(f.id)-\(sigHash(f))-\(width)-\(Int(jsRound(at * 100))).jpg")
    if fileExists(out) { return out }
    guard let ffmpeg = Tools.ffmpeg else { return nil }
    if let running = thumbInflight[out] { return await running.value }
    let task = Task { () -> String? in
      let made = await thumbLimit.run { () -> String? in
        let info = await probe(f)
        if let info, info.video == nil { return nil }
        let t = (info?.duration ?? 0) > 0 ? info!.duration * at : 60
        let tmp = "\(out).tmp.jpg"
        let r = try? await runTool(ffmpeg, [
          "-nostdin", "-hide_banner", "-loglevel", "error", "-ss", toFixed(t, 2), "-i", f.path, "-map", "0:v:0",
          "-vf", "thumbnail=8,scale=\(width):-2", "-frames:v", "1", "-q:v", "3", "-y", tmp,
        ], timeout: 60)
        guard r?.code == 0 else {
          removeItem(tmp)
          return nil
        }
        return rename(tmp, out) == 0 ? out : nil
      }
      thumbInflight[out] = nil
      return made
    }
    thumbInflight[out] = task
    return await task.value
  }

  // ---- Subtitles -------------------------------------------------------------------

  private let subDir = ensureDir(Paths.data("subs"))
  private static let textSubCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"]
  static let langNames = ["eng": "English", "en": "English", "spa": "Spanish", "fre": "French", "fra": "French", "ger": "German", "deu": "German", "ita": "Italian", "por": "Portuguese", "jpn": "Japanese", "kor": "Korean", "chi": "Chinese", "zho": "Chinese", "hin": "Hindi", "rus": "Russian", "ara": "Arabic", "dut": "Dutch", "nld": "Dutch", "swe": "Swedish", "nor": "Norwegian", "dan": "Danish", "fin": "Finnish", "pol": "Polish", "tur": "Turkish"]

  /// Subtitles next to the file and text subtitles inside it.
  func listSubtitles(_ f: LibraryFile) async -> [SubtitleTrack] {
    var out = f.subs.enumerated().map { SubtitleTrack(id: "x\($0.offset)", label: $0.element.label, source: "file") }
    for s in await probe(f)?.subs ?? [] {
      guard let codec = s.codec, Media.textSubCodecs.contains(codec) else { continue }
      let lang = Media.langNames[s.lang] ?? s.lang
      let parts = [lang, !s.title.isEmpty && s.title != lang ? s.title : "", s.forced ? "Forced" : ""].filter { !$0.isEmpty }
      let label = parts.isEmpty ? "Track \(s.index + 1)" : parts.joined(separator: " · ")
      out.append(SubtitleTrack(id: "e\(s.index)", label: label, source: "embedded"))
    }
    return out
  }

  /// A subtitle next to the file or inside it, as WebVTT text.
  func subtitleVtt(_ f: LibraryFile, _ subId: String) async -> String? {
    let kind = subId.first
    guard let index = Int(subId.dropFirst()) else { return nil }
    if kind == "x" {
      guard index >= 0, index < f.subs.count else { return nil }
      let sub = f.subs[index]
      let ext = extname(sub.path).lowercased()
      if ext == ".srt" || ext == ".vtt" {
        guard let data = FileManager.default.contents(atPath: sub.path) else { return nil }
        let text = Subtext.decodeText(data)
        return ext == ".vtt" ? Subtext.dropBOM(text) : Subtext.srtToVtt(text)
      }
    }
    guard let ffmpeg = Tools.ffmpeg else { return nil }
    let cache = join(subDir, "\(f.id)-\(sigHash(f))-\(subId).vtt")
    if let data = FileManager.default.contents(atPath: cache) { return String(decoding: data, as: UTF8.self) }
    let args = kind == "x"
      ? ["-nostdin", "-loglevel", "error", "-i", f.subs[index].path, "-f", "webvtt", "pipe:1"]
      : ["-nostdin", "-loglevel", "error", "-i", f.path, "-map", "0:s:\(index)", "-f", "webvtt", "pipe:1"]
    guard let r = try? await runTool(ffmpeg, args, timeout: 180), r.code == 0 else { return nil }
    FileManager.default.createFile(atPath: cache, contents: r.stdout)
    return String(decoding: r.stdout, as: UTF8.self)
  }

  /// Subtitle text (SRT, WebVTT, ASS/SSA, MicroDVD, SAMI, MPL2) as WebVTT.
  func textToVtt(_ text: String, ext: String = "") async -> String? {
    let fmt = Subtext.sniffFormat(text)
    if fmt == "vtt" { return Subtext.dropBOM(text) }
    if fmt == "srt" || (fmt == nil && ext == ".srt") { return Subtext.srtToVtt(text) }
    guard let fmt, let ffmpeg = Tools.ffmpeg else { return nil }
    let tmp = join(subDir, "convert-\(getpid())-\(nowMs()).txt")
    FileManager.default.createFile(atPath: tmp, contents: Data(text.utf8))
    defer { removeItem(tmp) }
    guard let r = try? await runTool(ffmpeg, ["-nostdin", "-loglevel", "error", "-f", fmt, "-i", tmp, "-f", "webvtt", "pipe:1"], timeout: 60),
      r.code == 0
    else { return nil }
    return String(decoding: r.stdout, as: UTF8.self)
  }
}
