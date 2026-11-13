import Foundation

// What the app makes and can make again lives in Paths.cache (~/Library/Caches/Nightcap):
//   trickplay/     preview thumbnail sheets          stills/   pictures chosen from them
//   thumbs/        frames for cards (fallback)       subs/     subtitles inside videos, as WebVTT
//   fingerprints/  audio fingerprints for detection  probe.json, complete.json: file details
// Each item goes when it hasn't been used for `keepMs`: using one marks it
// (its modification time, at most once a day), and `sweep` removes the rest.
// macOS may also empty the folder; everything in it is made again when needed.
// What can't be made again stays in Paths.data: progress, settings, the
// library, detection results and corrections, subtitles downloaded or made.

enum Cache {
  static let keepDays = 30
  static let keepMs: Int64 = Int64(keepDays) * dayMs
  static let dayMs: Int64 = 86_400_000

  /// What earlier versions kept in Paths.data.
  static let items = ["trickplay", "stills", "thumbs", "subs", "fingerprints", "probe.json"]

  /// Marks a cached file or folder as used now: its modification time, set
  /// at most once a day, so that it costs a stat.
  nonisolated static func touch(_ path: String, now: Int64 = nowMs()) {
    var st = stat()
    guard stat(path, &st) == 0, now - Scanner.mtimeMs(st) > dayMs else { return }
    utimes(path, nil)
  }

  /// The item an entry belongs to: "<fileId>-<sigHash>" for every entry made
  /// for one version of a video ("<id>-<sig>", "<id>-<sig>.json",
  /// "<id>-<sig>-card-480.jpg", "<id>-<sig>-head.fp", "<id>-<sig>.tmp"), so
  /// they go together; any other name is its own item.
  nonisolated static func item(_ name: String) -> String {
    let parts = name.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count >= 2, !parts[0].isEmpty, let sig = parts[1].split(separator: ".", maxSplits: 1).first, !sig.isEmpty else {
      return name
    }
    return "\(parts[0])-\(sig)"
  }

  /// Removes from `dir` the items none of whose entries was used (modified)
  /// in `keepMs`; returns the items removed.
  @discardableResult
  nonisolated static func sweep(_ dir: String, keepMs: Int64 = Cache.keepMs, now: Int64 = nowMs()) -> Set<String> {
    var last: [String: Int64] = [:]
    var entries: [String: [String]] = [:]
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
      var st = stat()
      guard lstat(join(dir, name), &st) == 0 else { continue }
      let key = item(name)
      last[key] = max(last[key] ?? .min, Scanner.mtimeMs(st))
      entries[key, default: []].append(name)
    }
    var removed = Set<String>()
    for (key, t) in last where now - t > keepMs {
      for name in entries[key]! { removeItem(join(dir, name)) }
      removed.insert(key)
    }
    return removed
  }

  /// Moves `names` from `from` to `to` where they aren't there yet (the same
  /// disk: a rename, instant). What can't be moved, or is there already, is
  /// removed: it can be made again.
  nonisolated static func moveOld(_ names: [String], from: String, to: String) {
    guard from != to else { return }
    for name in names {
      let a = join(from, name), b = join(to, name)
      var st = stat()
      guard lstat(a, &st) == 0 else { continue }
      if lstat(b, &st) == 0 || rename(a, b) != 0 { removeItem(a) }
    }
  }
}
