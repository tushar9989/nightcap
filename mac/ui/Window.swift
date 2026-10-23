import AppKit
import SwiftUI
import UniformTypeIdentifiers

// A window: the sidebar, the page it shows, the toolbar (back, forward,
// search), and the player over all of them.

enum Route: Equatable {
  case home, shows, movies
  case search(String)
  /// A show or film; `season` is the one chosen on its page.
  case title(String, season: Int?)

  /// Which page is showing.
  var key: String {
    switch self {
    case .home: "home"
    case .shows: "shows"
    case .movies: "movies"
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
  /// Pages to go back and forward to.
  private(set) var back: [Route] = []
  private(set) var forward: [Route] = []
  private(set) var searchText = ""
  /// The search field has the keyboard (kept in step by the view).
  var searchFocused = false
  /// Bumped to move the keyboard into the search field, or out of it.
  private(set) var focusSearchToken = 0
  private(set) var blurSearchToken = 0
  /// The sidebar list a title was last chosen from (0 Watching, 1 Shows or Movies),
  /// so the row clicked stays selected when a title is in both.
  var sideList = 1
  private(set) var player: PlayerModel?
  private(set) var toast: Toast?
  private(set) var isFullScreen = false
  /// Sidebar shown or hidden (the toolbar button, View › Hide Sidebar).
  var columns = NavigationSplitViewVisibility.automatic

  init(app: AppModel) {
    self.app = app
  }

  // ---- Pages ------------------------------------------------------------------------

  var canGoBack: Bool { !back.isEmpty }
  var canGoForward: Bool { !forward.isEmpty }

  func go(_ to: Route) {
    if player != nil { closePlayer() }
    // Going somewhere other than by typing leaves the search.
    if searchFocused { blurSearchToken += 1 }
    if case .search(let q) = to { searchText = q } else if !searchText.isEmpty { searchText = "" }
    sideList = 1
    visit(to)
  }

  /// Shows `to`, remembering the page it leaves for Back.
  private func visit(_ to: Route) {
    guard to != route else { return }
    back.append(route)
    if back.count > 100 { back.removeFirst() }
    forward = []
    route = to
  }

  func goBack() {
    guard let to = back.popLast() else { return }
    if player != nil { closePlayer() }
    forward.append(route)
    show(to)
  }

  func goForward() {
    guard let to = forward.popLast() else { return }
    if player != nil { closePlayer() }
    back.append(route)
    show(to)
  }

  /// Back or forward: the page, with the search it had.
  private func show(_ to: Route) {
    if case .search(let q) = to { searchText = q } else if !searchText.isEmpty { searchText = "" }
    route = to
  }

  /// The season chosen on a title page (not a step for Back).
  func setSeason(_ i: Int) {
    if case .title(let id, let s) = route, s != i { route = .title(id, season: i) }
  }

  func typeSearch(_ q: String) {
    // The field also hands back the text it already has (when it gains or
    // loses the keyboard, say): only an edit searches.
    guard q != searchText else { return }
    searchText = q
    if player != nil { closePlayer() }
    let searching: Bool
    if case .search = route { searching = true } else { searching = false }
    if q.jsTrimmed.isEmpty {
      // Emptied: back to the page the search started from.
      if searching { route = back.popLast() ?? .home }
    } else if searching {
      route = .search(q)
    } else {
      visit(.search(q))
    }
  }

  func focusSearch() { focusSearchToken += 1 }

  var sidebarHidden: Bool { columns == .detailOnly }

  func toggleSidebar() {
    withAnimation { columns = sidebarHidden ? .all : .detailOnly }
  }

  // ---- Player ---------------------------------------------------------------------------

  /// Plays a video, from `start` or where it was left.
  func play(_ fid: String, at start: Double? = nil) {
    if let p = player {
      p.open(fid, start: start)
    } else {
      if searchFocused { blurSearchToken += 1 }
      let p = PlayerModel(app: app, win: self)
      player = p
      p.open(fid, start: start)
      // The player covers the window; the toolbar would float over it.
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 180_000_000)
        if let self, self.player != nil { self.window?.toolbar?.isVisible = false }
      }
    }
    updateTitle()
  }

