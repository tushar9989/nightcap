import Foundation

// OpenSubtitles.com client (REST API v1).
//
// Needs the user's own API key (free: opensubtitles.com -> Consumers). Search
// is unlimited; downloads are not: a free key allows 5 per IP per 24 h
// without signing in, and signing in uses the account's own daily quota.
// The password is only sent to /login and never stored; the token is.
// Docs: https://opensubtitles.stoplight.io/docs/opensubtitles-api

struct OSError: Error, @unchecked Sendable {
  let message: String
  /// The HTTP status worth reporting (0 when the API was never reached).
  let status: Int
  /// The API's answer, when it sent one.
  let data: [String: Any]?

  init(_ message: String, _ status: Int = 0, _ data: [String: Any]? = nil) {
    self.message = message
    self.status = status
    self.data = data
  }
}

/// One subtitle found by a search (a single-file one; multi-CD subtitles are skipped).
struct SubtitleResult {
  /// The file id to download; NaN when the API gave none.
  var id: Double
  var subtitleId: String
  var language: String
  var release: String
  var fileName: String
  var downloads: Double
  var hearingImpaired: Bool
  var foreignOnly: Bool
  var aiTranslated: Bool
  var machineTranslated: Bool
  var trusted: Bool
  /// Made for this very file (the moviehash matched).
  var hashMatch: Bool
  var fps: Double?
  var uploaded: String?
  var uploader: String
  var feature: String
  var season: Double?
  var episode: Double?
}

/// A downloaded subtitle, as text, with the quota the API reported.
struct OSDownload {
  var text: String
  var fileName: String
  var remaining: Double?
  var resetAt: String?
}

