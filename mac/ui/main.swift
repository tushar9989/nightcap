import AppKit

// Nightcap: one Mac app, one process. Opening it shows a window and starts the
// engine (scans, intro and credits detection, previews); quitting it, or
// closing its last window, saves everything and ends every ffmpeg run it started.

// ---- The data of the earlier Nightcap ------------------------------------------------------

/// The earlier Nightcap (a Node engine) kept its data in the repository's data/
/// folder, which Info.plist's NightcapLegacyData names. The first launch copies
/// it (APFS clones: instant, and no extra space), so progress, detection
/// results, previews and downloaded subtitles carry over.
@MainActor
enum LegacyData {
  static let items = [
    "analysis.json", "library.json", "probe.json", "progress.json", "opensubtitles.json", "subs-downloaded.json",
    "subsync.json", "fingerprints", "subs", "subs-downloaded", "thumbs", "trickplay",
    // Last: once it is there, the copy is complete.
    "config.json",
  ]
  static let stagingPrefix = ".copying-"

  static func copyIfNeeded() {
    if let d = ProcessInfo.processInfo.environment["DATA_DIR"], !d.isEmpty { return }
    let fm = FileManager.default
    if fm.fileExists(atPath: Paths.data("config.json")) { return }
    guard let from = Bundle.main.object(forInfoDictionaryKey: "NightcapLegacyData") as? String, !from.isEmpty,
      fm.fileExists(atPath: join(from, "config.json"))
    else { return }
    ensureDir(Paths.data)
    // Left by a copy that was cut short.
    for name in (try? fm.contentsOfDirectory(atPath: Paths.data)) ?? [] where name.hasPrefix(stagingPrefix) {
      try? fm.removeItem(atPath: Paths.data(name))
    }
    let staging = Paths.data("\(stagingPrefix)\(getpid())")
    ensureDir(staging)
    defer { try? fm.removeItem(atPath: staging) }
    // Each item is copied whole into the staging folder, then moved into place,
    // so what is in place is always complete.
    var copied = 0
    for name in items {
      let src = join(from, name)
      let dst = Paths.data(name)
      guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst) else { continue }
      let staged = join(staging, name)
      guard clone(src, staged) else {
        logLine("[app] could not copy \(src); the earlier data was not taken over")
        return
      }
      do {
        try fm.moveItem(atPath: staged, toPath: dst)
        copied += 1
      } catch {
        logLine("[app] could not move \(name) into place: \(error.localizedDescription)")
        return
      }
    }
    logLine("[app] took over the earlier Nightcap's data from \(from) (\(copied) items)")
  }

  /// `cp -c -R`: a clone where the disk allows it, else a copy.
  private static func clone(_ src: String, _ dst: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/cp")
    p.arguments = ["-c", "-R", src, dst]
    do {
      try p.run()
    } catch {
      return false
    }
    p.waitUntilExit()
    return p.terminationStatus == 0
  }
}