  func closePlayer() {
    guard let p = player else { return }
    p.close()
    player = nil
    window?.toolbar?.isVisible = true
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

  /// The Mac's folder chooser; the folder is added and scanned.
  func addFolder() {
    guard let window else { return }
    chooseFolder(for: window) { [weak self] path, kind in
      Task { @MainActor in await self?.add(path, kind: kind) }
    }
  }

  private func add(_ path: String, kind: String) async {
    toast("Adding and scanning…", ms: 120_000)
    do {
      try await app.addFolder(path, kind: kind)
      toast("Folder added")
      go(.home)
    } catch {
      toast(errorText(error), ms: 5000)
    }
  }

  /// The Settings window. What plays here pauses while it is in front.
  func openSettings(_ tab: SettingsTab? = nil) {
    if let p = player {
      p.closePanel()
      p.pause()
    }
    SettingsWindowController.show(app: app, tab: tab)
  }

  // ---- Videos from outside the library --------------------------------------------------------

  /// What File › Open offers: the videos a scan takes, and any other movie.
  static let videoTypes: [UTType] =
    [.movie] + Scanner.videoExt.sorted().map { UTType(filenameExtension: String($0.dropFirst()), conformingTo: .movie) ?? .movie }

  /// The Mac's file chooser, for videos to play.
  func chooseVideos() {
    guard let window, window.attachedSheet == nil else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = WindowModel.videoTypes
    panel.prompt = "Play"
    panel.message = "Choose videos to play. They don't need to be in your library."
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK else { return }
      let paths = panel.urls.map(\.path)
      Task { @MainActor in await self?.openFiles(paths) }
    }
  }

  /// Plays videos opened from Finder or File › Open: the first now, the others
  /// after it in name order (Next). Library videos play as they do from its pages.
  func openFiles(_ paths: [String]) async {
    var fids: [String] = []
    var unreadable: [String] = []
    for p in paths.stableSorted(by: { naturalCompare(basename($0), basename($1)) }) {
      if let fid = await app.engine.openPath(p) {
        if !fids.contains(fid) { fids.append(fid) }
      } else {
        unreadable.append(basename(p))
      }
    }
    app.refresh()
    app.opened(fids)
    if let first = fids.first { play(first) }
    if !unreadable.isEmpty {
      toast(unreadable.count == 1 ? "Could not open “\(unreadable[0])”" : "Could not open \(unreadable.count) of those files", ms: 5000)
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

/// The Mac's folder chooser, with what the folder contains: `done(path, kind)`.
@MainActor
func chooseFolder(for window: NSWindow, done: @escaping (String, String) -> Void) {
  guard window.attachedSheet == nil else { return }
  let panel = NSOpenPanel()
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.allowsMultipleSelection = false
  panel.canCreateDirectories = false
  panel.prompt = "Add Folder"
  panel.message = "Choose a folder with films or shows. Each subfolder of a show becomes a season."
  let popup = NSPopUpButton(frame: .zero, pullsDown: false)
  popup.addItems(withTitles: AppModel.folderKinds.map(\.label))
  let label = NSTextField(labelWithString: "Contains:")
  let row = NSStackView(views: [label, popup])
  row.orientation = .horizontal
  row.spacing = 8
  row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
  panel.accessoryView = row
  panel.isAccessoryViewDisclosed = true
  panel.beginSheetModal(for: window) { response in
    guard response == .OK, let url = panel.url else { return }
    done(url.path, AppModel.folderKinds[max(0, popup.indexOfSelectedItem)].kind)
  }
}

// ---- The window's view -------------------------------------------------------------------------

struct WindowRoot: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  @FocusState private var searchFocused: Bool

  var body: some View {
    @Bindable var win = win
    let search = Binding(get: { win.searchText }, set: { win.typeSearch($0) })
    NavigationSplitView(columnVisibility: $win.columns) {
      Sidebar()
        .navigationSplitViewColumnWidth(min: 190, ideal: 236, max: 340)
    } detail: {
      PageHost()
    }
    .searchable(text: search, placement: .toolbar, prompt: "Titles and episodes")
    .searchFocused($searchFocused)
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button { win.goBack() } label: { Label("Back", systemImage: "chevron.left") }
          .disabled(!win.canGoBack)
          .help("Back")
        Button { win.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
          .disabled(!win.canGoForward)
          .help("Forward")
      }
    }
    .overlay {
      if let p = win.player {
        PlayerView(player: p, fullScreen: win.isFullScreen)
          .ignoresSafeArea()
          .transition(.opacity)
      }
    }
    .overlay { ToastView().ignoresSafeArea() }
    .animation(.easeOut(duration: 0.2), value: win.player == nil)
    .onChange(of: searchFocused) { _, focused in win.searchFocused = focused }
    .onChange(of: win.focusSearchToken) { searchFocused = true }
    .onChange(of: win.blurSearchToken) { searchFocused = false }
  }
}

/// The page the route names.
private struct PageHost: View {
  @Environment(WindowModel.self) private var win
  @State private var width: CGFloat = 1000

