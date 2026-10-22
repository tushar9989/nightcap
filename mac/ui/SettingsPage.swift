import AppKit
import SwiftUI

// Settings: library folders, detection, previews, playback, subtitles
// (with the OpenSubtitles.com connection), and quitting.

struct SettingsPage: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  @State private var scanning = false

  var body: some View {
    let lib = app.lib
    PageScroll(maxWidth: 860, bottom: 70) {
      Text("Settings").font(.system(size: 26, weight: .bold)).padding(.bottom, 24)

      SettingsSection(
        title: "Library folders",
        text: "Each subfolder of a show becomes a season. Folders are rescanned every 15 minutes; your watch progress is kept even if a drive is unplugged."
      ) {
        if lib.folders.isEmpty {
          Text("No folders yet.").font(.system(size: 13)).foregroundStyle(Theme.text2)
        } else {
          ForEach(lib.folders, id: \.id) { FolderRow(folder: $0, status: lib.folderStatus[$0.id]) }
        }
        HStack(spacing: 8) {
          Button { win.addFolder() } label: { Label("Add folder", systemImage: "plus") }
            .buttonStyle(PillButtonStyle(kind: .accent, small: true))
          Button {
            Task { await scanNow() }
          } label: {
            Label("Scan now", systemImage: "arrow.clockwise")
          }
          .buttonStyle(PillButtonStyle(small: true))
          .disabled(scanning)
        }
        .padding(.top, 14)
      }

      SettingsSection(
        title: "Intro & credits detection",
        text: "Runs on this Mac. Each episode’s opening and closing minutes are turned into an audio fingerprint and compared with the other episodes of its season: music they share is the intro or the end credits. Movies (and shows without a shared end theme) are checked for text-on-black credits. Fingerprints and results are saved, so only new episodes are ever analysed."
      ) {
        SettingToggle(
          label: "Detect intros and credits", desc: "Uses some CPU in the background while new episodes are analysed.",
          isOn: lib.settings.analysis, first: true
        ) { update(SettingsPatch(analysis: $0)) }
        AnalysisProgress(status: app.status.analysis)
      }

      SettingsSection(
        title: "Preview thumbnails",
        text: "A frame every few seconds of each episode and film, made on this Mac from keyframes (about a second per episode). They show above the seek bar while you scrub, play as previews when you rest the pointer on an episode, and preview the next episode at the end credits."
      ) {
        SettingToggle(
          label: "Make preview thumbnails", desc: "Runs in the background; what you open or play is done first. About 2 MB per episode.",
          isOn: lib.settings.previews, first: true
        ) { update(SettingsPatch(previews: $0)) }
        PreviewsProgress(status: app.status.previews)
      }

      SettingsSection(title: "Playback") {
        SettingToggle(
          label: "Skip intros automatically", desc: "Otherwise a Skip Intro button appears during the intro.",
          isOn: lib.settings.autoSkipIntro, first: true
        ) { update(SettingsPatch(autoSkipIntro: $0)) }
        SettingToggle(
          label: "Autoplay next episode", desc: "When the end credits start, count down and play the next episode.",
          isOn: lib.settings.autoplayNext
        ) { update(SettingsPatch(autoplayNext: $0)) }
        SettingRow(label: "Next episode countdown") {
          let current = lib.settings.nextCountdown
          // A value set some other way (the settings file) is listed too, so the menu shows what is in use.
          let stops = [5, 10, 15, 20, 30].contains(current) ? [5, 10, 15, 20, 30] : ([5, 10, 15, 20, 30] + [current]).sorted()
          Picker("Next episode countdown", selection: Binding(get: { current }, set: { update(SettingsPatch(nextCountdown: Double($0))) })) {
            ForEach(stops, id: \.self) { Text("\($0) seconds").tag($0) }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .fixedSize()
        }
        SettingRow(
          label: "Keyboard",
          desc:
            "Space play/pause · ←/→ 10 s · ↑/↓ volume up to 200% · [ ] speed ({ } fine, = normal) · S skip intro · N next episode · C subtitles · G / H subtitles earlier / later · F full screen · M mute"
        ) { EmptyView() }
      }

      SubtitlesSection()

      SettingsSection(
        title: "Engine",
        text: lib.ffmpeg
          ? "Videos play in Nightcap’s own player, built on ffmpeg: any format plays, decoded by the Mac’s hardware where it can."
          : "ffmpeg was not found, so intro and credits detection, previews, subtitles inside videos and syncing to the dialogue are off. Videos still play."
      ) {
        Button("Quit Nightcap") { NSApp.terminate(nil) }
          .buttonStyle(PillButtonStyle(small: true))
      }
    }
  }

  private func update(_ patch: SettingsPatch) {
    _ = app.engine.updateSettings(patch)
    app.refresh()
  }

  private func scanNow() async {
    scanning = true
    win.toast("Scanning…")
    app.apply(await app.engine.scan())
    scanning = false
    win.toast("Library updated")
  }
}

