import Foundation

private let PILOT_AD = """
  1
  00:00:06,000 --> 00:00:12,074
  Someone needs to stop Clearway Law.
  Public shouldn't leave reviews for lawyers.

  2
  00:00:40,100 --> 00:00:42,500
  The following story is inspired
  by actual documented accounts.

  3
  00:01:10,000 --> 00:01:12,000
  Subtitles by explosiveskull

  4
  00:20:00,000 --> 00:20:02,000
  He wrote it down at www.example.com, she said.

  5
  00:41:00,000 --> 00:41:03,000
  Sync and corrections by n17t01
  www.addic7ed.com

  6
  00:41:30,000 --> 00:41:33,000
  Support us and become VIP member
  to remove all ads from www.OpenSubtitles.org

  """

// ---- fake API ------------------------------------------------------------------------

private let KEY = "testkey12345"

private func base64url(_ s: String) -> String {
  Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

private func fromBase64url(_ s: String) -> Data? {
  var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  b += String(repeating: "=", count: (4 - b.count % 4) % 4)
  return Data(base64Encoded: b)
}

private func futureToken(_ exp: Int) -> String { "x.\(base64url("{\"exp\":\(exp)}")).y" }

private let SRT = "1\n00:00:01,000 --> 00:00:03,000\nHello, Mulder.\n\n2\n00:00:04,000 --> 00:00:05,000\nDownloaded from www.OpenSubtitles.org\n"

/// The OpenSubtitles API as far as these tests need it.
private final class FakeAPI: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [(path: String, query: String)] = []
  private var downloadsLeft = 2
  private var server: FakeHTTP!
  var port: UInt16 { server.port }
  var base: String { "http://127.0.0.1:\(port)/api/v1" }
  /// Every request so far.
  var seen: [(path: String, query: String)] { lock.withLock { requests } }

  init() {
    server = FakeHTTP { [unowned self] req in handle(req) }
  }

  private func send(_ status: Int, _ json: String) -> FakeHTTP.Response {
    FakeHTTP.Response(status: status, type: "application/json", body: Data(json.utf8))
  }

  private func handle(_ req: FakeHTTP.Request) -> FakeHTTP.Response {
    lock.withLock { requests.append((req.path, req.query)) }
    if req.path == "/file/9001.srt" { return FakeHTTP.Response(status: 200, type: nil, body: Data(SRT.utf8)) }
    if req.headers["api-key"] != KEY { return send(403, #"{"message":"You cannot consume this service"}"#) }
    if !matches(req.headers["user-agent"] ?? "", #"^Nightcap v\d"#) { return send(403, #"{"message":"User-Agent header is wrong"}"#) }
    let b = req.body.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
    switch "\(req.method) \(req.path)" {
    case "GET /api/v1/infos/formats":
      return send(200, #"{"data":{"output_formats":["srt","vtt"]}}"#)
    case "POST /api/v1/login":
      if b["username"] as? String != "mulder" || b["password"] as? String != "trustno1" {
        return send(401, #"{"message":"Error, invalid username/password"}"#)
      }
      let token = futureToken(Int(Date().timeIntervalSince1970) + 86400)
      return send(200, #"{"token":"\#(token)","base_url":"api.opensubtitles.com","user":{"allowed_downloads":20,"level":"Sub leecher","vip":false},"status":200}"#)
    case "GET /api/v1/features":
      return send(200, """
        {"data":[
          {"id":"2","attributes":{"feature_id":"2","title":"The X-Files","year":"2016","feature_type":"Tvshow","subtitles_counts":{"en":40}}},
          {"id":"1","attributes":{"feature_id":"1","title":"The X-Files","year":"1993","feature_type":"Tvshow","subtitles_counts":{"en":5000,"fr":900}}},
          {"id":"3","attributes":{"feature_id":"3","title":"The X-Files: I Want to Believe","year":"2008","feature_type":"Movie"}}
        ]}
        """)
    case "GET /api/v1/subtitles":
      return send(200, """
        {"data":[
          {"id":"10","attributes":{"subtitle_id":"10","language":"en","download_count":9000,"release":"The.X-Files.S01E02.WEB","files":[{"file_id":8000,"file_name":"a.srt"}]}},
          {"id":"11","attributes":{"subtitle_id":"11","language":"en","download_count":12,"release":"The X-Files S01E02 DVDRip XviD-TSV","moviehash_match":true,"files":[{"file_id":9001,"file_name":"b.srt"}]}},
          {"id":"12","attributes":{"subtitle_id":"12","language":"en","download_count":99999,"release":"two cds","files":[{"file_id":1},{"file_id":2}]}}
        ]}
        """)
    case "POST /api/v1/download":
      if let auth = req.headers["authorization"] {
        let parts = auth.components(separatedBy: ".")
        let exp = parts.count > 1 ? fromBase64url(parts[1]).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["exp"] as? Int : nil
        if exp.map({ auth != "Bearer \(futureToken($0))" }) ?? true { return send(401, #"{"message":"invalid token"}"#) }
      }
      if downloadsLeft <= 0 {
        return send(406, #"{"message":"You have downloaded your allowed 5 subtitles for 24h.","remaining":0,"reset_time_utc":"2030-01-01T00:00:00.000Z"}"#)
      }
      downloadsLeft -= 1
      let fileId = (b["file_id"] as? NSNumber)?.intValue ?? 0
      let link = "\(base.replacingOccurrences(of: "/api/v1", with: ""))/file/\(fileId).srt"
      return send(200, #"{"link":"\#(link)","file_name":"b.srt","requests":1,"remaining":\#(downloadsLeft),"message":"ok","reset_time":"23 hours","reset_time_utc":"2030-01-01T00:00:00.000Z"}"#)
    case "DELETE /api/v1/logout":
      return send(200, #"{"message":"token successfully destroyed","status":200}"#)
    default:
      return send(404, #"{"message":"not found"}"#)
    }
  }
}

private func message(_ e: Error) -> String { (e as? MessageError)?.message ?? "\(e)" }

private func result(
  id: Double, downloads: Double = 0, hashMatch: Bool = false, foreignOnly: Bool = false, machineTranslated: Bool = false, fps: Double? = nil
) -> SubtitleResult {
  SubtitleResult(
    id: id, subtitleId: "", language: "", release: "", fileName: "", downloads: downloads, hearingImpaired: false, foreignOnly: foreignOnly,
    aiTranslated: false, machineTranslated: machineTranslated, trusted: false, hashMatch: hashMatch, fps: fps, uploaded: nil, uploader: "",
    feature: "", season: nil, episode: nil)
}

@MainActor func subtitlesTests(_ t: Tests) {
  let tmp = tempDir("nightcap-subs-")

  t.test("adverts and uploader credits are removed, dialogue is kept") {
    let (vtt, removed) = Subtext.stripAds(Subtext.srtToVtt(PILOT_AD))
    try expect(matches(vtt, "^WEBVTT"))
    try expect(matches(vtt, #"inspired\nby actual documented accounts"#))
    try expect(matches(vtt, #"www\.example\.com, she said"#), "links in the middle of an episode are dialogue")
    try expect(!matches(vtt, "Clearway|explosiveskull|addic7ed|OpenSubtitles", ignoringCase: true))
    try expectEqual(removed.count, 4)
  }

  t.test("retime shifts and stretches cues and drops ones before zero") {
    let vtt = Subtext.srtToVtt("1\n00:00:01,000 --> 00:00:02,000\nearly\n\n2\n00:01:00,000 --> 00:01:02,500\nlater\n")
    let out = Subtext.retime(vtt, SubTiming(offset: -2.5, scale: 25 / 23.976))
    let times = Subtext.cueTimes(out)
    try expectEqual(times.count, 1)
    try expect(abs(times[0].0 - (60 * 25 / 23.976 - 2.5)) < 0.002, "\(times[0].0)")
    try expect(matches(out, "later"))
  }

  t.test("subtitle formats are recognised from their content") {
    try expectEqual(Subtext.sniffFormat("\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\nhi"), "srt")
    try expectEqual(Subtext.sniffFormat("WEBVTT\n\n00:01.000 --> 00:02.000\nhi"), "vtt")
    try expectEqual(Subtext.sniffFormat("[Script Info]\nTitle: x"), "ass")
    try expectEqual(Subtext.sniffFormat("{1}{25}hello"), "microdvd")
    try expectEqual(Subtext.sniffFormat("00:00:01,000 --> 00:00:02,000\nno cue numbers"), "srt")
    try expectEqual(Subtext.sniffFormat("#EXTM3U\nfile:///etc/passwd"), nil, "never handed to ffmpeg to guess")
  }

  t.test("moviehash adds the size and the 64-bit words of the first and last 64 KiB") {
    func hex(_ v: UInt64) -> String {
      let h = String(v, radix: 16)
      return String(repeating: "0", count: 16 - h.count) + h
    }
    let file = join(tmp, "ones.bin")
    FileManager.default.createFile(atPath: file, contents: Data(repeating: 1, count: 200_000))
    let word: UInt64 = 0x0101_0101_0101_0101
    try expectEqual(try OpenSubtitles.movieHash(file, size: 200_000), hex(200_000 &+ 16384 &* word))

    let zeros = join(tmp, "zeros.bin")
    FileManager.default.createFile(atPath: zeros, contents: Data(count: 150_000))
    try expectEqual(try OpenSubtitles.movieHash(zeros, size: 150_000), hex(150_000))
  }

  t.test("queries are sorted, lower-case, without empty values or leading zeros") {
    try expectEqual(
      OpenSubtitles.canonicalQuery([
        "season_number": "1", "languages": "EN", "query": "The X-Files", "moviehash": nil, "parent_imdb_id": "tt0106179", "episode_number": "2",
      ]),
      "episode_number=2&languages=en&parent_imdb_id=106179&query=the+x-files&season_number=1")
  }

  t.test("ranking puts the exact-file match first and partial or machine subtitles last") {
    let out = OpenSubtitles.rankResults([
      result(id: 1, downloads: 90000),
      result(id: 2, downloads: 10, hashMatch: true),
      result(id: 3, downloads: 500_000, foreignOnly: true),
      result(id: 4, downloads: 5000, machineTranslated: true),
      result(id: 5, downloads: 80000, fps: 23.976),
    ], fps: 23.976)
    try expectEqual(out.map(\.id), [2, 5, 1, 4, 3])
  }

  let api = FakeAPI()
  func client(base: String? = nil, envKey: String = "") -> OpenSubtitles {
    OpenSubtitles(
      store: JsonStore(join(tmp, "os-\(UUID().uuidString).json"), defaults: OSStoreData(), mode: 0o600), base: base ?? api.base, envKey: envKey)
  }

  t.test("an API key is checked before it is saved") {
    let os1 = client()
    let e = try await thrown { try await os1.setKey("wrongkey1234") }
    try expect(matches(message(e), "did not accept"), message(e))
    try expectEqual(os1.configured, false)
    try await os1.setKey(KEY)
    try expectEqual(os1.status().keyHint, "••••2345")
  }

  t.test("signing in keeps the token, never the password") {
    let os1 = client()
    try await os1.setKey(KEY)
    let e = try await thrown { _ = try await os1.login("mulder", "nope") }
    try expect(matches(message(e), "Wrong username or password"), message(e))
    let st = try await os1.login("mulder", "trustno1")
    try expectEqual(st.signedIn, true)
    try expectEqual(st.allowedDownloads, 20)
    os1.store.flush()
    let saved = (try? String(contentsOfFile: os1.store.file, encoding: .utf8)) ?? ""
    try expect(!saved.isEmpty && !matches(saved, "trustno1"), saved)
    var st2 = stat()
    try expect(stat(os1.store.file, &st2) == 0, "not saved")
    try expectEqual(st2.st_mode & 0o777, 0o600)
    await os1.logout()
    try expectEqual(os1.status().signedIn, false)
  }

  t.test("finds the show, searches by episode and downloads within the quota") {
    let os1 = client()
    try await os1.setKey(KEY)
    let show = try await os1.findShow("The X-Files", year: nil)
    try expectEqual(show?.id, 1, "the long-running show, not the revival")

    let results = OpenSubtitles.rankResults(try await os1.search([
      "languages": "en", "moviehash": "abcdef0123456789", "parent_feature_id": "\(show!.id)", "season_number": "1", "episode_number": "2",
    ]))
    try expectEqual(results.count, 2, "multi-CD subtitles are dropped")
    try expectEqual(results[0].id, 9001)
    try expectEqual(results[0].hashMatch, true)
    let q = api.seen.last { $0.path == "/api/v1/subtitles" }?.query
    try expectEqual(q, "episode_number=2&languages=en&moviehash=abcdef0123456789&parent_feature_id=1&season_number=1")

    let got = try await os1.download(9001)
    try expect(matches(got.text, "Hello, Mulder"), got.text)
    try expectEqual(os1.status().remaining, 1)
    _ = try await os1.download(9001)
    let e = try await thrown { _ = try await os1.download(9001) }
    let oe = e as? OSError
    try expect(oe?.status == 429 && matches(oe?.message ?? "", "allowed 5 subtitles.*Sign in"), "\(e)")
    try expectEqual(os1.status().remaining, 0)
  }

  t.test("requests are spaced to respect the rate limit") {
    let os1 = client()
    try await os1.setKey(KEY)
    let t0 = nowMs()
    try await withThrowingTaskGroup(of: Void.self) { g in
      for _ in 0..<3 { g.addTask { @MainActor in _ = try await os1.request("GET", "/infos/formats") } }
      try await g.waitForAll()
    }
    try expect(nowMs() - t0 >= 450, "took \(nowMs() - t0) ms")
  }

  t.test("connections the network resets are tried again") {
    let flaky = FlakyProxy(resets: 3, target: api.port)
    defer { flaky.stop() }
    let os1 = client(base: flaky.base)
    try await os1.setKey(KEY)
    try expectEqual(os1.configured, true)
    try expectEqual(flaky.connections, 4)

    let blocked = FlakyProxy(resets: .max, target: api.port)
    defer { blocked.stop() }
    let os2 = client(base: blocked.base, envKey: KEY)
    let e = try await thrown { _ = try await os2.request("GET", "/infos/formats") }
    try expect(matches(message(e), "keeps cutting the connection"), message(e))
    // URLSession itself makes three connections for a GET whose connection is
    // lost, so the client stops after three such requests, before a fourth
    // could go past its 10 tries (the JavaScript client made exactly 10).
    try expectEqual(blocked.connections, 9)
  }

  t.after { removeItem(tmp) }
}
