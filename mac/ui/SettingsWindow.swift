import AppKit
import SwiftUI

// Settings, in a window of its own as Mac apps have it: Library (folders,
// detection, previews), Playback, and Subtitles (with OpenSubtitles.com).

enum SettingsTab: Int, CaseIterable {
  case library, playback, subtitles

  var label: String {
    switch self {
    case .library: "Library"
    case .playback: "Playback"
    case .subtitles: "Subtitles"
    }
  }

  var symbol: String {
    switch self {
    case .library: "books.vertical"
    case .playback: "play.rectangle"
    case .subtitles: "captions.bubble"
    }
  }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private static var shared: SettingsWindowController?

  let window: NSWindow
  private let tabs = NSTabViewController()

  /// Opens Settings (one window for the app), at `tab` if given.
  static func show(app: AppModel, tab: SettingsTab?) {
    let c = shared ?? SettingsWindowController(app: app)
    shared = c
    if let tab { c.tabs.selectedTabViewItemIndex = tab.rawValue }
    c.window.makeKeyAndOrderFront(nil)
  }

  private init(app: AppModel) {
    tabs.tabStyle = .toolbar
    for tab in SettingsTab.allCases {
      let page: AnyView =
        switch tab {
        case .library: AnyView(LibrarySettings())
        case .playback: AnyView(PlaybackSettings())
        case .subtitles: AnyView(SubtitleSettings())
        }
      let host = NSHostingController(rootView: page.environment(app).activeLook(WindowController.drawActive))
      host.sizingOptions = []
      host.title = tab.label
      let item = NSTabViewItem(viewController: host)
      item.label = tab.label
      item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
      tabs.addTabViewItem(item)
    }
    window = NSWindow(contentViewController: tabs)
    super.init()
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.setContentSize(NSSize(width: SettingsMetrics.width, height: SettingsMetrics.height))
    window.center()
    window.setFrameAutosaveName("Settings")
    window.delegate = self
  }
}

enum SettingsMetrics {
  static let width: CGFloat = 620
  static let height: CGFloat = 600
}

/// A tab's page: a grouped form, the window's size.
private struct SettingsForm<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .font(.app(.body))
      .frame(width: SettingsMetrics.width, height: SettingsMetrics.height)
  }
}

// A grouped form sets its own type on section headers and on the line under a setting's
// name, over the window's: the sizes macOS gives them (13 pt semibold and 11 pt, measured),
// in the app's face.
private func header(_ text: String) -> Text { Text(text).font(.app(.body, weight: .semibold)) }
private func detail(_ text: String) -> Text { Text(text).font(.app(.subheadline)) }

/// A note under a setting, or a line of status: small and secondary.
private struct Note: View {
  let text: String
  var color: Color? = nil

  init(_ text: String, color: Color? = nil) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text)
      .font(.app(.callout))
      .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
      .fixedSize(horizontal: false, vertical: true)
  }
}

// ---- Library -------------------------------------------------------------------------------------

private struct LibrarySettings: View {
  @Environment(AppModel.self) private var app
  @State private var busy = false
  @State private var note: (text: String, failed: Bool)?

  var body: some View {
    let lib = app.lib
    SettingsForm {
      Section {
        if lib.folders.isEmpty {
          Text("No folders yet.").foregroundStyle(.secondary)
        } else {
          ForEach(lib.folders, id: \.id) { f in
            FolderRow(folder: f, status: lib.folderStatus[f.id]) { text, failed in note = (text, failed) }
          }
        }
        HStack(spacing: 8) {
          Button("Add Folder…") { addFolder() }
          Button("Scan Now") { Task { await scanNow() } }
            .disabled(busy || lib.folders.isEmpty)
          Spacer(minLength: 12)
          if let note { Note(note.text, color: note.failed ? Theme.error : nil).lineLimit(2) }
        }
      } header: {
        header("Folders")
      } footer: {
        Note("Each subfolder of a show becomes a season. Folders are scanned when you press Scan Now or add or change a folder, and your progress is kept even while a drive is unplugged.")
      }

      Section {
        WorkRow(
          kind: .detect, title: "Detect intros and credits in every show",
          detail: "Only when you ask: here, or for one show from its page (···). Uses some CPU while it runs.")
        AnalysisProgress(status: app.status.analysis, work: app.status.work)
      } header: {
        header("Intros and Credits")
      } footer: {
        Note("Runs on this Mac. The first and last minutes of each episode are compared with the rest of its season by sound: music they share is the intro or the end credits. Films are checked for text on black. Results are saved, so only new episodes are analysed. Episodes still downloading wait until they are complete. Pause stops the work where it is; it goes on from there when you resume, also after quitting.")
      }

      Section {
        Toggle(isOn: Binding(get: { lib.settings.previews }, set: { update(SettingsPatch(previews: $0)) })) {
          Text("Make previews for what you play")
          detail("The video playing and the one after it. About 2 MB per episode.")
        }
        WorkRow(
          kind: .previews, title: "Make previews for every show",
          detail: "Only when you ask: here, or for one show from its page (···).")
        PreviewsProgress(status: app.status.previews, work: app.status.work)
      } header: {
        header("Previews")
      } footer: {
        Note("A frame every few seconds of each episode and film, shown above the seek bar, when you rest the pointer on an episode, and for the next episode at the end credits. Made for what you play and what you ask for, never for videos still downloading. Kept in ~/Library/Caches/Nightcap with the app's other made files, each removed after \(Cache.keepDays) days unused.")
      }

      if !lib.ffmpeg {
        Section {
          Label {
            Text("ffmpeg was not found, so intro and credits detection, previews, subtitles inside videos and syncing to the dialogue are off. Videos still play.")
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
          }
        }
      }
    }
  }

