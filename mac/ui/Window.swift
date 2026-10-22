import AppKit
import SwiftUI

// A window: the sidebar, the page it shows, and the player over them.

enum Route: Equatable {
  case home, shows, movies, settings
  case search(String)
  /// A show or film; `season` is the tab chosen on its page.
  case title(String, season: Int?)

  /// Which page is showing (the sidebar marks it).
  var key: String {
    switch self {
    case .home: "home"
    case .shows: "shows"
    case .movies: "movies"
    case .settings: "settings"
    case .search: "search"
    case .title(let id, _): "title:\(id)"
    }
  }
}

struct Toast: Equatable {
  let id: Int
  let text: String
}

/// The text of an error, as the pages showed it.
func errorText(_ error: Error) -> String {
  (error as? MessageError)?.message ?? error.localizedDescription
}

@MainActor
@Observable
final class WindowModel {
  @ObservationIgnored let app: AppModel
  @ObservationIgnored weak var window: NSWindow?

  private(set) var route: Route = .home
  private(set) var searchText = ""
  /// The search field has the keyboard (kept in step by the view).
  var searchFocused = false
  /// Bumped to move the keyboard into the search field, or out of it.
  private(set) var focusSearchToken = 0
  private(set) var blurSearchToken = 0
  private(set) var player: PlayerModel?
  private(set) var toast: Toast?
  private(set) var isFullScreen = false

  init(app: AppModel) {
    self.app = app
  }

  // ---- Pages ------------------------------------------------------------------------

  func go(_ to: Route) { navigate(to, typing: false) }

  private func navigate(_ to: Route, typing: Bool) {
    var r = to
    if case .search(let q) = r, q.jsTrimmed.isEmpty { r = .home }
    if player != nil { closePlayer() }
    if r != route { route = r }
    // On the pages a click anywhere took the keyboard from the search field;
    // here buttons don't, so going somewhere other than by typing does.
    if !typing && searchFocused { blurSearchToken += 1 }
    if r.key != "search" && (!typing || !searchFocused) && !searchText.isEmpty { searchText = "" }
  }

  /// The season tab chosen on a title page.
  func setSeason(_ i: Int) {
    if case .title(let id, let s) = route, s != i { route = .title(id, season: i) }
  }

  func typeSearch(_ q: String) {
    // The field also hands back the text it already has (when it gains or
    // loses the keyboard, say): only an edit searches, as the pages' input event did.
    guard q != searchText else { return }
    searchText = q
    navigate(q.jsTrimmed.isEmpty ? .home : .search(q), typing: true)
  }

  /// Esc in the search field.
  func leaveSearch() {
    searchText = ""
    blurSearchToken += 1
    go(.home)
  }

  func focusSearch() { focusSearchToken += 1 }

  // ---- Player ---------------------------------------------------------------------------

  /// Plays a video, from `start` or where it was left.
  func play(_ fid: String, at start: Double? = nil) {
    if let p = player {
      p.open(fid, start: start)
    } else {
      let p = PlayerModel(app: app, win: self)
      player = p
      p.open(fid, start: start)
    }
    updateTitle()
  }

  func closePlayer() {
    guard let p = player else { return }
    p.close()
    player = nil
    updateTitle()
  }

  /// The window's name (Window menu, Mission Control): what's playing, else Nightcap.
  func updateTitle() {
    window?.title = player?.windowTitle ?? "Nightcap"
  }

  // ---- Toasts ---------------------------------------------------------------------------

  @ObservationIgnored private var toastTask: Task<Void, Never>?
  @ObservationIgnored private var toastSeq = 0

  func toast(_ text: String, ms: Int = 2600) {
    toastSeq += 1
    toast = Toast(id: toastSeq, text: text)
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
      if Task.isCancelled { return }
      self?.toast = nil
    }
  }

  // ---- Folders ------------------------------------------------------------------------------

  static let folderKinds: [(kind: String, label: String)] = [("auto", "Auto-detect"), ("shows", "TV shows"), ("movies", "Movies")]

  /// The Mac's folder chooser, with what the folder contains.
  func addFolder() {
    guard let window, window.attachedSheet == nil else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "Add Folder"
    panel.message = "Choose a folder with films or shows. Each subfolder of a show becomes a season."
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.addItems(withTitles: WindowModel.folderKinds.map(\.label))
    let label = NSTextField(labelWithString: "Contains:")
    let row = NSStackView(views: [label, popup])
    row.orientation = .horizontal
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    panel.accessoryView = row
    panel.isAccessoryViewDisclosed = true
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      let kind = WindowModel.folderKinds[max(0, popup.indexOfSelectedItem)].kind
      Task { @MainActor in await self?.add(url.path, kind: kind) }
    }
  }

  private func add(_ path: String, kind: String) async {
    toast("Adding and scanning…", ms: 120_000)
    do {
      app.apply(try await app.engine.addFolder(path, kind: kind))
      toast("Folder added")
      if route != .settings { go(.home) }
    } catch {
      toast(errorText(error), ms: 5000)
    }
  }

  // ---- Keys -------------------------------------------------------------------------------

  /// A key pressed in this window; true if it was used.
  func handleKey(_ e: NSEvent) -> Bool {
    if let p = player { return p.onKey(e) }
    let mods = e.modifierFlags.intersection([.command, .control, .option])
    if e.characters == "/" && mods.isEmpty && !(window?.firstResponder is NSText) {
      focusSearch()
      return true
    }
    return false
  }

  // ---- Full screen ---------------------------------------------------------------------------

  func fullScreenChanged(_ on: Bool) {
    isFullScreen = on
    player?.fullScreenChanged(on)
  }

  func toggleFullScreen() {
    window?.toggleFullScreen(nil)
  }

  /// Shows or hides the close / minimise / zoom buttons (hidden with the player's controls).
  /// Their container fades, not the buttons: AppKit takes a button at alpha 0 as
  /// disabled, and Close Window (⌘W) and Minimize (⌘M) would then do nothing.
  func setWindowButtons(visible: Bool) {
    guard let window else { return }
    var bars: [NSView] = []
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      guard let bar = window.standardWindowButton(kind)?.superview, !bars.contains(bar) else { continue }
      bars.append(bar)
    }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.3
      for bar in bars { bar.animator().alphaValue = visible ? 1 : 0 }
    }
  }
}