// ---- Building blocks ------------------------------------------------------------------------

/// A boxed section with a heading and an explanation.
struct SettingsSection<Content: View>: View {
  let title: String
  var text: String? = nil
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title).font(.system(size: 16, weight: .bold)).padding(.bottom, 4)
      if let text {
        Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 16)
      }
      content
    }
    .padding(.vertical, 20)
    .padding(.horizontal, 22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
    .padding(.bottom, 18)
  }
}

/// A line of settings: what it is on the left, its control on the right.
struct SettingRow<Control: View>: View {
  let label: String
  var desc: String? = nil
  /// The first line of a section has no rule above it.
  var first = false
  @ViewBuilder var control: Control

  var body: some View {
    HStack(spacing: 20) {
      VStack(alignment: .leading, spacing: 2) {
        Text(label).font(.system(size: 14))
        if let desc, !desc.isEmpty {
          Text(desc).font(.system(size: 12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      control
    }
    .padding(.vertical, 13)
    .overlay(alignment: .top) {
      if !first { Theme.line.frame(height: 1) }
    }
  }
}

struct SettingToggle: View {
  let label: String
  let desc: String
  let isOn: Bool
  var first = false
  let change: (Bool) -> Void

  var body: some View {
    SettingRow(label: label, desc: desc, first: first) {
      Toggle(label, isOn: Binding(get: { isOn }, set: change))
        .toggleStyle(AmberSwitchStyle())
        .labelsHidden()
    }
  }
}

/// The pages' switch: amber when on.
struct AmberSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      ZStack(alignment: configuration.isOn ? .trailing : .leading) {
        Capsule().fill(configuration.isOn ? Theme.accent : Color.white.opacity(0.16))
        Circle().fill(.white)
          .frame(width: 20, height: 20)
          .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
          .padding(2)
      }
      .frame(width: 40, height: 24)
      .animation(.easeOut(duration: 0.2), value: configuration.isOn)
    }
    .buttonStyle(PlainTapStyle())
    .accessibilityLabel(Text("Switch"))
    .accessibilityValue(Text(configuration.isOn ? "On" : "Off"))
  }
}

/// A button that asks for a second click before it acts ("Click again to remove").
struct ArmedButton: View {
  let title: String
  let armedTitle: String
  var help: String? = nil
  let action: () -> Void
  @State private var armed = false

  var body: some View {
    Button(armed ? armedTitle : title) {
      if armed {
        armed = false
        action()
      } else {
        armed = true
      }
    }
    .buttonStyle(LinkButtonStyle())
    .fixedSize()
    .help(help ?? "")
    .task(id: armed) {
      guard armed else { return }
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      if !Task.isCancelled { armed = false }
    }
  }
}

private struct FolderRow: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  let folder: Folder
  let status: FolderStatus?

