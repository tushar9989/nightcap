import CryptoKit
import Foundation

// Shared helpers: where data lives, ids, sorting, JSON files on disk, and
// running ffmpeg.

enum Paths {
  /// The app's data: progress, the library, detection results, previews,
  /// subtitles. DATA_DIR overrides it (tests).
  static let data: String = {
    if let d = ProcessInfo.processInfo.environment["DATA_DIR"], !d.isEmpty {
      return URL(fileURLWithPath: (d as NSString).expandingTildeInPath).standardizedFileURL.path
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("Nightcap").path
  }()

  static func data(_ parts: String...) -> String {
    parts.reduce(data) { ($0 as NSString).appendingPathComponent($1) }
  }

  static let home = NSHomeDirectory()
}

func join(_ parts: String...) -> String {
  parts.dropFirst().reduce(parts[0]) { ($0 as NSString).appendingPathComponent($1) }
}

func basename(_ p: String) -> String { (p as NSString).lastPathComponent }
func dirname(_ p: String) -> String {
  let d = (p as NSString).deletingLastPathComponent
  return d.isEmpty ? "." : d
}
/// Node's path.extname, step for step on UTF-16 units: ".mkv", or "" (a
/// leading dot alone is not an extension).
func extname(_ p: String) -> String {
  let u = Array(p.utf16)
  var startDot = -1, startPart = 0, end = -1, matchedSlash = true, preDotState = 0
  var i = u.count - 1
  while i >= 0 {
    let code = u[i]
    if code == 0x2F {
      if !matchedSlash {
        startPart = i + 1
        break
      }
      i -= 1
      continue
    }
    if end == -1 {
      matchedSlash = false
      end = i + 1
    }
    if code == 0x2E {
      if startDot == -1 { startDot = i } else if preDotState != 1 { preDotState = 1 }
    } else if startDot != -1 {
      preDotState = -1
    }
    i -= 1
  }
  if startDot == -1 || end == -1 || preDotState == 0
    || (preDotState == 1 && startDot == end - 1 && startDot == startPart + 1)
  {
    return ""
  }
  return String(decoding: u[startDot..<end], as: UTF16.self)
}

@discardableResult
func ensureDir(_ dir: String) -> String {
  try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  return dir
}

func fileExists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

func removeItem(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

/// Milliseconds since 1970, like Date.now().
func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

// ---- Ids --------------------------------------------------------------------

private let hexDigits = Array("0123456789abcdef".utf8)

func sha1Hex(_ s: String) -> String {
  var out = [UInt8]()
  out.reserveCapacity(40)
  for b in Insecure.SHA1.hash(data: Data(s.utf8)) {
    out.append(hexDigits[Int(b >> 4)])
    out.append(hexDigits[Int(b & 15)])
  }
  return String(decoding: out, as: UTF8.self)
}

func hashId(_ s: String, _ n: Int = 12) -> String { String(sha1Hex(s).prefix(n)) }

/// Changes whenever the file on disk changes; keys every cache.
func fileSig(_ f: LibraryFile) -> String { "\(f.size):\(f.mtime)" }
func sigHash(_ f: LibraryFile) -> String { hashId("\(f.path)|\(fileSig(f))", 10) }

// ---- Numbers ----------------------------------------------------------------

/// JavaScript's Math.round: halves go up.
func jsRound(_ x: Double) -> Double {
  let f = x.rounded(.down)
  return x - f >= 0.5 ? f + 1 : f
}

/// Rounds to `places` decimals the way the engine always has: Math.round(x * 10^n) / 10^n.
func roundTo(_ x: Double, _ places: Int) -> Double {
  let m = pow(10, Double(places))
  return jsRound(x * m) / m
}

/// Number#toFixed: the exact binary value rounded to `digits` decimals, halves
/// away from zero (printf would round exact halves to even).
func toFixed(_ x: Double, _ digits: Int) -> String {
  guard x.isFinite, abs(x) < 1e21 else { return jsNumber(x) }
  // macOS prints the exact decimal expansion of a double when asked for enough digits.
  let exact = String(format: "%.80f", abs(x))
  let dot = exact.firstIndex(of: ".")!
  var keep = Array(exact[..<dot]) + Array(exact[exact.index(after: dot)...].prefix(digits))
  let rest = exact[exact.index(after: dot)...].dropFirst(digits)
  if let first = rest.first, first >= "5" {
    // Round up: add one to the last kept digit, carrying.
    var i = keep.count - 1
    while i >= 0 {
      if keep[i] == "9" {
        keep[i] = "0"
        i -= 1
      } else {
        keep[i] = Character(UnicodeScalar(keep[i].asciiValue! + 1))
        break
      }
    }
    if i < 0 { keep.insert("1", at: 0) }
  }
  let intDigits = keep.count - digits
  var s = String(keep[..<intDigits])
  if digits > 0 { s += "." + String(keep[intDigits...]) }
  return x < 0 ? "-" + s : s
}

// ---- Sorting ----------------------------------------------------------------

private let collationLocale = Locale(identifier: "en")

/// Names in the order people expect: "Episode 9" before "Episode 10", case and
/// accents ignored (Intl.Collator with numeric, sensitivity: base).
func naturalCompare(_ a: String, _ b: String) -> Int {
  switch a.compare(b, options: [.numeric, .caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: nil, locale: collationLocale) {
  case .orderedAscending: return -1
  case .orderedDescending: return 1
  case .orderedSame: return 0
  }
}

extension Array {
  /// A stable sort with a JavaScript-style comparator (negative, zero, positive),
  /// so ties keep their order exactly as Array.prototype.sort does.
  mutating func stableSort(by cmp: (Element, Element) -> Int) {
    guard count > 1 else { return }
    var src = self
    var dst = self
    var width = 1
    while width < count {
      var lo = 0
      while lo < count {
        let mid = Swift.min(lo + width, count), hi = Swift.min(lo + 2 * width, count)
        var i = lo, j = mid, k = lo
        while i < mid && j < hi {
          if cmp(src[j], src[i]) < 0 { dst[k] = src[j]; j += 1 } else { dst[k] = src[i]; i += 1 }
          k += 1
        }
        while i < mid { dst[k] = src[i]; i += 1; k += 1 }
        while j < hi { dst[k] = src[j]; j += 1; k += 1 }
        lo = hi
      }
      swap(&src, &dst)
      width *= 2
    }
    self = src
  }

  func stableSorted(by cmp: (Element, Element) -> Int) -> [Element] {
    var copy = self
    copy.stableSort(by: cmp)
    return copy
  }
}

/// Comparator for numbers, like (a, b) => a - b.
func numCompare<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : a > b ? 1 : 0 }

// ---- JSON files ---------------------------------------------------------------

let jsonEncoder: JSONEncoder = {
  let e = JSONEncoder()
  e.outputFormatting = [.withoutEscapingSlashes]
  return e
}()
let jsonDecoder = JSONDecoder()

/// Decodes a JSON file the JavaScript engine may have written. JSONDecoder
/// fails on an escaped lone surrogate ("\ud83d": JSON.stringify writes half an
/// emoji that way), which drops the entry holding it, and on bad UTF-8, which
/// drops the whole file. Text with either is read with JSON.parse instead
/// (which makes those U+FFFD, as reading the file in Node did for bad bytes).
func decodeJSONFile<T: Decodable>(_ type: T.Type, from raw: Data) -> T? {
  if hasSurrogateEscape(raw) || !isValidUTF8(raw) { return decodeViaJSONParse(T.self, from: raw) }
  return try? jsonDecoder.decode(T.self, from: raw)
}

/// JSON.parse the text, write it out again (now valid for JSONDecoder) and decode that.
func decodeViaJSONParse<T: Decodable>(_ type: T.Type, from raw: Data) -> T? {
  guard let value = JSON.parse(String(decoding: raw, as: UTF8.self)), JSONSerialization.isValidJSONObject(value),
    let clean = try? JSONSerialization.data(withJSONObject: value)
  else { return nil }
  return try? jsonDecoder.decode(T.self, from: clean)
}

/// Whether the bytes hold \uD800 to \uDFFF (either case), a surrogate written as an escape.
private func hasSurrogateEscape(_ raw: Data) -> Bool {
  raw.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Bool in
    guard b.count >= 4 else { return false }
    for i in 0..<(b.count - 3) where b[i] == 0x5C && b[i + 1] == 0x75 && (b[i + 2] | 0x20) == 0x64 {
      let c = b[i + 3] | 0x20
      if c == 0x38 || c == 0x39 || (c >= 0x61 && c <= 0x66) { return true }
    }
    return false
  }
}

private func isValidUTF8(_ raw: Data) -> Bool {
  raw.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Bool in
    var it = b.makeIterator()
    var utf8 = UTF8()
    while true {
      switch utf8.decode(&it) {
      case .scalarValue: continue
      case .emptyInput: return true
      case .error: return false
      }
    }
  }
}

