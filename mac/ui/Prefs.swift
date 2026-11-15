import Foundation

// The player's choices, remembered for every window (the pages kept them in
// localStorage): volume, mute, speed, audio language, the subtitles last
// chosen, each show's audio and subtitles, each video's subtitle timing
// nudges, and the picture.
@MainActor
enum Prefs {
  private static let d = UserDefaults.standard

  static let maxVolume = 2.0
  static let minSpeed = 0.25
  static let maxSpeed = 3.0

  static var volume: Double {
    get { min(maxVolume, max(0, (d.object(forKey: "volume") as? Double) ?? 1)) }
    set { d.set(newValue, forKey: "volume") }
  }

  static var muted: Bool {
    get { d.bool(forKey: "muted") }
    set { d.set(newValue, forKey: "muted") }
  }

  static var speed: Double {
    get {
      let s = (d.object(forKey: "speed") as? Double) ?? 1
      return s.isFinite && s != 0 ? min(maxSpeed, max(minSpeed, s)) : 1
    }
    set { d.set(newValue, forKey: "speed") }
  }

  /// The language of the audio track last chosen ("" for none).
  static var audioLang: String {
    get { d.string(forKey: "audioLang") ?? "" }
    set { d.set(newValue, forKey: "audioLang") }
  }

  /// The subtitles chosen (their label), or nil for off.
  static var subLabel: String? {
    get { d.string(forKey: "subLabel") }
    set { newValue == nil ? d.removeObject(forKey: "subLabel") : d.set(newValue, forKey: "subLabel") }
  }

  /// The last subtitles shown, for C to turn back on.
  static var lastSubLabel: String {
    get { d.string(forKey: "lastSubLabel") ?? "" }
    set { d.set(newValue, forKey: "lastSubLabel") }
  }

  /// How the picture is shown. Settings reads and writes the same key (players
  /// follow it through UserDefaults.didChangeNotification).
  static let pictureKey = "picture"
  static let defaultPicture = PictureMode.sharper

  static var picture: PictureMode {
    get { d.string(forKey: pictureKey).flatMap(PictureMode.init(rawValue:)) ?? defaultPicture }
    set { d.set(newValue.rawValue, forKey: pictureKey) }
  }

  // ---- Subtitle timing, per video and track ("<fileId>:<subId>"), the latest 300 -----------

  private struct Delay: Codable {
    var key: String
    var seconds: Double
  }

  private static var delays: [Delay] {
    get {
      guard let data = d.data(forKey: "subDelays"), let list = try? JSONDecoder().decode([Delay].self, from: data) else { return [] }
      return list
    }
    set { d.set(try? JSONEncoder().encode(newValue), forKey: "subDelays") }
  }

  static func subDelay(_ key: String) -> Double {
    delays.last { $0.key == key }?.seconds ?? 0
  }

  static func setSubDelay(_ key: String, _ seconds: Double) {
    var list = delays.filter { $0.key != key }
    if seconds != 0 { list.append(Delay(key: key, seconds: seconds)) }
    if list.count > 300 { list.removeFirst(list.count - 300) }
    delays = list
  }

  // ---- Each title's picture, as Tune Picture chose it (PictureTune) ---------------------------

  static var pictureTunes: [String: PictureTune.Result] {
    get {
      guard let data = d.data(forKey: "pictureTunes"),
        let all = try? JSONDecoder().decode([String: PictureTune.Result].self, from: data)
      else { return [:] }
      return all
    }
    set { d.set(try? JSONEncoder().encode(newValue), forKey: "pictureTunes") }
  }

  // ---- Each title's loudness, as Level Loudness measured it (Loudness) -------------------------

  static var loudness: [String: Loudness.Result] {
    get {
      guard let data = d.data(forKey: "loudness"),
        let all = try? JSONDecoder().decode([String: Loudness.Result].self, from: data)
      else { return [:] }
      return all
    }
    set { d.set(try? JSONEncoder().encode(newValue), forKey: "loudness") }
  }

  // ---- Each show's audio and subtitles (TrackChoice), the latest 500 shows ------------------

  private static var showTrackList: [ShowTracks] {
    get {
      guard let data = d.data(forKey: "showTracks"), let list = try? JSONDecoder().decode([ShowTracks].self, from: data) else { return [] }
      return list
    }
    set { d.set(try? JSONEncoder().encode(newValue), forKey: "showTracks") }
  }

  /// What show `show` plays with; the first time, the choices last made anywhere, kept for it from now on.
  static func showTracks(_ show: String) -> ShowTracks {
    if let t = showTrackList.last(where: { $0.show == show }) { return t }
    let t = ShowTracks(
      show: show, audio: audioLang.isEmpty ? nil : AudioChoice(lang: audioLang), sub: subLabel, lastSub: lastSubLabel)
    setShowTracks(t)
    return t
  }

  /// What show `show` plays with, if it has played; nothing is kept by asking.
  static func savedShowTracks(_ show: String) -> ShowTracks? {
    showTrackList.last(where: { $0.show == show })
  }

  static func setShowTracks(_ t: ShowTracks) {
    showTrackList = ShowTracks.keep(t, in: showTrackList)
  }
}
