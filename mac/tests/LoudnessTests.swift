import Foundation

// Level Loudness (Loudness): ffmpeg's EBU R128 summary read, the gain each video
// gets, and real measurements of sound at known levels.

@MainActor
func loudnessTests(_ t: Tests) {
  t.test("loudness: the integrated loudness is read from ffmpeg's summary") {
    let summary = """
      [Parsed_ebur128_2 @ 0x1] Summary:

        Integrated loudness:
          I:         -24.5 LUFS
          Threshold: -35.1 LUFS

        Loudness range:
          LRA:        12.3 LU
      """
    try expectEqual(Loudness.parse(summary), -24.5)
    try expectEqual(Loudness.parse("no summary"), nil)
  }

  t.test("loudness: gain takes a video to the target, within ±12 dB") {
    try expect(abs(Loudness.gain(measured: -28.2, target: -24) - 4.2) < 1e-9)
    try expectEqual(Loudness.gain(measured: -20, target: -24), -4)
    try expectEqual(Loudness.gain(measured: -50, target: -24), 12, "capped")
    let r = Loudness.Result(files: ["a": -28, "b": -26, "c": -22], target: -24, measuredAt: 0)
    try expectEqual(r.gain("a"), 4)
    try expectEqual(r.typical, -26)
    try expectEqual(r.gain("new"), 2, "not measured yet: the title's typical level")
    try expectEqual(Loudness.Result(files: [:], target: -24, measuredAt: 0).gain("x"), 0)
  }

  t.test("loudness: measured as EBU R128 on the stereo mix, 6 dB apart reads 6 LU apart") {
    let dir = tempDir("loud")
    let a = join(dir, "a.mkv"), b = join(dir, "b.mkv"), mute = join(dir, "mute.mkv")
    // BS.1770: a 1 kHz sine peaking at -23 dBFS in both channels reads -23 LUFS (ffmpeg's sine
    // peaks at 1/8, -18 dBFS; 5 dB less is -23).
    try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=20", "-af", "volume=-5dB,pan=stereo|c0=c0|c1=c0", "-c:a", "flac", a])
    try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=20", "-af", "volume=-11dB,pan=stereo|c0=c0|c1=c0", "-c:a", "flac", b])
    try await ffmpeg(["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", "10", "-c:a", "flac", mute])
    let la = try await Loudness.measure(a), lb = try await Loudness.measure(b)
    try expect(la != nil && lb != nil)
    try expect(abs(la! - -23) < 0.5, "a: \(la!)")
    try expect(abs((la! - lb!) - 6) < 0.2, "\(la!) vs \(lb!)")
    try expectEqual(try await Loudness.measure(mute), nil, "silence")
    let r = try await Loudness.level([(id: "a", path: a), (id: "m", path: mute)])
    try expectEqual(r.files.count, 1)
  }
}