/// A JSON file kept in memory and written back (atomically) shortly after
/// changes. `mode` 0o600 keeps files with secrets readable by this user only.
/// Used from the main thread only.
final class JsonStore<T: Codable> {
  let file: String
  let mode: mode_t?
  var data: T
  private var timer: DispatchWorkItem?

  init(_ file: String, defaults: T, mode: mode_t? = nil) {
    self.file = file
    self.mode = mode
    if let raw = FileManager.default.contents(atPath: file), let v = decodeJSONFile(T.self, from: raw) {
      data = v
    } else {
      data = defaults
    }
  }

  func save() {
    timer?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.flush() }
    timer = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  func flush() {
    timer?.cancel()
    timer = nil
    ensureDir(dirname(file))
    guard let bytes = try? jsonEncoder.encode(data) else {
      logLine("[store] could not encode \(basename(file))")
      return
    }
    let tmp = "\(file).tmp"
    var attrs: [FileAttributeKey: Any]? = nil
    if let mode { attrs = [.posixPermissions: mode] }
    guard FileManager.default.createFile(atPath: tmp, contents: bytes, attributes: attrs) else {
      logLine("[store] could not write \(tmp)")
      return
    }
    if let mode { chmod(tmp, mode) }
    if rename(tmp, file) != 0 { logLine("[store] could not replace \(file)") }
  }
}

