import Foundation

// Level Loudness: every episode of a title played at the same loudness.
//
// Each video's integrated loudness is measured as EBU R128 / ITU-R BS.1770 defines
// it (LUFS), on the stereo mix the player plays (ffmpeg's ebur128 on the same
// downmix as ncdecoder.c). Playing, the player adds the gain that takes it to
// `target`, -24 LUFS: ATSC A/85, the loudness US television is delivered at.
// The gain is capped at ±`maxGain` dB; the player's limiter keeps the peaks a
// louder level brings under full scale. A video of the title not measured yet
// (added since) gets the title's typical level, the median of those measured.

enum Loudness {
  static let target = -24.0
  static let maxGain = 12.0
  /// Quieter than this is silence, or no sound to measure.
  static let floor = -70.0

  struct Result: Codable, Equatable {
    /// Integrated loudness of each video measured (file id: LUFS).
    var files: [String: Double]
    var target: Double
    var measuredAt: Int64

    /// The median loudness measured: what a video not measured yet is taken to be.
    var typical: Double? {
      let v = files.values.sorted()
      guard !v.isEmpty else { return nil }
      return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    /// The gain (dB) for a video of this title.
    func gain(_ fid: String) -> Double {
      guard let l = files[fid] ?? typical else { return 0 }
      return Loudness.gain(measured: l, target: target)
    }
  }

  static func gain(measured: Double, target: Double = target) -> Double {
    max(-maxGain, min(maxGain, target - measured))
  }

  /// The integrated loudness in ffmpeg's ebur128 summary.
  static func parse(_ stderr: String) -> Double? {
    // "Integrated loudness:\n    I:         -24.5 LUFS"
    guard let r = stderr.range(of: "Integrated loudness:") else { return nil }
    let rest = stderr[r.upperBound...]
    guard let i = rest.range(of: "I:") else { return nil }
    let num = rest[i.upperBound...].drop { $0 == " " }.prefix { "-+.0123456789".contains($0) }
    return Double(num)
  }

  /// One video's integrated loudness (LUFS); nil without sound to measure.
  static func measure(_ path: String) async throws -> Double? {
    guard let ffmpeg = Tools.ffmpeg else { throw EngineError("ffmpeg is not installed", 500) }
    let r = try await runTool(
      ffmpeg, ["-nostdin", "-nostats", "-v", "info", "-i", path, "-vn", "-sn", "-dn", "-map", "0:a:0",
               "-af", "aresample=48000,aformat=sample_fmts=flt:channel_layouts=stereo,ebur128=framelog=quiet",
               "-f", "null", "-"],
      timeout: 1800, background: true, pausable: true, maxErr: 200_000)
    guard r.code == 0, let l = parse(r.stderr), l > floor else { return nil }
    return l
  }

  /// Measures the title's videos (file id, path). `progress` gets videos done of all.
  static func level(
    _ files: [(id: String, path: String)], progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }
  ) async throws -> Result {
    var out: [String: Double] = [:]
    for (i, f) in files.enumerated() {
      if let l = try await measure(f.path) { out[f.id] = l }
      await progress(i + 1, files.count)
    }
    return Result(files: out, target: target, measuredAt: Int64(Date().timeIntervalSince1970 * 1000))
  }
}
