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

  t.test("loudness: the audio track asked for is measured, and only it is levelled") {
    // Fullmetal Alchemist: a louder first track (-20.5 LUFS) and a quieter second one (-27.7),
    // the one played; measuring only the first turned the played one down instead of up.
    let dir = tempDir("loud2")
    let two = join(dir, "two.mkv")
    try await ffmpeg([
      "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=20",
      "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=20",
      "-filter_complex", "[0:a]volume=-2dB,pan=stereo|c0=c0|c1=c0[a];[1:a]volume=-10dB,pan=stereo|c0=c0|c1=c0[b]",
      "-map", "[a]", "-map", "[b]", "-c:a", "flac", two])
    let first = try await Loudness.level([(id: "two", path: two)], track: 0)
    let second = try await Loudness.level([(id: "two", path: two)], track: 1)
    let l0 = try unwrapLoud(first.files["two"]), l1 = try unwrapLoud(second.files["two"])
    try expect(abs(l0 - -20) < 0.5 && abs(l1 - -28) < 0.5, "\(l0), \(l1)")
    try expectEqual(second.track, 1)
    try expect(second.gain("two", track: 1) > 3.5, "the quieter track turned up: \(second.gain("two", track: 1))")
    try expectEqual(second.gain("two", track: 0), 0, "a track not measured: as it is")
    try expect(second.gain("new", track: 1) > 3.5, "not measured yet: the title's typical level")
    let back = try JSONDecoder().decode(Loudness.Result.self, from: try JSONEncoder().encode(second))
    try expectEqual(back, second)
  }

  t.test("loudness: a result from before the track was asked measured the first") {
    let json = #"{"files":{"a":-20,"b":-22},"target":-24,"measuredAt":0}"#
    let old = try JSONDecoder().decode(Loudness.Result.self, from: Data(json.utf8))
    try expectEqual(old.measuredTrack, 0)
    try expectEqual(old.gain("a"), -4)
    try expectEqual(old.gain("a", track: 1), 0, "another track: left as it is")
    try expectEqual(old.typical, -21)
  }
}

private func unwrapLoud<T>(_ v: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
  guard let v else { throw TestFailure(description: "nil at \(file):\(line)") }
  return v
}