  private func update(_ patch: SettingsPatch) {
    _ = app.engine.updateSettings(patch)
    app.refresh()
  }

  private func addFolder() {
    guard let window = NSApp.keyWindow else { return }
    chooseFolder(for: window) { path, kind in
      Task { @MainActor in
        busy = true
        note = ("Adding and scanning…", false)
        do {
          try await app.addFolder(path, kind: kind)
          note = ("Folder added", false)
        } catch {
          note = (errorText(error), true)
        }
        busy = false
      }
    }
  }

  private func scanNow() async {
    busy = true
    note = ("Scanning…", false)
    app.apply(await app.engine.scan())
    busy = false
    note = ("Library updated", false)
  }
}

private struct FolderRow: View {
  @Environment(AppModel.self) private var app
  let folder: Folder
  let status: FolderStatus?
  let report: (String, Bool) -> Void

  var body: some View {
    let offline = status.map { !$0.online } == true
    let stat = status.map { st in st.online ? "\(st.titles ?? 0) titles · \(st.videos ?? 0) videos" : st.error ?? "" }
    HStack(spacing: 12) {
      Image(systemName: offline ? "externaldrive.badge.xmark" : "folder.fill")
        .font(.title2)
        .foregroundStyle(offline ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(.tint))
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(basename(folder.path)).lineLimit(1)
        Text(folder.path)
          .font(.app(.caption))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .help(folder.path)
        Text(stat ?? "Not scanned yet")
          .font(.app(.caption))
          .foregroundStyle(offline ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(.secondary))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Picker("Contains", selection: Binding(get: { folder.kind }, set: { kind in Task { await setKind(kind) } })) {
        ForEach(AppModel.folderKinds, id: \.kind) { Text($0.label).tag($0.kind) }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()
      .help("What this folder contains")
      ArmedButton(title: "Remove", armedTitle: "Remove?", help: "Remove from the library (the files stay where they are)") {
        Task { await remove() }
      }
    }
    .padding(.vertical, 2)
  }

  private func setKind(_ kind: String) async {
    guard kind != folder.kind else { return }
    report("Rescanning…", false)
    do {
      app.apply(try await app.engine.setFolderKind(folder.id, kind))
      report("Library updated", false)
    } catch {
      report(errorText(error), true)
    }
  }

  private func remove() async {
    app.apply(await app.engine.removeFolder(folder.id))
    report("Folder removed (its files are untouched)", false)
  }
}

/// Start for every show, and Pause / Resume while work asked for is left
/// (one pause for detection and previews: everything running stops).
private struct WorkRow: View {
  @Environment(AppModel.self) private var app
  let kind: Engine.WorkKind
  let title: String
  let detail: String