// ---- Log ------------------------------------------------------------------------

private let logLock = NSLock()
private let logStamp: DateFormatter = {
  let f = DateFormatter()
  f.dateFormat = "yyyy-MM-dd HH:mm:ss"
  return f
}()

/// Appends to DATA_DIR/nightcap.log (and stderr), like the engine's console output.
func logLine(_ message: String) {
  logLock.lock()
  defer { logLock.unlock() }
  let line = "\(logStamp.string(from: Date())) \(message)\n"
  FileHandle.standardError.write(Data(line.utf8))
  let path = Paths.data("nightcap.log")
  if let h = FileHandle(forWritingAtPath: path) {
    h.seekToEndOfFile()
    h.write(Data(line.utf8))
    try? h.close()
  } else {
    ensureDir(Paths.data)
    FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
  }
}

// ---- Tools ----------------------------------------------------------------------

enum Tools {
  /// ffmpeg and ffprobe: the copies inside the app, else Homebrew's (development).
  static let ffmpeg = find("ffmpeg", env: "FFMPEG")
  static let ffprobe = find("ffprobe", env: "FFPROBE")

  private static func find(_ name: String, env: String) -> String? {
    var candidates: [String] = []
    if let e = ProcessInfo.processInfo.environment[env], !e.isEmpty { candidates.append(e) }
    if let res = Bundle.main.resourcePath { candidates.append(join(res, "bin", name)) }
    candidates += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}

struct RunResult {
  /// The exit status; -1 when the process was killed by a signal.
  let code: Int32
  let stdout: Data
  let stderr: String
  var lastErrorLine: String {
    stderr.jsTrimmed.jsSplit("\n").last ?? ""
  }
}

/// Every process the engine runs, so quitting can end them all.
final class Children: @unchecked Sendable {
  static let shared = Children()
  private let lock = NSLock()
  private var pids = Set<pid_t>()

