import Foundation

// Stand-ins for the network in tests: a tiny HTTP server, and a proxy that
// resets connections the way some internet providers do.

/// A socket listening on 127.0.0.1 at a free port.
private func listenLocal() -> (fd: Int32, port: UInt16) {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  precondition(fd >= 0, "socket failed")
  var yes: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
  var addr = sockaddr_in()
  addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = 0
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  var len = socklen_t(MemoryLayout<sockaddr_in>.size)
  let bound = withUnsafeMutablePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
  }
  precondition(bound && listen(fd, 64) == 0, "could not listen")
  return (fd, UInt16(bigEndian: addr.sin_port))
}

/// Accepts connections until the socket is closed, handing each to `serve`.
private func acceptLoop(_ fd: Int32, _ serve: @escaping @Sendable (Int32) -> Void) {
  Thread.detachNewThread {
    while true {
      let c = accept(fd, nil, nil)
      if c < 0 {
        if errno == EINTR { continue }
        return
      }
      var yes: Int32 = 1
      setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
      DispatchQueue.global().async { serve(c) }
    }
  }
}

private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
  data.withUnsafeBytes { raw in
    var off = 0
    while off < raw.count {
      let n = send(fd, raw.baseAddress! + off, raw.count - off, 0)
      if n <= 0 { return false }
      off += n
    }
    return true
  }
}

/// An HTTP/1.1 server on 127.0.0.1: one request per connection, answered by
/// `handle` (one request at a time).
final class FakeHTTP: @unchecked Sendable {
  struct Request {
    let method: String
    let path: String
    /// The query string, without "?".
    let query: String
    /// Lower-case names.
    let headers: [String: String]
    let body: Data
  }

  struct Response {
    var status: Int
    /// No Content-Type header when nil.
    var type: String?
    var body: Data
  }

  let port: UInt16
  private let fd: Int32
  private let lock = NSLock()
  private let handle: (Request) -> Response

  init(_ handle: @escaping (Request) -> Response) {
    self.handle = handle
    (fd, port) = listenLocal()
    acceptLoop(fd) { [self] c in serve(c) }
  }

  private func serve(_ c: Int32) {
    defer { close(c) }
    var buf = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    func more() -> Bool {
      let n = recv(c, &chunk, chunk.count, 0)
      if n <= 0 { return false }
      buf.append(contentsOf: chunk[0..<n])
      return true
    }
    let end = Data("\r\n\r\n".utf8)
    while buf.range(of: end) == nil { if !more() { return } }
    let headEnd = buf.range(of: end)!
    let head = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    let line = head[0].split(separator: " ", maxSplits: 2).map(String.init)
    guard line.count >= 2 else { return }
    var headers: [String: String] = [:]
    for h in head.dropFirst() {
      guard let colon = h.firstIndex(of: ":") else { continue }
      headers[h[..<colon].lowercased()] = h[h.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let length = Int(headers["content-length"] ?? "") ?? 0
    while buf.count - headEnd.upperBound < length { if !more() { return } }
    let target = line[1].split(separator: "?", maxSplits: 1).map(String.init)
    let req = Request(
      method: line[0], path: target[0], query: target.count > 1 ? target[1] : "", headers: headers,
      body: buf.subdata(in: headEnd.upperBound..<(headEnd.upperBound + length)))
    let res = lock.withLock { handle(req) }
    var out = "HTTP/1.1 \(res.status) \(HTTPURLResponse.localizedString(forStatusCode: res.status))\r\n"
    if let type = res.type { out += "Content-Type: \(type)\r\n" }
    out += "Content-Length: \(res.body.count)\r\nConnection: close\r\n\r\n"
    _ = sendAll(c, Data(out.utf8) + res.body)
  }
}

/// Stands in for a network that resets the first `resets` connections right
/// after the client's first bytes; the others go through to `target`.
final class FlakyProxy: @unchecked Sendable {
  let port: UInt16
  private let fd: Int32
  private let lock = NSLock()
  private var resets: Int
  private var count = 0
  private var open = Set<Int32>()

  var base: String { "http://127.0.0.1:\(port)/api/v1" }
  /// Connections made to the proxy so far.
  var connections: Int { lock.withLock { count } }

  init(resets: Int, target: UInt16) {
    self.resets = resets
    (fd, port) = listenLocal()
    acceptLoop(fd) { [self] c in serve(c, target) }
  }

  private func serve(_ c: Int32, _ target: UInt16) {
    let reset = lock.withLock { () -> Bool in
      count += 1
      open.insert(c)
      if resets > 0 {
        resets -= 1
        return true
      }
      return false
    }
    if reset {
      var b: UInt8 = 0
      _ = recv(c, &b, 1, 0)
      // Closing with a zero linger time sends a reset, not an orderly close.
      var l = linger(l_onoff: 1, l_linger: 0)
      setsockopt(c, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
      drop(c)
      return
    }
    let up = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(up, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = target.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(up, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
    if !connected {
      Darwin.close(up)
      drop(c)
      return
    }
    lock.withLock { _ = open.insert(up) }
    // Both directions, each passing on the end of its stream.
    let group = DispatchGroup()
    for (from, to) in [(c, up), (up, c)] {
      group.enter()
      DispatchQueue.global().async {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
          let n = recv(from, &chunk, chunk.count, 0)
          if n <= 0 || !sendAll(to, Data(chunk[0..<n])) { break }
        }
        shutdown(to, SHUT_WR)
        group.leave()
      }
    }
    group.notify(queue: .global()) { [self] in
      drop(up)
      drop(c)
    }
  }

  private func drop(_ s: Int32) {
    let was = lock.withLock { open.remove(s) != nil }
    if was { Darwin.close(s) }
  }

  /// Stops listening and cuts every open connection (their threads then close them).
  func stop() {
    shutdown(fd, SHUT_RDWR)
    Darwin.close(fd)
    lock.withLock {
      for s in open { shutdown(s, SHUT_RDWR) }
    }
  }
}
