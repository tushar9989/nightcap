// Nightcap's Mac app: native windows around the engine (server/index.js),
// drawn by the WebKit that comes with macOS. No browser is involved.
// Built by scripts/make-mac-app.sh, which records in Info.plist where the
// repo and Node are.
//
// Lifetime (see "Lifetime" in server/index.js):
// - the app starts the engine as its child and stops it when it quits, or when
//   its last window closes; the engine then ends its ffmpeg runs;
// - if the app is killed, its pages close and the engine quits a few seconds later;
// - if the engine quits on purpose (Settings > Quit Nightcap), the app quits too;
//   if it crashes, the app starts it again and the pages pick up where they were.

import AppKit
import WebKit

let env = ProcessInfo.processInfo.environment
let plist = Bundle.main.infoDictionary ?? [:]
let root = env["NIGHTCAP_ROOT"] ?? plist["NightcapRoot"] as? String ?? ""
let nodePath = env["NIGHTCAP_NODE"] ?? plist["NightcapNode"] as? String ?? "/opt/homebrew/bin/node"
let port = env["PORT"] ?? "8484"
let dataDir = env["DATA_DIR"] ?? "\(root)/data"
let home = URL(string: "http://localhost:\(port)/")!
let background = NSColor(srgbRed: 0x18 / 255, green: 0x18 / 255, blue: 0x1a / 255, alpha: 1)

func isOurs(_ url: URL) -> Bool {
  (url.host == "localhost" || url.host == "127.0.0.1") && url.port == Int(port)
}

// ---- Talking to the engine ----------------------------------------------------------

let http: URLSession = {
  let c = URLSessionConfiguration.ephemeral
  c.connectionProxyDictionary = [:]
  c.requestCachePolicy = .reloadIgnoringLocalCacheData
  return URLSession(configuration: c)
}()

func ping() async -> String? {
  let req = URLRequest(url: home.appendingPathComponent("api/ping"), timeoutInterval: 0.5)
  guard let (data, res) = try? await http.data(for: req), (res as? HTTPURLResponse)?.statusCode == 200 else { return nil }
  return String(decoding: data, as: UTF8.self)
}

func post(_ path: String) async {
  var req = URLRequest(url: home.appendingPathComponent(path), timeoutInterval: 1)
  req.httpMethod = "POST"
  req.setValue("application/json", forHTTPHeaderField: "Content-Type") // the engine refuses other POSTs
  req.httpBody = Data("{}".utf8)
  _ = try? await http.data(for: req)
}

func sleep(ms: UInt64) async {
  try? await Task.sleep(nanoseconds: ms * 1_000_000)
}

@MainActor
final class Engine {
  var onReady: () -> Void = {}
  var onGone: (_ problem: String?) -> Void = { _ in } // nil: it quit on purpose
  private(set) var ready = false
  private var process: Process?
  private var stopping = false
  private var crashes: [Date] = []

  func start() {
    ready = false
    Task { @MainActor in
      await replaceLeftovers()
      guard launch() else { return }
      for _ in 0..<300 { // up to 15 s; it normally answers in a fraction of a second
        if await ping()?.contains(#""app":"nightcap""#) == true {
          ready = true
          return onReady()
        }
        if process == nil { return } // ended() has dealt with it
        await sleep(ms: 50)
      }
      onGone("Nightcap's engine did not start. Its log is \(dataDir)/server.log.")
    }
  }

  // An engine still running from before (an older Nightcap, or one whose app
  // was killed) is asked to quit, so this one runs the code on disk. The window
  // of the old browser-based Nightcap is closed too (SIGTERM: it saves its state).
  private func replaceLeftovers() async {
    if let answer = await ping(), answer.contains(#""app":"nightcap""#) || answer.contains(#""app":"marquee""#) {
      await post("api/quit")
      for _ in 0..<50 {
        if await ping() == nil { break }
        await sleep(ms: 100)
      }
    }
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["-TERM", "-f", "--", "--user-data-dir=\(dataDir)/window-profile"]
    try? pkill.run()
  }

  private func launch() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: nodePath)
    p.arguments = ["\(root)/server/index.js", "--no-open", "--quit-when-closed"]
    p.currentDirectoryURL = URL(fileURLWithPath: root)
    var e = env
    e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    e["PORT"] = port
    p.environment = e
    p.standardInput = FileHandle.nullDevice
    let logPath = "\(dataDir)/server.log"
    try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
    if let log = FileHandle(forWritingAtPath: logPath) {
      log.seekToEndOfFile()
      let stamp = DateFormatter()
      stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
      log.write(Data("[app] \(stamp.string(from: Date())) starting the engine\n".utf8))
      p.standardOutput = log
      p.standardError = log
    }
    p.terminationHandler = { [weak self] ended in Task { @MainActor in self?.ended(ended) } }
    do {
      try p.run()
      process = p
      return true
    } catch {
      onGone("Could not start Node (\(nodePath)): \(error.localizedDescription)")
      return false
    }
  }

  private func ended(_ p: Process) {
    guard p === process, !stopping else { return }
    process = nil
    ready = false
    if p.terminationReason == .exit && p.terminationStatus == 0 { return onGone(nil) }
    crashes = crashes.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
    if crashes.count > 3 { return onGone("Nightcap's engine keeps stopping. Its log is \(dataDir)/server.log.") }
    start() // open pages reconnect to the new engine by themselves
  }

  // SIGTERM: the engine saves its state and ends its ffmpeg runs.
  func stop() {
    stopping = true
    guard let p = process, p.isRunning else { return }
    p.terminate()
    let deadline = Date().addingTimeInterval(2)
    while p.isRunning && Date() < deadline { usleep(20_000) }
    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
  }
}