// ---- The window's view -------------------------------------------------------------------------

private struct MetricsKey: EnvironmentKey {
  static let defaultValue = Metrics(width: 1200)
}

extension EnvironmentValues {
  var metrics: Metrics {
    get { self[MetricsKey.self] }
    set { self[MetricsKey.self] = newValue }
  }
}

struct WindowRoot: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  @FocusState private var searchFocused: Bool

  var body: some View {
    // Only a reader inside the safe area sees the title bar's height (one that
    // ignores the safe area is told 0); the window's content fills the whole window.
    GeometryReader { safe in
      let top = safe.safeAreaInsets.top
      GeometryReader { geo in
        let m = Metrics(width: geo.size.width)
        ZStack(alignment: .topLeading) {
          HStack(spacing: 0) {
            Sidebar(topInset: top, searchFocused: $searchFocused)
              .frame(width: m.sideWidth)
            PageHost()
              .padding(.top, top)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          if let p = win.player {
            PlayerView(player: p, topInset: top)
              .transition(.opacity)
          }
          ToastView(offset: win.player == nil ? m.sideWidth / 2 : 0)
        }
        .environment(\.metrics, m)
        .frame(width: geo.size.width, height: geo.size.height)
      }
      .ignoresSafeArea()
    }
    .background(Theme.bg)
    .foregroundStyle(Theme.text)
    .preferredColorScheme(.dark)
    .animation(.easeOut(duration: 0.2), value: win.player == nil)
    .onChange(of: searchFocused) { _, focused in win.searchFocused = focused }
    .onChange(of: win.focusSearchToken) { searchFocused = true }
    .onChange(of: win.blurSearchToken) { searchFocused = false }
  }
}

/// The page the route names.
private struct PageHost: View {
  @Environment(WindowModel.self) private var win

  var body: some View {
    let route = win.route
    Group {
      switch route {
      case .home: HomePage()
      case .shows: GridPage(shows: true)
      case .movies: GridPage(shows: false)
      case .search(let q): SearchPage(query: q)
      case .title(let id, let season): TitlePage(titleId: id, season: season)
      case .settings: SettingsPage()
      }
    }
    .id(pageId(route))
  }

  /// A new page (scrolled to the top) for each title or search; not for a season tab.
  private func pageId(_ r: Route) -> String {
    if case .search(let q) = r { return "search:\(q)" }
    return r.key
  }
}

private struct ToastView: View {
  @Environment(WindowModel.self) private var win
  var offset: CGFloat

  var body: some View {
    VStack {
      Spacer()
      if let t = win.toast {
        Text(t.text)
          .font(.system(size: 13.5, weight: .semibold))
          .foregroundStyle(Color(hex: 0x111111))
          .multilineTextAlignment(.center)
          .padding(.vertical, 9)
          .padding(.horizontal, 16)
          .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0xf2f2f4)))
          .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
          .frame(maxWidth: 640)
          .transition(.opacity.combined(with: .offset(y: 20)))
      }
    }
    .padding(.bottom, 28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .offset(x: offset)
    .animation(.easeOut(duration: 0.25), value: win.toast == nil)
    .allowsHitTesting(false)
  }
}

// ---- The NSWindow --------------------------------------------------------------------------------

@MainActor
final class WindowController: NSObject, NSWindowDelegate {
  let window: NSWindow
  let model: WindowModel
  var onClose: ((WindowController) -> Void)?

  init(app: AppModel, after front: NSWindow?) {
    model = WindowModel(app: app)
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(1440, screen.width * 0.9), height: min(900, screen.height * 0.9))
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    super.init()
    window.title = "Nightcap"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.backgroundColor = Theme.nsBackground
    window.appearance = NSAppearance(named: .darkAqua)
    window.minSize = NSSize(width: 720, height: 480)
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.collectionBehavior.insert(.fullScreenPrimary)
    // The player shows its controls when the mouse moves anywhere over it.
    window.acceptsMouseMovedEvents = true
    window.delegate = self
    model.window = window

    let host = NSHostingView(rootView: WindowRoot().environment(app).environment(model))
    host.sizingOptions = []
    window.contentView = host

    if let front {
      window.setFrame(front.frame, display: false)
      window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
    } else {
      window.center()
      window.setFrameUsingName("Nightcap")
      window.setFrameAutosaveName("Nightcap")
    }
  }

  func show() {
    window.makeKeyAndOrderFront(nil)
    // AppKit gives the first text field, the search, the keyboard; the pages
    // started without it ("/" or ⌘F moves there).
    window.makeFirstResponder(nil)
  }

  func windowWillClose(_ note: Notification) {
    model.closePlayer()
    onClose?(self)
  }

  func windowDidEnterFullScreen(_ note: Notification) { model.fullScreenChanged(true) }
  func windowDidExitFullScreen(_ note: Notification) { model.fullScreenChanged(false) }
}