  var body: some View {
    let stat = status.map { st in st.online ? "\(st.titles ?? 0) titles · \(st.videos ?? 0) videos" : st.error ?? "" }
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(folder.path)
          .font(.system(size: 12.5, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        Text(stat ?? "Not scanned yet")
          .font(.system(size: 12))
          .foregroundStyle(status.map { !$0.online } == true ? Theme.warn : Theme.text2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Picker("What this folder contains", selection: Binding(get: { folder.kind }, set: { kind in Task { await setKind(kind) } })) {
        ForEach(WindowModel.folderKinds, id: \.kind) { Text($0.label).tag($0.kind) }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()
      .help("What this folder contains")
      ArmedButton(title: "Remove", armedTitle: "Click again to remove", help: "Remove from library (files are not touched)") {
        Task { await remove() }
      }
    }
    .padding(.vertical, 12)
    .overlay(alignment: .top) { Theme.line.frame(height: 1) }
  }

  private func setKind(_ kind: String) async {
    guard kind != folder.kind else { return }
    win.toast("Rescanning…")
    do {
      app.apply(try await app.engine.setFolderKind(folder.id, kind))
    } catch {
      win.toast(errorText(error), ms: 5000)
    }
  }

  private func remove() async {
    app.apply(await app.engine.removeFolder(folder.id))
    win.toast("Folder removed (files untouched)")
  }
}

private struct AnalysisProgress: View {
  let status: Analyzer.Status

  var body: some View {
    let a = status
    let text =
      !a.available
      ? "Needs ffmpeg."
      : !a.enabled
        ? "Paused."
        : a.current.map { "Analysing \($0.label) (\($0.done)/\($0.total))… \(a.analyzedFiles) of \(a.totalFiles) done" }
          ?? (a.analyzedFiles >= a.totalFiles ? "All \(a.totalFiles) videos analysed." : "\(a.analyzedFiles) of \(a.totalFiles) analysed.")
    VStack(alignment: .leading, spacing: 8) {
      ProgressLine(fraction: a.totalFiles != 0 ? Double(a.analyzedFiles) / Double(a.totalFiles) : 0)
      Text(text).font(.system(size: 13)).foregroundStyle(Theme.text2)
    }
    .padding(.top, 12)
  }
}

private struct PreviewsProgress: View {
  let status: Trickplay.Status

  var body: some View {
    let p = status
    let bytes = Double(p.bytes)
    let size = bytes >= 1e9 ? "\(toFixed(bytes / 1e9, 1)) GB" : "\(jsNumber(jsRound(bytes / 1e6))) MB"
    let text =
      !p.available
      ? "Needs ffmpeg."
      : p.current != nil && p.enabled
        ? "Making previews for \(p.current!)… \(p.done) of \(p.total) done · \(size)"
        : "\(p.done) of \(p.total) videos have previews · \(size)\(!p.enabled ? " · paused" : "")"
    VStack(alignment: .leading, spacing: 8) {
      ProgressLine(fraction: p.total != 0 ? Double(p.done) / Double(p.total) : 0)
      Text(text).font(.system(size: 13)).foregroundStyle(Theme.text2)
    }
    .padding(.top, 12)
  }
}

// ---- Subtitles and OpenSubtitles.com --------------------------------------------------------------

private struct SubtitlesSection: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let settings = app.lib.settings
    SettingsSection(
      title: "Subtitles",
      text: "Subtitle files next to a video and subtitle tracks inside it are found automatically. Nightcap can also search OpenSubtitles.com, preferring subtitles timed for your exact file (Subtitles button → Search online…). Adverts that uploaders put into subtitles are hidden."
    ) {
      SettingRow(label: "Subtitle language", desc: "Searched first, and used for automatic downloads.", first: true) {
        Picker(
          "Subtitle language",
          selection: Binding(
            get: { settings.subtitleLanguage },
            set: {
              _ = app.engine.updateSettings(SettingsPatch(subtitleLanguage: $0))
              app.refresh()
            })
        ) {
          ForEach(subLanguages(settings.subtitleLanguage), id: \.code) { Text($0.name).tag($0.code) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
      SettingToggle(
        label: "Download missing subtitles automatically",
        desc:
          "When you watch with subtitles on and an episode has none in your language, fetch the best match from OpenSubtitles (one download from the daily allowance per episode).",
        isOn: settings.autoFetchSubtitles
      ) {
        _ = app.engine.updateSettings(SettingsPatch(autoFetchSubtitles: $0))
        app.refresh()
      }
      OpenSubtitlesBox()
        .padding(.top, 6)
    }
  }
}

/// The OpenSubtitles.com connection: the API key, and signing in.
private struct OpenSubtitlesBox: View {
  @Environment(AppModel.self) private var app
  @State private var status: OpenSubtitles.Status?
  @State private var message = ""
  @State private var failed = false
  @State private var busy = false
  @State private var key = ""
  @State private var username = ""
  @State private var password = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let st = status {
        content(st)
      } else {
        Text("Loading…").font(.system(size: 13)).foregroundStyle(Theme.text2)
      }
    }
    .font(.system(size: 13.5))
    .tint(Theme.accent2)
    .padding(.vertical, 16)
    .padding(.horizontal, 18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
    .task {
      let st = await app.engine.openSubtitlesStatus(refresh: true)
      username = st.username
      status = st
    }
  }

  @ViewBuilder private func content(_ st: OpenSubtitles.Status) -> some View {
    HStack(spacing: 10) {
      Text("OpenSubtitles.com").fontWeight(.bold)
      Text(st.configured ? (st.signedIn ? "Signed in as \(st.username)" : "Connected") : "Not set up")
        .font(.system(size: 12))
        .foregroundStyle(st.configured ? Theme.ok : Theme.text2)
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(Capsule().fill(st.configured ? Theme.ok.opacity(0.16) : Color.white.opacity(0.08)))
    }
    .padding(.bottom, 6)

    if !st.configured {
      Text("To search online, Nightcap needs your own API key. It is free:")
        .foregroundStyle(Theme.text2).padding(.top, 10).padding(.bottom, 6)
      VStack(alignment: .leading, spacing: 4) {
        step(1, "Create an account on [opensubtitles.com](https://www.opensubtitles.com/en/users/sign_up).")
        step(2, "Open [API consumers](https://www.opensubtitles.com/en/consumers), add a new consumer (call it Nightcap) and copy its API key.")
        step(3, "Paste the key here. It stays on this Mac, in Nightcap’s data folder.")
      }
      .padding(.bottom, 12)
      HStack(spacing: 8) {
        FieldBox {
          SecureField("API key", text: $key)
            .onSubmit { saveKey() }
            .accessibilityLabel("OpenSubtitles API key")
        }
        .frame(minWidth: 160)
        Button("Save key") { saveKey() }
          .buttonStyle(PillButtonStyle(kind: .accent, small: true))
          .disabled(busy)
      }
      note
    } else {
      let left = st.remaining.map { " · \(jsNumber($0)) left today" } ?? ""
      SettingRow(label: "API key", desc: st.keyFromEnv ? "\(st.keyHint) (from OPENSUBTITLES_API_KEY)" : st.keyHint) {
        if !st.keyFromEnv {
          ArmedButton(title: "Remove key", armedTitle: "Click again to remove") {
            run { try await app.engine.setOpenSubtitlesKey("") }
          }
          .disabled(busy)
        }
      }
      if st.signedIn {
        let details = [st.level, st.allowedDownloads.map { "\(jsNumber($0)) downloads a day" } ?? ""].filter { !$0.isEmpty }
        SettingRow(label: "Signed in as \(st.username)", desc: details.joined(separator: " · ") + left) {
          Button("Sign out") { run { await app.engine.signOutOpenSubtitles() } }
            .buttonStyle(LinkButtonStyle())
            .fixedSize()
            .disabled(busy)
        }
      } else {
        VStack(alignment: .leading, spacing: 10) {
          Text(
            "\(st.signInExpired ? "Your sign-in has expired. " : "")Without signing in you can download 5 subtitles a day\(left). Signing in uses your account’s own daily allowance. Your password is only sent to OpenSubtitles, never stored."
          )
          .font(.system(size: 13))
          .foregroundStyle(Theme.text2)
          .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) {
            FieldBox {
              TextField("Username", text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
                .accessibilityLabel("OpenSubtitles username")
            }
            .frame(minWidth: 160)
            FieldBox {
              SecureField("Password", text: $password)
                .textContentType(.password)
                .onSubmit { signIn() }
                .accessibilityLabel("OpenSubtitles password")
            }
            .frame(minWidth: 160)
            Button("Sign in") { signIn() }
              .buttonStyle(PillButtonStyle(small: true))
              .disabled(busy)
          }
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
      }
      note
      Text("Subtitles provided by [OpenSubtitles.com](https://www.opensubtitles.com). Downloaded subtitles are kept in Nightcap’s data folder; your media folders are not touched.")
        .font(.system(size: 13))
        .foregroundStyle(Theme.text2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
    }
  }

  private func step(_ n: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("\(n).").monospacedDigit()
      Text(LocalizedStringKey(text)).fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(Theme.text2)
  }

  private var note: some View {
    Text(message)
      .font(.system(size: 13))
      .foregroundStyle(failed ? Theme.error : Theme.text2)
      .frame(minHeight: 18, alignment: .topLeading)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 8)
  }

  private func saveKey() {
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