// ---- Windows ------------------------------------------------------------------------

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
  let engine = Engine()
  var windows: [NSWindow] = []
  var waiting: [WKWebView: URL] = [:] // windows opened before the engine answered

  func applicationDidFinishLaunching(_ note: Notification) {
    buildMenu()
    engine.onReady = { [weak self] in
      guard let self else { return }
      for (web, url) in waiting { web.load(URLRequest(url: url)) }
      waiting = [:]
    }
    engine.onGone = { problem in
      if let problem {
        let alert = NSAlert()
        alert.messageText = "Nightcap stopped"
        alert.informativeText = problem
        alert.runModal()
      }
      NSApp.terminate(nil)
    }
    openWindow(home)
    engine.start()
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationWillTerminate(_ note: Notification) {
    engine.stop()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

  // Clicking the Dock icon with no window open.
  func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { openWindow(home) }
    return true
  }

  @objc func newWindow(_ sender: Any?) {
    openWindow(home)
  }

  @objc func reloadPage(_ sender: Any?) {
    (NSApp.keyWindow?.contentView as? WKWebView)?.reload()
  }

  func openWindow(_ url: URL) {
    let config = WKWebViewConfiguration()
    config.mediaTypesRequiringUserActionForPlayback = [] // autoplay of the next episode and previews
    config.preferences.isElementFullscreenEnabled = true // the player's full screen button
    config.applicationNameForUserAgent = "Nightcap"
    let web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = self
    web.uiDelegate = self
    web.underPageBackgroundColor = background
    web.isHidden = true // until the page has loaded, instead of a white flash
    if #available(macOS 13.3, *) { web.isInspectable = true } // Safari > Develop

    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(1440, screen.width * 0.9), height: min(900, screen.height * 0.9))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "Nightcap"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.backgroundColor = background
    window.appearance = NSAppearance(named: .darkAqua)
    window.minSize = NSSize(width: 720, height: 480)
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.contentView = web
    window.delegate = self
    if let front = windows.last {
      window.setFrame(front.frame, display: false)
      window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
    } else {
      window.center()
      window.setFrameUsingName("Nightcap")
      window.setFrameAutosaveName("Nightcap")
    }
    windows.append(window)
    window.makeKeyAndOrderFront(nil)

    if engine.ready { web.load(URLRequest(url: url)) } else { waiting[web] = url }
  }

  func windowWillClose(_ note: Notification) {
    guard let window = note.object as? NSWindow else { return }
    if let web = window.contentView as? WKWebView { waiting[web] = nil }
    windows.removeAll { $0 === window }
  }

  // Our pages stay in the window; links out (OpenSubtitles) open in the usual browser.
  func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    guard let url = action.request.url else { return decisionHandler(.cancel) }
    if isOurs(url) || ["about", "blob", "data"].contains(url.scheme ?? "") { return decisionHandler(.allow) }
    NSWorkspace.shared.open(url)
    decisionHandler(.cancel)
  }

  // target="_blank"
  func webView(_ web: WKWebView, createWebViewWith config: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = action.request.url {
      if isOurs(url) { openWindow(url) } else { NSWorkspace.shared.open(url) }
    }
    return nil
  }

  func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
    web.isHidden = false
  }

  // The engine is restarting: try again shortly.
  func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    let e = error as NSError
    guard e.domain == NSURLErrorDomain, e.code != NSURLErrorCancelled else { return }
    let url = e.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? home
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak web] in
      guard let self, let web else { return }
      if engine.ready { web.load(URLRequest(url: url)) } else { waiting[web] = url }
    }
  }

  func webViewWebContentProcessDidTerminate(_ web: WKWebView) {
    web.reload()
  }

  func buildMenu() {
    func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
      let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
      i.keyEquivalentModifierMask = mods
      return i
    }
    let app = NSMenu()
    app.addItem(item("About Nightcap", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
    app.addItem(.separator())
    app.addItem(item("Hide Nightcap", #selector(NSApplication.hide(_:)), "h"))
    app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
    app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
    app.addItem(.separator())
    app.addItem(item("Quit Nightcap", #selector(NSApplication.terminate(_:)), "q"))
    let file = NSMenu(title: "File")
    file.addItem(item("New Window", #selector(newWindow(_:)), "n"))
    file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
    let edit = NSMenu(title: "Edit")
    edit.addItem(item("Undo", Selector(("undo:")), "z"))
    edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
    edit.addItem(.separator())
    edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
    edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
    edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
    edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
    let view = NSMenu(title: "View")
    view.addItem(item("Reload", #selector(reloadPage(_:)), "r"))
    view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
    let window = NSMenu(title: "Window")
    window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
    window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
    window.addItem(.separator())
    window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
    let bar = NSMenu()
    for (title, menu) in [("Nightcap", app), ("File", file), ("Edit", edit), ("View", view), ("Window", window)] {
      let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      top.submenu = menu
      bar.addItem(top)
    }
    NSApp.mainMenu = bar
    NSApp.windowsMenu = window
  }
}

// ---- Start ----------------------------------------------------------------------------

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)

  // `kill` (or logging out) quits like ⌘Q, so the engine is stopped too.
  signal(SIGTERM, SIG_IGN)
  let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
  sigterm.setEventHandler { NSApp.terminate(nil) }
  sigterm.resume()

  app.run()
}