  var body: some View {
    let w = app.status.work
    let left = kind == .detect ? w.detect : w.previews
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.app(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      if !left.isEmpty {
        Button(w.paused ? "Resume" : "Pause") {
          app.engine.pauseWork(!w.paused)
          app.refresh()
        }
        .help(w.paused ? "Go on from where it stopped" : "Stop the work where it is, until you resume")
      }
      Button(left.isEmpty ? "Start" : "Add All") {
        app.engine.startWork(kind)
        app.refresh()
      }
      .disabled(!app.status.ffmpeg || (!left.isEmpty && left.count >= app.lib.titles.count))
      .help(left.isEmpty ? "Start now" : "Include every show")
    }
  }
}

/// What is left of the work asked for: "2 shows to go · 3 videos still downloading · paused".
private func workLeft(_ titles: Int, arriving: Int, _ w: WorkStatus, noun: String) -> String {
  [
    titles > 0 ? "\(titles) \(titles == 1 ? noun : noun + "s") to go" : nil,
    arriving > 0 ? "\(arriving) \(arriving == 1 ? "video" : "videos") still downloading" : nil,
    w.checking > 0 ? "checking \(w.checking) \(w.checking == 1 ? "download" : "downloads")" : nil,
    titles > 0 && w.paused ? "paused" : nil,
  ].compactMap { $0 }.joined(separator: " · ")
}

private struct AnalysisProgress: View {
  let status: Analyzer.Status
  let work: WorkStatus

  var body: some View {
    let a = status
    let left = workLeft(work.detect.count, arriving: work.detectArriving, work, noun: "title")
    let done = a.analyzedFiles >= a.totalFiles ? "All \(a.totalFiles) videos analysed" : "\(a.analyzedFiles) of \(a.totalFiles) videos analysed"
    let text =
      !a.available
      ? "Needs ffmpeg."
      : work.paused && !work.detect.isEmpty
        ? "Paused\(a.current.map { " in \($0.label) (\($0.done)/\($0.total))" } ?? "") · \(left)"
        : a.current.map { "Analysing \($0.label) (\($0.done)/\($0.total))… \(left)" }
          ?? (left.isEmpty ? "\(done)." : "\(done) · \(left)")
    VStack(alignment: .leading, spacing: 6) {
      ProgressView(value: a.totalFiles != 0 ? Double(a.analyzedFiles) / Double(a.totalFiles) : 0)
      Note(text).lineLimit(1).truncationMode(.middle)
    }
  }
}

private struct PreviewsProgress: View {
  let status: Trickplay.Status
  let work: WorkStatus

  var body: some View {
    let p = status
    let bytes = Double(p.bytes)
    let size = bytes >= 1e9 ? "\(toFixed(bytes / 1e9, 1)) GB" : "\(jsNumber(jsRound(bytes / 1e6))) MB"
    let left = workLeft(work.previews.count, arriving: work.previewsArriving, work, noun: "title")
    let text =
      !p.available
      ? "Needs ffmpeg."
      : p.current != nil && !work.paused
        ? "Making previews for \(p.current!)… \(p.done) of \(p.total) asked for · \(size)"
        : left.isEmpty
          ? "Previews kept: \(size)"
          : "\(p.done) of \(p.total) asked for · \(left) · \(size)"
    VStack(alignment: .leading, spacing: 6) {
      ProgressView(value: p.total != 0 ? Double(p.done) / Double(p.total) : 0)
      Note(text).lineLimit(1).truncationMode(.middle)
    }
  }
}

// ---- Playback -------------------------------------------------------------------------------------

private struct PlaybackSettings: View {
  @Environment(AppModel.self) private var app
  @AppStorage(Prefs.pictureKey) private var picture = Prefs.defaultPicture

  static let keys: [(String, String)] = [
    ("Play or pause", "Space"),
    ("Back or forward 10 seconds", "← →"),
    ("Back or forward 30 seconds", "⇧← ⇧→"),
    ("Jump to 0%, 10% … 90%", "0 – 9"),
    ("Volume, up to 200%", "↑ ↓"),
    ("Mute", "M"),
    ("Slower or faster", "[ ]"),
    ("Speed in fine steps", "{ }"),
    ("Normal speed", "="),
    ("Skip intro", "S"),
    ("Next episode", "N"),
    ("Subtitles on or off", "C"),
    ("Subtitles earlier or later", "G H"),
    ("Full screen", "F"),
    ("Leave the player", "Esc"),
  ]