@MainActor
final class OpenSubtitles {
  nonisolated static let defaultBase = "https://api.opensubtitles.com/api/v1"
  nonisolated static let userAgent =
    "Nightcap v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")"
  nonisolated static let spacingMs: Int64 = 250  // the API allows 5 requests per second per IP
  nonisolated static let showCacheMs: Int64 = 30 * 86_400_000
  nonisolated static let maxSubtitleBytes = 8 << 20

  // Some networks cut connections to OpenSubtitles at random: one internet
  // provider was seen resetting about half of the TLS handshakes for
  // *.opensubtitles.com, a few ms after the hello (the name is readable there).
  // A connection reset before the reply never reached the API, so try again.
  nonisolated static let attempts = 10
  nonisolated static let blocked =
    "Your network keeps cutting the connection to OpenSubtitles (your internet provider may be blocking it). Try again in a moment."

  let store: JsonStore<OSStoreData>
  let base: String
  let envKey: String
  private var chain: Task<Void, Never>?
  private var last: Int64 = 0

  init(
    store: JsonStore<OSStoreData>,
    base: String = ProcessInfo.processInfo.environment["OPENSUBTITLES_API"].flatMap { $0.isEmpty ? nil : $0 } ?? OpenSubtitles.defaultBase,
    envKey: String = ProcessInfo.processInfo.environment["OPENSUBTITLES_API_KEY"] ?? ""
  ) {
    self.store = store
    self.base = base
    self.envKey = envKey
  }

  // ---- Connections ------------------------------------------------------------------

  nonisolated private static func session(timeout: Double) -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = timeout
    c.timeoutIntervalForResource = timeout
    c.urlCache = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    return URLSession(configuration: c)
  }
  nonisolated private static let apiSession = session(timeout: 20)
  nonisolated private static let fileSession = session(timeout: 30)

  /// A connection the network cut before the reply: a TLS handshake reset
  /// (-1200 with SSL stream error -9816 or -9806, or a POSIX reset), or a
  /// connection lost before the answer (-1005).
  nonisolated static func isReset(_ error: Error) -> Bool {
    let ns = error as NSError
    guard ns.domain == NSURLErrorDomain else { return false }
    if ns.code == NSURLErrorNetworkConnectionLost { return true }
    guard ns.code == NSURLErrorSecureConnectionFailed else { return false }
    let domain = ns.userInfo["_kCFStreamErrorDomainKey"] as? Int ?? 0
    let code = ns.userInfo["_kCFStreamErrorCodeKey"] as? Int ?? 0
    if domain == 3 { return code == -9816 || code == -9806 }  // errSSLClosedNoNotify, errSSLClosedAbort
    if domain == 1 { return [ECONNRESET, EPIPE, ECONNABORTED].contains(Int32(code)) }
    return false
  }

  struct Reply: Sendable {
    let status: Int
    /// nil when the body was cut off.
    let body: Data?
    var ok: Bool { (200...299).contains(status) }
  }

  /// Notes whether the server's reply had begun, and how many connections a
  /// request took. URLSession holds a reply back until it has 512 bytes when
  /// the reply has no type or says text/plain (it guesses the type), so a
  /// connection lost in that time looks like one lost before the reply, yet
  /// the server has answered. And it tries a GET up to three times itself when
  /// the connection is lost.
  private final class ReplyWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var answered: Int?
    private var tries = 1

    /// The status of the reply the server began to send, if it did.
    var status: Int? { lock.withLock { answered } }
    /// The connections the request took.
    var connections: Int { lock.withLock { tries } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
      let status = (metrics.transactionMetrics.last?.response as? HTTPURLResponse)?.statusCode
      let count = metrics.transactionMetrics.count
      lock.withLock {
        answered = status
        tries = max(count, 1)
      }
    }
  }

  /// Fetches a URL, trying again when the network resets the connection before
  /// the reply. The body is read after; past `maxBytes` the reading stops.
  nonisolated static func fetchRetrying(
    _ urlString: String, method: String = "GET", headers: [String: String], body: Data? = nil, session: URLSession,
    maxBytes: Int = .max
  ) async throws -> Reply {
    guard let url = URL(string: urlString) else { throw OSError("Could not reach OpenSubtitles (offline?)") }
    var req = URLRequest(url: url)
    req.httpMethod = method
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = body
    var attempt = 1
    while true {
      let watch = ReplyWatch()
      do {
        let (bytes, response) = try await session.bytes(for: req, delegate: watch)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var data = Data()
        do {
          for try await b in bytes {
            data.append(b)
            if data.count > maxBytes { break }
          }
        } catch {
          return Reply(status: status, body: nil)
        }
        return Reply(status: status, body: data)
      } catch {
        // The reply had begun, so the request reached the server: its body was cut off.
        if let status = watch.status { return Reply(status: status, body: nil) }
        // Each connection counts as a try, and the next request may take as
        // many as this one did: stop before it could go past the limit.
        attempt += watch.connections - 1
        let reset = isReset(error)
        if !reset || attempt + watch.connections > attempts {
          logLine("[opensubtitles] \(url.host ?? urlString): URLError \((error as NSError).code) (try \(attempt))")
          throw OSError(reset ? blocked : "Could not reach OpenSubtitles (offline?)")
        }
        await sleep(seconds: Double(100 + 50 * attempt) / 1000)
        attempt += 1
      }
    }
  }

  // ---- Hashes and queries -------------------------------------------------------------

  /// OpenSubtitles "moviehash": file size plus the 64-bit little-endian words of
  /// the first and last 64 KiB. Identifies the exact release, so subtitles made
  /// for this very file come first and are in sync.
  nonisolated static func movieHash(_ path: String, size: Int64) throws -> String {
    let chunk = 65536
    guard size >= 0 else { throw OSError("bad size") }
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { throw OSError(String(cString: strerror(errno))) }
    defer { close(fd) }
    var head = [UInt8](repeating: 0, count: chunk)
    var tail = [UInt8](repeating: 0, count: chunk)
    let n = Int(min(Int64(chunk), size))
    guard pread(fd, &head, n, 0) >= 0, pread(fd, &tail, n, off_t(max(0, size - Int64(chunk)))) >= 0 else {
      throw OSError(String(cString: strerror(errno)))
    }
    var hash = UInt64(size)
    for buf in [head, tail] {
      buf.withUnsafeBytes { raw in
        for i in stride(from: 0, to: chunk, by: 8) { hash &+= UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)) }
      }
    }
    return String(hash, radix: 16).padStart(16, "0")
  }

  nonisolated private static let idKeyRe = Re("_id$|^id$")
  nonisolated private static let ttRe = Re("^tt")
  nonisolated private static let leadZerosRe = Re(#"^0+(?=\d)"#)

  /// The API asks for sorted, lower-case parameters without defaults, and IDs
  /// without leading zeros, so requests hit its cache instead of redirecting.
  nonisolated static func canonicalQuery(_ params: [String: String?]) -> String {
    var parts: [String] = []
    for k in params.keys.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
      guard let raw = params[k] ?? nil, !raw.isEmpty else { continue }
      var v = raw.jsLowercased
      if idKeyRe.test(k) { v = leadZerosRe.replace(ttRe.replace(v, "", global: false), "", global: false) }
      parts.append("\(formEncode(k))=\(formEncode(v))")
    }
    return parts.joined(separator: "&")
  }

  /// URLSearchParams' encoding: letters, digits and *-._ stay, spaces become +.
  nonisolated static func formEncode(_ s: String) -> String {
    var out = ""
    for b in s.utf8 {
      switch b {
      case 0x2A, 0x2D, 0x2E, 0x30...0x39, 0x41...0x5A, 0x5F, 0x61...0x7A: out.unicodeScalars.append(Unicode.Scalar(b))
      case 0x20: out += "+"
      default: out += String(format: "%%%02X", b)
      }
    }
    return out
  }

  /// The expiry (seconds) in a sign-in token, if it says.
  nonisolated static func jwtExpiry(_ token: String?) -> Double? {
    guard let token else { return nil }
    let parts = token.jsSplit(".")
    guard parts.count > 1 else { return nil }
    let payload = Data(base64URLDecode(parts[1]))
    guard let obj = JSON.parse(String(decoding: payload, as: UTF8.self)), !(obj is NSNull) else { return nil }
    let exp = JSON.toNumber(JSON.get(obj, "exp"))
    return exp.isNaN || exp == 0 ? nil : exp
  }

  /// Node's lenient base64/base64url decoding: both alphabets, other characters
  /// skipped, stopping at padding.
  nonisolated static func base64URLDecode(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var acc: UInt32 = 0, bits = 0
    for c in s.utf8 {
      let v: UInt32
      switch c {
      case 0x41...0x5A: v = UInt32(c - 0x41)
      case 0x61...0x7A: v = UInt32(c - 0x61 + 26)
      case 0x30...0x39: v = UInt32(c - 0x30 + 52)
      case 0x2B, 0x2D: v = 62
      case 0x2F, 0x5F: v = 63
      case 0x3D: return out
      default: continue
      }
      acc = acc << 6 | v
      bits += 6
      if bits >= 8 {
        bits -= 8
        out.append(UInt8(truncatingIfNeeded: acc >> UInt32(bits)))
      }
    }
    return out
  }

  nonisolated private static let normAmpRe = Re("&")
  nonisolated private static let normNonAlnumRe = Re("[^a-z0-9]+")
  nonisolated private static let normTheRe = Re("^the ")

  nonisolated static func norm(_ s: String?) -> String {
    let lower = (s ?? "").jsLowercased
    return normTheRe.replace(normNonAlnumRe.replace(normAmpRe.replace(lower, "and"), " "), "", global: false).jsTrimmed
  }

  // ---- State --------------------------------------------------------------------------

  var key: String { !envKey.isEmpty ? envKey : store.data.apiKey ?? "" }

  var configured: Bool { !key.isEmpty }

  var signedIn: Bool {
    let d = store.data
    guard let token = d.token, !token.isEmpty else { return false }
    guard let exp = d.tokenExp, exp != 0 else { return true }
    return exp * 1000 > Double(nowMs() + 60_000)
  }

  struct Status: Equatable {
    var provider = "OpenSubtitles.com"
    var configured: Bool
    var keyHint: String
    var keyFromEnv: Bool
    var signedIn: Bool
    var signInExpired: Bool
    var username: String
    var level: String
    var allowedDownloads: Double?
    var remaining: Double?
    var resetAt: String?
  }

  func status() -> Status {
    let d = store.data
    let key = self.key
    var quota: OSQuota?
    if let q = d.quota {
      if let r = q.resetAt, !r.isEmpty {
        if let t = jsDateParse(r), t > Double(nowMs()) { quota = q }
      } else {
        quota = q
      }
    }
    let signedIn = self.signedIn
    return Status(
      configured: !key.isEmpty, keyHint: key.isEmpty ? "" : "••••\(key.jsSlice(-4))", keyFromEnv: !envKey.isEmpty,
      signedIn: signedIn, signInExpired: !(d.token ?? "").isEmpty && !signedIn, username: d.username ?? "",
      level: signedIn ? d.user?.level ?? "" : "", allowedDownloads: signedIn ? d.user?.allowedDownloads : 5,
      remaining: quota?.remaining, resetAt: quota?.resetAt.flatMap { $0.isEmpty ? nil : $0 })
  }

  nonisolated private static let hostRe = Re(#"^[a-z0-9.-]+\.opensubtitles\.com$"#)

  /// After signing in, requests go to the host /login returned (VIP accounts get their own).
  func apiBase() -> String {
    guard signedIn, let host = store.data.baseUrl, !host.isEmpty, base == OpenSubtitles.defaultBase, OpenSubtitles.hostRe.test(host) else {
      return base
    }
    return "https://\(host)/api/v1"
  }

  /// Waits for this request's turn: requests start at least 250 ms apart, in order.
  private func takeTurn() async {
    let previous = chain
    let turn = Task { @MainActor in
      await previous?.value
      let wait = self.last + OpenSubtitles.spacingMs - nowMs()
      if wait > 0 { await sleep(seconds: Double(wait) / 1000) }
      self.last = nowMs()
    }
    chain = turn
    await turn.value
  }

  /// One API call: the JSON object it answered (an empty one when the answer
  /// wasn't JSON). Errors carry the API's message.
  func request(
    _ method: String, _ apiPath: String, query: [String: String?]? = nil, body: [String: Any]? = nil, auth: Bool = true,
    key: String? = nil
  ) async throws -> [String: Any] {
    let key = key ?? self.key
    if key.isEmpty { throw OSError("Add an OpenSubtitles API key in Settings first") }
    await takeTurn()
    let url = "\(apiBase())\(apiPath)\(query.map { "?\(OpenSubtitles.canonicalQuery($0))" } ?? "")"
    var headers = ["Api-Key": key, "User-Agent": OpenSubtitles.userAgent, "Accept": "application/json"]
    if body != nil { headers["Content-Type"] = "application/json" }
    if auth && signedIn, let token = store.data.token { headers["Authorization"] = "Bearer \(token)" }
    let payload = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes]) }
    let r = try await OpenSubtitles.fetchRetrying(url, method: method, headers: headers, body: payload, session: OpenSubtitles.apiSession)
    let parsed = r.body.flatMap { JSON.parse(body: $0) }
    let data = parsed as? [String: Any] ?? [:]
    if !r.ok {
      var msg = JSON.truthy(data["message"]) ? JSON.string(data["message"]) ?? "" : ""
      if msg.isEmpty, let errors = data["errors"] as? [Any] { msg = errors.map { JSON.string($0) ?? "" }.joined(separator: ", ") }
      if msg.isEmpty { msg = "OpenSubtitles answered \(r.status)" }
      throw OSError(msg, r.status, data)
    }
    return data
  }

  // ---- Key and account ------------------------------------------------------------------

  nonisolated private static let keyRe = Re("^[A-Za-z0-9_-]{8,128}$")

  /// Checks a key with a cheap request before saving it.
  func setKey(_ apiKey: String?) async throws {
    let apiKey = (apiKey ?? "").jsTrimmed
    if apiKey.isEmpty {
      store.data.apiKey = nil
      store.save()
      return
    }
    if !OpenSubtitles.keyRe.test(apiKey) { throw OSError("That does not look like an API key", 400) }
    do {
      _ = try await request("GET", "/infos/formats", auth: false, key: apiKey)
    } catch let e as OSError where e.status == 401 || e.status == 403 {
      throw OSError("OpenSubtitles did not accept this API key", 400)
    }
    store.data.apiKey = apiKey
    store.save()
  }

  func login(_ username: String?, _ password: String?) async throws -> Status {
    let username = (username ?? "").jsTrimmed
    guard !username.isEmpty, let password, !password.isEmpty else {
      throw OSError("Enter your OpenSubtitles username and password", 400)
    }
    let data: [String: Any]
    do {
      data = try await request("POST", "/login", body: ["username": username, "password": password], auth: false)
    } catch let e as OSError where e.status == 401 {
      throw OSError("Wrong username or password", 400)
    }
    let user = JSON.get(data, "user")
    store.data.token = JSON.string(data["token"])
    store.data.tokenExp = OpenSubtitles.jwtExpiry(JSON.string(data["token"]))
    store.data.username = username
    store.data.baseUrl = JSON.truthy(data["base_url"]) ? JSON.string(data["base_url"]) : ""
    store.data.user = OSUser(
      level: JSON.truthy(JSON.get(user, "level")) ? JSON.string(JSON.get(user, "level")) ?? "" : "",
      allowedDownloads: JSON.number(JSON.get(user, "allowed_downloads")), vip: JSON.truthy(JSON.get(user, "vip")))
    store.data.quota = nil
    store.save()
    return status()
  }

  func logout() async {
    if !(store.data.token ?? "").isEmpty { _ = try? await request("DELETE", "/logout") }
    store.data.token = nil
    store.data.tokenExp = nil
    store.data.baseUrl = nil
    store.data.user = nil
    store.data.quota = nil
    store.save()
  }

  /// Remaining downloads for the signed-in user.
  func refreshUser() async -> Status {
    guard signedIn else { return status() }
    do {
      let res = try await request("GET", "/infos/user")
      // No "data": nothing to learn (JavaScript stopped at reading data.level).
      guard let raw = res["data"], !(raw is NSNull) else { return status() }
      let data = raw as? [String: Any] ?? [:]
      let old = store.data.user
      let level = JSON.truthy(data["level"]) ? JSON.string(data["level"]) ?? "" : (old?.level.isEmpty == false ? old!.level : "")
      let allowed = JSON.nullish(data["allowed_downloads"], nil) != nil ? JSON.number(data["allowed_downloads"]) : old?.allowedDownloads
      store.data.user = OSUser(level: level, allowedDownloads: allowed, vip: JSON.truthy(data["vip"]))
      if JSON.nullish(data["remaining_downloads"], nil) != nil {
        let resetAt = store.data.quota?.resetAt.flatMap { $0.isEmpty ? nil : $0 }
        store.data.quota = OSQuota(remaining: JSON.number(data["remaining_downloads"]), resetAt: resetAt)
      }
      store.save()
    } catch let e as OSError where e.status == 401 {
      dropToken()
    } catch {}
    return status()
  }

  func dropToken() {
    store.data.token = nil
    store.data.tokenExp = nil
    store.data.baseUrl = nil
    store.save()
  }

  // ---- Search -------------------------------------------------------------------------

  nonisolated private static let tvRe = Re("tv", "i")

  /// The show as OpenSubtitles knows it (cached), so episodes can be searched by id.
  func findShow(_ name: String, year: Int?) async throws -> OSShow? {
    let cacheKey = "\(OpenSubtitles.norm(name))|\(year.map { $0 == 0 ? "" : String($0) } ?? "")"
    if let hit = store.data.shows[cacheKey], nowMs() - hit.at < (hit.show != nil ? OpenSubtitles.showCacheMs : 86_400_000) {
      return hit.show
    }
    let res = try await request("GET", "/features", query: ["query": name, "type": "tvshow"])
    let list: [Any]
    switch res["data"] {
    case nil: list = []
    case let a as [Any]: list = a
    default: throw OSError("OpenSubtitles sent an unexpected answer", 502)
    }
    var shown: [OSShow] = []
    for f in list {
      if f is NSNull { throw OSError("OpenSubtitles sent an unexpected answer", 502) }
      let a = JSON.get(f, "attributes")
      let id = JSON.toNumber(JSON.or(JSON.get(a, "feature_id"), JSON.get(f, "id")))
      let title = JSON.truthy(JSON.get(a, "title")) ? JSON.string(JSON.get(a, "title")) ?? "" : ""
      let yearNum = JSON.toNumber(JSON.get(a, "year"))
      var count = 0.0
      if let counts = JSON.get(a, "subtitles_counts") as? [String: Any] {
        for v in counts.values { count += JSON.toNumber(v) }
      }
      if count == 0 || count.isNaN { count = JSON.truthy(JSON.get(a, "subtitles_count")) ? JSON.toNumber(JSON.get(a, "subtitles_count")) : 0 }
      let type = JSON.truthy(JSON.get(a, "feature_type")) ? JSON.string(JSON.get(a, "feature_type")) ?? "" : ""
      guard id != 0, !id.isNaN, let intId = Int(exactly: id), OpenSubtitles.tvRe.test(type.isEmpty ? "tvshow" : type) else { continue }
      shown.append(OSShow(
        id: intId, title: title, year: yearNum == 0 || yearNum.isNaN ? nil : Int(exactly: yearNum),
        count: Int(exactly: count) ?? 0, type: type))
    }
    let want = OpenSubtitles.norm(name)
    let exact = shown.filter { OpenSubtitles.norm($0.title).jsEquals(want) }
    let pool = !exact.isEmpty
      ? exact
      : shown.filter { OpenSubtitles.norm($0.title).jsStartsWith(want) || want.jsStartsWith(OpenSubtitles.norm($0.title)) }
    let byYear = year.map { y in y == 0 ? [] : pool.filter { $0.year == y } } ?? []
    let show = (byYear.isEmpty ? pool : byYear).stableSorted { numCompare($1.count, $0.count) }.first
    store.data.shows[cacheKey] = OSShowCache(at: nowMs(), show: show)
    store.save()
    return show
  }

  func search(_ params: [String: String?]) async throws -> [SubtitleResult] {
    let res = try await request("GET", "/subtitles", query: params)
    guard JSON.truthy(res["data"]) else { return [] }
    guard let list = res["data"] as? [Any] else { throw OSError("OpenSubtitles sent an unexpected answer", 502) }
    return list.compactMap(OpenSubtitles.normaliseResult)
  }

  nonisolated private static func text(_ v: Any?) -> String { JSON.truthy(v) ? JSON.string(v) ?? "" : "" }

  nonisolated static func normaliseResult(_ item: Any) -> SubtitleResult? {
    guard let a = JSON.get(item, "attributes"), JSON.truthy(a) else { return nil }
    guard let files = JSON.get(a, "files") as? [Any], files.count == 1 else { return nil }  // multi-CD subtitles don't fit a single file
    let f = files[0]
    let fd = JSON.or(JSON.get(a, "feature_details"), [String: Any]())
    let fps = JSON.toNumber(JSON.get(a, "fps"))
    return SubtitleResult(
      id: JSON.toNumber(JSON.get(f, "file_id")),
      subtitleId: text(JSON.or(JSON.or(JSON.get(a, "subtitle_id"), JSON.get(item, "id")), "")),
      language: text(JSON.get(a, "language")),
      release: text(JSON.or(JSON.get(a, "release"), JSON.get(f, "file_name"))).jsTrimmed,
      fileName: text(JSON.get(f, "file_name")),
      downloads: JSON.truthy(JSON.get(a, "download_count")) ? JSON.toNumber(JSON.get(a, "download_count")) : 0,
      hearingImpaired: JSON.truthy(JSON.get(a, "hearing_impaired")),
      foreignOnly: JSON.truthy(JSON.get(a, "foreign_parts_only")),
      aiTranslated: JSON.truthy(JSON.get(a, "ai_translated")),
      machineTranslated: JSON.truthy(JSON.get(a, "machine_translated")),
      trusted: JSON.truthy(JSON.get(a, "from_trusted")),
      hashMatch: JSON.truthy(JSON.nullish(JSON.get(a, "moviehash_match"), JSON.get(f, "moviehash_match"))),
      fps: fps == 0 || fps.isNaN ? nil : fps,
      uploaded: JSON.truthy(JSON.get(a, "upload_date")) ? JSON.string(JSON.get(a, "upload_date")) : nil,
      uploader: text(JSON.get(JSON.get(a, "uploader"), "name")),
      feature: text(JSON.or(JSON.get(fd, "title"), JSON.get(fd, "movie_name"))),
      season: JSON.number(JSON.get(fd, "season_number")),
      episode: JSON.number(JSON.get(fd, "episode_number")))
  }

  /// Best first: made for this file, complete, human-made, popular.
  nonisolated static func rankResults(_ results: [SubtitleResult], fps: Double? = nil) -> [SubtitleResult] {
    func score(_ r: SubtitleResult) -> Double {
      var s = (r.hashMatch ? 1000.0 : 0) - (r.foreignOnly ? 600 : 0) - (r.machineTranslated ? 400 : 0) - (r.aiTranslated ? 150 : 0)
      s = s + (r.trusted ? 40 : 0) - (r.hearingImpaired ? 15 : 0)
      if let fps, fps != 0, !fps.isNaN, let rf = r.fps, abs(rf - fps) < 0.05 { s += 30 }
      return s + nc_fdlibm_log10(1 + r.downloads) * 12
    }
    return results.map { (r: $0, s: score($0)) }.stableSorted { numCompare($1.s, $0.s) }.map(\.r)
  }

  // ---- Download -------------------------------------------------------------------------

  /// The subtitle's text, recording the quota the API reports.
  func download(_ fileId: Int) async throws -> OSDownload {
    var info: [String: Any]
    do {
      info = try await request("POST", "/download", body: ["file_id": fileId])
    } catch let e as OSError where e.status == 401 && !(store.data.token ?? "").isEmpty {
      // Signed-in token no longer valid: fall back to the anonymous allowance.
      dropToken()
      do {
        info = try await request("POST", "/download", body: ["file_id": fileId])
      } catch {
        try quotaError(error)
      }
    } catch {
      try quotaError(error)
    }
    let remaining = JSON.number(info["remaining"]).flatMap { $0.isFinite ? $0 : nil }
    let resetAt = JSON.truthy(info["reset_time_utc"]) ? JSON.string(info["reset_time_utc"]) : nil
    store.data.quota = OSQuota(remaining: remaining, resetAt: resetAt)
    store.save()
    guard JSON.truthy(info["link"]), let link = JSON.string(info["link"]) else {
      throw OSError(JSON.truthy(info["message"]) ? JSON.string(info["message"]) ?? "" : "OpenSubtitles did not return a download link", 502)
    }
    let r = try await OpenSubtitles.fetchRetrying(
      link, headers: ["User-Agent": OpenSubtitles.userAgent], session: OpenSubtitles.fileSession, maxBytes: OpenSubtitles.maxSubtitleBytes)
    if !r.ok { throw OSError("The subtitle download failed (\(r.status))", 502) }
    guard let buf = r.body else { throw OSError("The subtitle download was cut off. Try again.") }
    if buf.count > OpenSubtitles.maxSubtitleBytes { throw OSError("That subtitle file is too large", 502) }
    return OSDownload(
      text: Subtext.decodeText(buf), fileName: JSON.truthy(info["file_name"]) ? JSON.string(info["file_name"]) ?? "" : "",
      remaining: JSON.number(info["remaining"]), resetAt: resetAt)
  }

  nonisolated private static let quotaRe = Re("allowed|quota|limit", "i")

  func quotaError(_ error: Error) throws -> Never {
    let e = error as? OSError
    let message = e?.message ?? error.localizedDescription
    if e?.status == 406 || e?.status == 429 || OpenSubtitles.quotaRe.test(message) {
      let reset = JSON.truthy(e?.data?["reset_time_utc"]) ? JSON.string(e?.data?["reset_time_utc"]) : nil
      store.data.quota = OSQuota(remaining: 0, resetAt: reset ?? store.data.quota?.resetAt.flatMap { $0.isEmpty ? nil : $0 })
      store.save()
      let hint = signedIn ? "" : " Sign in to OpenSubtitles in Settings for more."
      throw OSError("\(message)\(hint)", 429, e?.data)
    }
    throw error
  }
}