  func add(_ pid: pid_t) { lock.lock(); pids.insert(pid); lock.unlock() }
  func remove(_ pid: pid_t) { lock.lock(); pids.remove(pid); lock.unlock() }
  func killAll() {
    lock.lock()
    let all = pids
    lock.unlock()
    for pid in all { kill(pid, SIGKILL) }
  }
}

/// Runs a command and returns its exit code, stdout and stderr. Past `maxErr`
/// bytes of stderr, only the last half is kept, or with `errHead` the start
/// (what the analysis worker kept, so frame times stay in step with frames).
/// `timeout` (seconds) kills it; `background` lowers its priority so playback
/// stays smooth. `onStdout` streams stdout instead of collecting it.
func runTool(
  _ cmd: String, _ args: [String], timeout: Double = 0, background: Bool = false,
  maxErr: Int = 1_000_000, errHead: Bool = false, onStdout: ((Data) -> Void)? = nil
) async throws -> RunResult {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: cmd)
  p.arguments = args
  p.standardInput = FileHandle.nullDevice
  let out = Pipe(), err = Pipe()
  p.standardOutput = out
  p.standardError = err
  final class Output: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
  }
  let o = Output()
  return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RunResult, Error>) in
    let group = DispatchGroup()
    group.enter()
    group.enter()
    group.enter()
    p.terminationHandler = { _ in group.leave() }
    do {
      try p.run()
    } catch {
      cont.resume(throwing: error)
      return
    }
    let pid = p.processIdentifier
    Children.shared.add(pid)
    if background { setpriority(PRIO_PROCESS, id_t(pid), 10) }
    DispatchQueue.global(qos: .utility).async {
      let h = out.fileHandleForReading
      while true {
        let chunk = h.availableData
        if chunk.isEmpty { break }
        if let onStdout { onStdout(chunk) } else { o.stdout.append(chunk) }
      }
      group.leave()
    }
    DispatchQueue.global(qos: .utility).async {
      let h = err.fileHandleForReading
      while true {
        let chunk = h.availableData
        if chunk.isEmpty { break }
        if errHead {
          if o.stderr.count < maxErr { o.stderr.append(chunk) }
        } else {
          o.stderr.append(chunk)
          if o.stderr.count > maxErr { o.stderr = o.stderr.suffix(maxErr / 2) }
        }
      }
      group.leave()
    }
    var timer: DispatchWorkItem?
    if timeout > 0 {
      let t = DispatchWorkItem { kill(pid, SIGKILL) }
      timer = t
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: t)
    }
    group.notify(queue: .global()) {
      timer?.cancel()
      Children.shared.remove(pid)
      let code: Int32 = p.terminationReason == .uncaughtSignal ? -1 : p.terminationStatus
      cont.resume(returning: RunResult(code: code, stdout: o.stdout, stderr: String(decoding: o.stderr, as: UTF8.self)))
    }
  }
}

// ---- Limits -----------------------------------------------------------------------

/// Limits how many async jobs of one kind run at once (main actor only).
@MainActor
final class Limiter {
  let max: Int
  private var active = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(_ max: Int) { self.max = max }

  func run<T>(_ fn: () async throws -> T) async rethrows -> T {
    if active >= max { await withCheckedContinuation { waiting.append($0) } }
    active += 1
    defer {
      active -= 1
      if !waiting.isEmpty { waiting.removeFirst().resume() }
    }
    return try await fn()
  }
}

/// Waits without blocking (seconds).
func sleep(seconds: Double) async {
  try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
}