  var body: some View {
    let s = app.lib.settings
    SettingsForm {
      Section {
        Toggle(isOn: Binding(get: { s.autoSkipIntro }, set: { update(SettingsPatch(autoSkipIntro: $0)) })) {
          Text("Skip intros automatically")
          detail("Otherwise a Skip Intro button appears during the intro.")
        }
        Toggle(isOn: Binding(get: { s.autoplayNext }, set: { update(SettingsPatch(autoplayNext: $0)) })) {
          Text("Play the next episode automatically")
          detail("When the end credits start, count down and play the next episode.")
        }
        // A value set some other way (the settings file) is listed too, so the menu shows what is in use.
        let current = s.nextCountdown
        let stops = [5, 10, 15, 20, 30].contains(current) ? [5, 10, 15, 20, 30] : ([5, 10, 15, 20, 30] + [current]).sorted()
        Picker("Countdown", selection: Binding(get: { current }, set: { update(SettingsPatch(nextCountdown: Double($0))) })) {
          ForEach(stops, id: \.self) { Text("\($0) seconds").tag($0) }
        }
        .disabled(!s.autoplayNext)
      } header: {
        header("Episodes")
      }

      Section {
        Picker(selection: $picture) {
          ForEach(PictureMode.allCases, id: \.self) { Text($0.label).tag($0) }
        } label: {
          Text("Quality")
          detail("Sharper doubles standard-definition video with Apple’s super resolution as it plays, on this Mac. Sharpening adds bite, and some grain.")
        }
      } header: {
        header("Picture")
      }

      Section {
        ForEach(PlaybackSettings.keys, id: \.0) { what, key in
          LabeledContent(what) {
            Text(key).font(.body.monospaced()).foregroundStyle(.secondary)
          }
        }
      } header: {
        header("Keyboard")
      }
    }
  }

  private func update(_ patch: SettingsPatch) {
    _ = app.engine.updateSettings(patch)
    app.refresh()
  }
}

// ---- Subtitles and OpenSubtitles.com --------------------------------------------------------------

private struct SubtitleSettings: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let s = app.lib.settings
    SettingsForm {
      Section {
        Picker(selection: Binding(get: { s.subtitleLanguage }, set: { update(SettingsPatch(subtitleLanguage: $0)) })) {
          ForEach(subLanguages(s.subtitleLanguage), id: \.code) { Text($0.name).tag($0.code) }
        } label: {
          Text("Language")
          detail("Searched first, and used for automatic downloads.")
        }
        Toggle(isOn: Binding(get: { s.autoFetchSubtitles }, set: { update(SettingsPatch(autoFetchSubtitles: $0)) })) {
          Text("Download missing subtitles automatically")
          detail("When subtitles are on and an episode has none in your language, fetch the best match from OpenSubtitles (one download from the daily allowance per episode).")
        }
      } header: {
        header("Subtitles")
      } footer: {
        Note("Subtitle files next to a video and tracks inside it are found automatically. In the player, Subtitles › Search Online finds more, preferring ones timed for your exact file. Adverts uploaders put into subtitles are hidden.")
      }

      OpenSubtitlesSection()
      LearnedNamesSection()
    }
  }

  private func update(_ patch: SettingsPatch) {
    _ = app.engine.updateSettings(patch)
    app.refresh()
  }
}

/// Names learned from fixes to made subtitles, by title; any can be forgotten.
private struct LearnedNamesSection: View {
  @Environment(AppModel.self) private var app
  @State private var learned: [Engine.LearnedNames] = []

  var body: some View {
    Section {
      if learned.isEmpty {
        Note("None yet. To fix a line of subtitles made on this Mac, press E in the player (or click the line while paused). A name you correct is learned for that show.")
      }
      ForEach(learned) { t in
        LabeledContent {
          Menu("Forget") {
            ForEach(t.names, id: \.self) { n in
              Button(n) { forget(n, t) }
            }
          }
          .fixedSize()
        } label: {
          Text(t.title)
          detail(t.names.joined(separator: ", "))
        }
      }
    } header: {
      header("Names from Your Fixes")
    } footer: {
      Note("Subtitles made later spell these names as you wrote them. For an episode of a show, the characters’ names are also looked up on TVmaze; only the show’s name and the episode’s number are sent.")
    }
    .task { learned = app.engine.learnedNames() }
  }

  private func forget(_ name: String, _ t: Engine.LearnedNames) {
    app.engine.forgetName(name, titleId: t.titleId)
    learned = app.engine.learnedNames()
  }
}

/// The OpenSubtitles.com connection: the API key, and signing in.
private struct OpenSubtitlesSection: View {
  @Environment(AppModel.self) private var app
  @State private var status: OpenSubtitles.Status?
  @State private var message = ""
  @State private var failed = false
  @State private var busy = false
  @State private var key = ""
  @State private var username = ""
  @State private var password = ""