// ---- The app --------------------------------------------------------------------------------

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  let app: AppModel
  private var controllers: [WindowController] = []
  private var monitors: [Any] = []
  private var refreshTimer: Timer?
  /// Videos Finder asked to open before the app had finished launching.
  private var pendingOpen: [URL]? = []

  init(app: AppModel) {
    self.app = app
    super.init()
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    buildMenu()
    ArtCache.shared.engine = app.engine
    watchEvents()
    openWindow()
    app.engine.start()
    // Durations found by probing don't announce themselves: look again now and then.
    let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.app.refresh() }
    }
    RunLoop.main.add(timer, forMode: .common)
    refreshTimer = timer
    NSApp.activate()
    let pending = pendingOpen ?? []
    pendingOpen = nil
    if !pending.isEmpty { openVideos(pending) }
  }

  /// Videos opened with Nightcap in Finder (Open With, a double click once it is
  /// the default, a drop on the Dock icon). On a launch this comes before
  /// applicationDidFinishLaunching.
  func application(_ application: NSApplication, open urls: [URL]) {
    if pendingOpen != nil {
      pendingOpen! += urls
    } else {
      openVideos(urls)
    }
  }

  func applicationWillTerminate(_ note: Notification) {
    refreshTimer?.invalidate()
    for c in controllers { c.model.closePlayer() }
    app.engine.shutdown()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  /// Clicking the Dock icon with no window open opens one.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if controllers.isEmpty {
      openWindow()
      return false
    }
    return true
  }

  // ---- Windows ---------------------------------------------------------------------------------

  @discardableResult
  private func openWindow() -> WindowController {
    let c = WindowController(app: app, after: controller(NSApp.keyWindow)?.window ?? controllers.last?.window)
    c.onClose = { [weak self] closed in self?.controllers.removeAll { $0 === closed } }
    controllers.append(c)
    c.show()
    return c
  }

  private func controller(_ window: NSWindow?) -> WindowController? {
    guard let window else { return nil }
    return controllers.first { $0.window === window }
  }

  @objc func newWindow(_ sender: Any?) {
    openWindow()
  }

  /// The window in front, even while another app is active (keyWindow is nil then).
  private func frontController() -> WindowController? {
    controller(NSApp.keyWindow) ?? NSApp.orderedWindows.lazy.compactMap { self.controller($0) }.first ?? controllers.last
  }

  /// Plays the videos in the window in front (replacing what plays there), else in a new one.
  private func openVideos(_ urls: [URL]) {
    let paths = urls.filter(\.isFileURL).map(\.path)
    guard !paths.isEmpty else { return }
    let c = frontController() ?? openWindow()
    if c.window.isMiniaturized { c.window.deminiaturize(nil) }
    c.window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    Task { await c.model.openFiles(paths) }
  }

  @objc func openVideosPanel(_ sender: Any?) {
    let c = frontController() ?? openWindow()
    c.window.makeKeyAndOrderFront(nil)
    c.model.chooseVideos()
  }

  @objc func showSettings(_ sender: Any?) {
    if let c = controller(NSApp.keyWindow) {
      c.model.openSettings()
    } else {
      SettingsWindowController.show(app: app, tab: nil)
    }
  }

  @objc func addFolder(_ sender: Any?) {
    let c = frontController() ?? openWindow()
    c.window.makeKeyAndOrderFront(nil)
    c.model.addFolder()
  }

  @objc func find(_ sender: Any?) {
    controller(NSApp.keyWindow)?.model.focusSearch()
  }

  @objc func goBack(_ sender: Any?) {
    controller(NSApp.keyWindow)?.model.goBack()
  }

  @objc func goForward(_ sender: Any?) {
    controller(NSApp.keyWindow)?.model.goForward()
  }

  @objc func toggleLibrarySidebar(_ sender: Any?) {
    controller(NSApp.keyWindow)?.model.toggleSidebar()
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let c = controller(NSApp.keyWindow)
    // Pages only: the player keeps its own keys.
    let page = c.map { $0.model.player == nil } ?? false
    switch item.action {
    case #selector(find(_:)): return page
    case #selector(goBack(_:)): return page && c!.model.canGoBack
    case #selector(goForward(_:)): return page && c!.model.canGoForward
    case #selector(toggleLibrarySidebar(_:)):
      item.title = c?.model.sidebarHidden == true ? "Show Sidebar" : "Hide Sidebar"
      return page
    default: return true
    }
  }

  // ---- Keys and the mouse ---------------------------------------------------------------------------

  private func watchEvents() {
    // The player's keys, and / for search.
    if let m = NSEvent.addLocalMonitorForEvents(
      matching: .keyDown,
      handler: { [weak self] e in
        guard let c = self?.controller(e.window) else { return e }
        return c.model.handleKey(e) ? nil : e
      })
    {
      monitors.append(m)
    }
    // Moving the mouse over the player shows its controls.
    if let m = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved, .leftMouseDragged],
      handler: { [weak self] e in
        if e.deltaX != 0 || e.deltaY != 0 { self?.controller(e.window)?.model.player?.showControls() }
        return e
      })
    {
      monitors.append(m)
    }
    // A click in one of the player's panels keeps it open.
    if let m = NSEvent.addLocalMonitorForEvents(
      matching: .leftMouseDown,
      handler: { [weak self] e in
        if let c = self?.controller(e.window), let p = c.model.player, let host = c.window.contentView {
          let pt = host.convert(e.locationInWindow, from: nil)
          p.mouseDown(at: CGPoint(x: pt.x, y: host.isFlipped ? pt.y : host.bounds.height - pt.y))
        }
        return e
      })
    {
      monitors.append(m)
    }
  }

  // ---- Menus --------------------------------------------------------------------------------------

  private func buildMenu() {
    func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
      let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
      i.keyEquivalentModifierMask = mods
      return i
    }
    let app = NSMenu()
    app.addItem(item("About Nightcap", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
    app.addItem(.separator())
    app.addItem(item("Settings…", #selector(showSettings(_:)), ","))
    app.addItem(.separator())
    app.addItem(item("Hide Nightcap", #selector(NSApplication.hide(_:)), "h"))
    app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
    app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
    app.addItem(.separator())
    app.addItem(item("Quit Nightcap", #selector(NSApplication.terminate(_:)), "q"))
    let file = NSMenu(title: "File")
    file.addItem(item("New Window", #selector(newWindow(_:)), "n"))
    file.addItem(item("Open…", #selector(openVideosPanel(_:)), "o"))
    file.addItem(item("Add Folder to Library…", #selector(addFolder(_:)), "o", [.command, .shift]))
    file.addItem(.separator())
    file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
    let edit = NSMenu(title: "Edit")
    edit.addItem(item("Undo", Selector(("undo:")), "z"))
    edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
    edit.addItem(.separator())
    edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
    edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
    edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
    edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
    edit.addItem(.separator())
    edit.addItem(item("Find", #selector(find(_:)), "f"))
    let view = NSMenu(title: "View")
    view.addItem(item("Back", #selector(goBack(_:)), "["))
    view.addItem(item("Forward", #selector(goForward(_:)), "]"))
    view.addItem(.separator())
    view.addItem(item("Hide Sidebar", #selector(toggleLibrarySidebar(_:)), "s", [.command, .control]))
    view.addItem(.separator())
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

// ---- Start ----------------------------------------------------------------------------------------

MainActor.assumeIsolated {
  LegacyData.copyIfNeeded()
  let app = NSApplication.shared
  let delegate = AppDelegate(app: AppModel())
  app.delegate = delegate
  app.setActivationPolicy(.regular)

  // `kill` (or logging out) quits like ⌘Q: progress is saved and ffmpeg runs end.
  signal(SIGTERM, SIG_IGN)
  let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
  sigterm.setEventHandler { NSApp.terminate(nil) }
  sigterm.resume()

  withExtendedLifetime((delegate, sigterm)) { app.run() }
}