  var body: some View {
    let route = win.route
    Group {
      switch route {
      case .home: HomePage()
      case .shows: GridPage(shows: true)
      case .movies: GridPage(shows: false)
      case .search(let q): SearchPage(query: q)
      case .title(let id, let season): TitlePage(titleId: id, season: season)
      }
    }
    .id(pageId(route))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .environment(\.metrics, Metrics(width: width))
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
  }

  /// A new page (scrolled to the top) for each title or search; not for a season.
  private func pageId(_ r: Route) -> String {
    if case .search(let q) = r { return "search:\(q)" }
    return r.key
  }
}

/// At the bottom of a page; in the player, at the top under the title, clear of the
/// bar, the subtitles and the cards.
private struct ToastView: View {
  @Environment(WindowModel.self) private var win

  var body: some View {
    let top = win.player != nil
    VStack {
      if let t = win.toast {
        Text(t.text)
          .font(.callout.weight(.medium))
          .multilineTextAlignment(.center)
          .padding(.vertical, 10)
          .padding(.horizontal, 18)
          .glassEffect(.regular, in: .capsule)
          .frame(maxWidth: 640)
          .id(t.id)
          .transition(.opacity.combined(with: .offset(y: top ? -16 : 16)))
      }
    }
    .padding(top ? .top : .bottom, top ? (win.isFullScreen ? 16 : 40) + 56 : 28)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: top ? .top : .bottom)
    .animation(.easeOut(duration: 0.25), value: win.toast)
    .allowsHitTesting(false)
  }
}

// ---- The NSWindow --------------------------------------------------------------------------------

@MainActor
final class WindowController: NSObject, NSWindowDelegate {
  /// Test builds draw windows as active even when the app isn't (pictures of the screen).
  static var drawActive = false

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
    window.toolbarStyle = .unified
    window.minSize = NSSize(width: 760, height: 500)
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.collectionBehavior.insert(.fullScreenPrimary)
    // The player shows its controls when the mouse moves anywhere over it.
    window.acceptsMouseMovedEvents = true
    window.delegate = self
    model.window = window

    let root = WindowRoot().environment(app).environment(model).activeLook(WindowController.drawActive)
    let host = NSHostingController(rootView: root)
    // The toolbar and search field come from the SwiftUI views.
    host.sceneBridgingOptions = [.toolbars]
    host.sizingOptions = []
    window.contentViewController = host
    window.setContentSize(size)

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
    // AppKit gives the search field the keyboard; the window starts without it
    // ("/" or ⌘F moves there).
    window.makeFirstResponder(nil)
  }

  func windowWillClose(_ note: Notification) {
    model.closePlayer()
    onClose?(self)
  }

  func windowDidEnterFullScreen(_ note: Notification) { model.fullScreenChanged(true) }
  func windowDidExitFullScreen(_ note: Notification) { model.fullScreenChanged(false) }
}

extension View {
  /// Draws as in the active window (test pictures only; see `WindowController.drawActive`).
  @ViewBuilder func activeLook(_ on: Bool) -> some View {
    if on { environment(\.controlActiveState, .key) } else { self }
  }
}
