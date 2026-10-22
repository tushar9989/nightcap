import Foundation

// A small test runner in the spirit of `node --test`: named async tests that
// run one after another; a failed expectation ends that test and the run goes
// on. scripts/test-mac.sh builds it with the engine and runs it.

struct TestFailure: Error, CustomStringConvertible {
  let description: String
}

@MainActor
final class Tests {
  private struct Case {
    let name: String
    let skip: String?
    let body: @MainActor () async throws -> Void
  }
  private var cases: [Case] = []
  private var cleanups: [@MainActor () -> Void] = []

  /// Adds a test; with `skip`, it is listed but not run, with that reason.
  func test(_ name: String, skip: String? = nil, _ body: @escaping @MainActor () async throws -> Void) {
    cases.append(Case(name: name, skip: skip, body: body))
  }

  /// Runs once every test has finished.
  func after(_ fn: @escaping @MainActor () -> Void) { cleanups.append(fn) }

  /// Runs every test (those whose name contains `filter`, when given) and
  /// prints each result. True when none failed.
  func run(filter: String?) async -> Bool {
    var passed = 0, failed = 0, skipped = 0
    for c in cases where filter.map({ c.name.contains($0) }) ?? true {
      if let reason = c.skip {
        print("﹣ \(c.name) (skipped: \(reason))")
        skipped += 1
        continue
      }
      let t0 = Date()
      do {
        try await c.body()
        print("✔ \(c.name) (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
        passed += 1
      } catch {
        print("✖ \(c.name)\n    \(error)")
        failed += 1
      }
    }
    for fn in cleanups { fn() }
    print("\(passed) passed, \(failed) failed\(skipped > 0 ? ", \(skipped) skipped" : "")")
    return failed == 0
  }
}

// ---- Expectations ----------------------------------------------------------------------

func expect(_ ok: Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) throws {
  if !ok { throw TestFailure(description: "\(file):\(line): \(message().isEmpty ? "expected true" : message())") }
}

func expectEqual<T: Equatable>(
  _ a: T, _ b: T, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line
) throws {
  if a != b {
    let what = "\(String(reflecting: a)) != \(String(reflecting: b))"
    throw TestFailure(description: "\(file):\(line): \(message().isEmpty ? what : "\(message()): \(what)")")
  }
}

/// Matches a regular expression (ICU syntax) anywhere in the text.
func matches(_ text: String, _ pattern: String, ignoringCase: Bool = false) -> Bool {
  text.range(of: pattern, options: ignoringCase ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
}

/// The error `body` throws; fails when it throws none.
func thrown(file: StaticString = #fileID, line: UInt = #line, _ body: () async throws -> Void) async throws -> Error {
  do {
    try await body()
  } catch {
    return error
  }
  throw TestFailure(description: "\(file):\(line): expected an error")
}

// ---- Helpers ----------------------------------------------------------------------------

/// The run's temporary folder (DATA_DIR is inside it), removed at the end.
let testRoot: String = {
  var template = Array(join(NSTemporaryDirectory(), "nightcap-tests-XXXXXX").utf8CString)
  guard mkdtemp(&template) != nil else { fatalError("mkdtemp failed") }
  return String(cString: template)
}()

/// The pseudo-random numbers the JavaScript tests drew (a 32-bit LCG), so the
/// generated audio and dialogue match theirs.
func lcg(_ seed: UInt32) -> () -> Double {
  var s = seed
  return {
    s = s &* 1_664_525 &+ 1_013_904_223
    return Double(s) / 4_294_967_296
  }
}

/// A new empty folder inside the run's temporary folder.
func tempDir(_ prefix: String) -> String {
  var template = Array(join(testRoot, "\(prefix)XXXXXX").utf8CString)
  guard mkdtemp(&template) != nil else { fatalError("mkdtemp failed") }
  return String(cString: template)
}

/// Runs ffmpeg; fails the test when it does.
func ffmpeg(_ args: [String]) async throws {
  guard let bin = Tools.ffmpeg else { throw TestFailure(description: "ffmpeg is not installed") }
  let r = try await runTool(bin, ["-nostdin", "-loglevel", "error"] + args)
  try expect(r.code == 0, "ffmpeg failed: \(r.lastErrorLine)")
}