  var body: some View {
    Section {
      if let st = status {
        content(st)
      } else {
        ProgressView().controlSize(.small)
      }
      if !message.isEmpty {
        Note(message, color: failed ? Theme.error : nil)
      }
    } header: {
      HStack {
        header("OpenSubtitles.com")
        Spacer()
        if let st = status { badge(st) }
      }
    } footer: {
      Note("Subtitles provided by OpenSubtitles.com. Downloaded subtitles are kept in Nightcap’s data folder; your media folders are not touched.")
    }
    .task {
      let st = await app.engine.openSubtitlesStatus(refresh: true)
      username = st.username
      status = st
    }
  }

  private func badge(_ st: OpenSubtitles.Status) -> some View {
    Text(st.configured ? (st.signedIn ? "Signed In" : "Connected") : "Not Set Up")
      .font(.app(.caption, weight: .semibold))
      .foregroundStyle(st.configured ? Theme.ok : .secondary)
      .padding(.vertical, 2)
      .padding(.horizontal, 8)
      .background(Capsule().fill(st.configured ? Theme.ok.opacity(0.15) : Color.primary.opacity(0.07)))
      .textCase(nil)
  }

  @ViewBuilder private func content(_ st: OpenSubtitles.Status) -> some View {
    if !st.configured {
      VStack(alignment: .leading, spacing: 6) {
        Text("To search online, Nightcap needs your own API key. It is free:")
        step(1, "Create an account on [opensubtitles.com](https://www.opensubtitles.com/en/users/sign_up).")
        step(2, "Open [API consumers](https://www.opensubtitles.com/en/consumers), add a consumer (call it Nightcap) and copy its API key.")
        step(3, "Paste the key here. It stays on this Mac, in Nightcap’s data folder.")
      }
      HStack(spacing: 8) {
        SecureField("API key", text: $key, prompt: Text("Paste your API key"))
          .textFieldStyle(.roundedBorder)
          .onSubmit { saveKey() }
        Button("Save Key") { saveKey() }
          .disabled(busy || key.jsTrimmed.isEmpty)
      }
    } else {
      let left = st.remaining.map { " · \(jsNumber($0)) left today" } ?? ""
      LabeledContent {
        if !st.keyFromEnv {
          ArmedButton(title: "Remove Key", armedTitle: "Remove?") {
            run { try await app.engine.setOpenSubtitlesKey("") }
          }
          .disabled(busy)
        }
      } label: {
        Text("API key")
        Text(st.keyFromEnv ? "\(st.keyHint) (from OPENSUBTITLES_API_KEY)" : st.keyHint).font(.subheadline.monospaced())
      }
      if st.signedIn {
        let details = [st.level, st.allowedDownloads.map { "\(jsNumber($0)) downloads a day" } ?? ""].filter { !$0.isEmpty }
        LabeledContent {
          Button("Sign Out") { run { await app.engine.signOutOpenSubtitles() } }
            .disabled(busy)
        } label: {
          Text("Signed in as \(st.username)")
          detail(details.joined(separator: " · ") + left)
        }
      } else {
        Note(
          "\(st.signInExpired ? "Your sign-in has expired. " : "")Without signing in you can download 5 subtitles a day\(left). Signing in uses your account’s own daily allowance. Your password is only sent to OpenSubtitles, never stored."
        )
        TextField("Username", text: $username)
          .textContentType(.username)
          .autocorrectionDisabled()
        SecureField("Password", text: $password)
          .textContentType(.password)
          .onSubmit { signIn() }
        HStack {
          Spacer()
          Button("Sign In") { signIn() }
            .disabled(busy || username.jsTrimmed.isEmpty || password.isEmpty)
        }
      }
    }
  }

  private func step(_ n: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
      Text(LocalizedStringKey(text)).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func saveKey() {
    guard !key.jsTrimmed.isEmpty else { return }
    run { try await app.engine.setOpenSubtitlesKey(key) }
  }

  private func signIn() {
    run { try await app.engine.signInOpenSubtitles(username, password) }
  }

  /// Asks OpenSubtitles, then shows the new state, or the old one with the error.
  private func run(_ fn: @escaping () async throws -> OpenSubtitles.Status) {
    guard !busy else { return }
    busy = true
    failed = false
    message = "Checking with OpenSubtitles…"
    Task {
      do {
        let st = try await fn()
        status = st
        message = ""
        key = ""
        password = ""
        if !st.username.isEmpty { username = st.username }
      } catch {
        message = errorText(error)
        failed = true
      }
      busy = false
    }
  }
}
