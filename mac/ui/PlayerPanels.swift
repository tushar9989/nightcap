import AppKit
import SwiftUI

// The player's panels, opened from the controls: audio, subtitles, the
// picture and the intro and credits markers; subtitles online
// (OpenSubtitles.com); speed; and the episodes. They sit on glass above the
// controls on the right, at most as tall as the window allows.

/// Lines between a panel's parts.
private let panelLine = Color.white.opacity(0.12)

struct PlayerPanelHost: View {
  let player: PlayerModel
  let size: CGSize

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if let kind = player.panel, player.info != nil {
        PanelChrome(player: player, kind: kind) {
          switch kind {
          case .settings: SettingsPanel(player: player)
          case .online: OnlinePanel(player: player, size: size)
          case .speed: SpeedPanel(player: player)
          case .episodes: EpisodesPanel(player: player, size: size)
          }
        }
        // Its own view per kind: the one switched away from leaves as itself.
        .id(kind)
        .transition(.rise)
      }
    }
    // Limits only: the panel keeps its own size, at the bottom right of this space.
    .frame(
      maxWidth: max(280, size.width - 2 * PlayerMetrics.margin), maxHeight: max(160, size.height - PlayerMetrics.aboveBar - 80),
      alignment: .bottomTrailing
    )
    .padding(.trailing, PlayerMetrics.margin)
    .padding(.bottom, PlayerMetrics.aboveBar)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    .animation(.easeOut(duration: 0.2), value: player.panel)
  }
}

private struct PanelChrome<Content: View>: View {
  let player: PlayerModel
  let kind: PlayerPanel
  @ViewBuilder let content: Content

  var body: some View {
    content
      .clipShape(RoundedRectangle(cornerRadius: 22))
      .glassEffect(playerGlass, in: .rect(cornerRadius: 22))
      // Where it is, so a click inside it keeps it open (see PlayerModel.mouseDown).
      // Only the open panel says: one switched away from reports on its way out.
      .background(
        GeometryReader { g in
          Color.clear
            .onAppear { if player.panel == kind { player.panelFrame = g.frame(in: .global) } }
            .onChange(of: g.frame(in: .global)) { _, r in if player.panel == kind { player.panelFrame = r } }
        }
      )
      .onHover { player.panelHover($0) }
  }
}

// ---- Layout helpers ---------------------------------------------------------------------------------

/// As tall as its first subview (laid out at the width offered but not drawn),
/// up to the height offered and `maxHeight`; the second subview, the same
/// content in a scroll view, fills that.
struct HugLayout: Layout {
  var maxHeight: CGFloat = .infinity

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let first = subviews.first else { return .zero }
    let s = first.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    return CGSize(width: s.width, height: min(s.height, maxHeight, proposal.height ?? .infinity))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 2 else { return }
    subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
  }
}

private struct ColumnSeparator: LayoutValueKey {
  static let defaultValue = false
}

private struct ColumnMinWidth: LayoutValueKey {
  static let defaultValue: CGFloat = 150
}

/// The settings panel's columns: side by side with lines between them, or one
/// under another when they don't fit across.
private struct PanelColumns: Layout {
  private func widths(_ subviews: Subviews) -> [CGSize] {
    subviews.filter { !$0[ColumnSeparator.self] }.map { v in
      let s = v.sizeThatFits(.unspecified)
      return CGSize(width: max(s.width, v[ColumnMinWidth.self]), height: s.height)
    }
  }

  private func across(_ width: CGFloat?, _ cols: [CGSize]) -> Bool {
    guard let width else { return true }
    return cols.reduce(0) { $0 + $1.width } + CGFloat(max(0, cols.count - 1)) <= width
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let cols = widths(subviews)
    let lines = CGFloat(max(0, cols.count - 1))
    if across(proposal.width, cols) {
      return CGSize(width: cols.reduce(0) { $0 + $1.width } + lines, height: cols.map(\.height).max() ?? 0)
    }
    let w = cols.map(\.width).max() ?? 0
    let heights = subviews.filter { !$0[ColumnSeparator.self] }.map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
    return CGSize(width: w, height: heights.reduce(0, +) + lines)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let cols = widths(subviews)
    let horizontal = across(proposal.width, cols)
    var x = bounds.minX
    var y = bounds.minY
    var i = 0
    for v in subviews {
      if v[ColumnSeparator.self] {
        if horizontal {
          v.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: 1, height: bounds.height))
          x += 1
        } else {
          v.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: 1))
          y += 1
        }
        continue
      }
      let s = cols[i]
      i += 1
      if horizontal {
        v.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: s.width, height: bounds.height))
        x += s.width
      } else {
        let h = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        v.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
        y += h
      }
    }
  }
}

private struct PanelHeading: View {
  let text: String
  var body: some View {
    Text(text).font(.app(size: 17, weight: .bold)).padding(.bottom, 10)
  }
}

/// A choice in a column (or in the list of seasons): ticked when on.
struct PanelOption: View {
  let label: String
  let on: Bool
  /// "Search online…": a + instead of the tick, in blue.
  var more = false
  /// Lit as under the pointer: set by a list that moves the light itself (with the arrow keys).
  var lit: Bool? = nil
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.colorScheme) private var scheme

  private var hot: Bool { lit ?? hovering }

  var body: some View {
    Button(action: action) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: more ? "plus" : "checkmark")
          .font(.system(size: 12, weight: .bold))
          .opacity(more || on ? 1 : 0)
          .frame(width: 14, alignment: .leading)
        Text(label).fixedSize(horizontal: false, vertical: true)
      }
      .font(.app(size: 14, weight: on ? .semibold : .regular))
      .foregroundStyle(style)
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill((scheme == .dark ? Color.white : .black).opacity(hot && enabled ? 0.1 : 0)))
      .contentShape(Rectangle())
    }
    .buttonStyle(PlainTapStyle())
    .opacity(enabled ? 1 : 0.6)
    .onHover { hovering = $0 }
  }

  private var style: AnyShapeStyle {
    if more { return AnyShapeStyle(Theme.accent) }
    return on || hot ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
  }
}

/// The small grey buttons (timing, markers).
private struct PanelButton: View {
  let label: String
  var help: String? = nil
  var full = false
  var leading = false
  var padding = EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 9)
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(.app(size: 13))
        .multilineTextAlignment(leading ? .leading : .center)
        .padding(padding)
        .frame(maxWidth: full ? .infinity : nil, alignment: leading ? .leading : .center)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovering && enabled ? 0.18 : 0.1)))
        .contentShape(Rectangle())
    }
    .buttonStyle(PressStyle())
    .foregroundStyle(.primary)
    .opacity(enabled ? 1 : 0.6)
    .onHover { hovering = $0 }
    .help(help ?? "")
  }
}

// ---- Audio, subtitles, intro and credits ---------------------------------------------------------------

private struct SettingsPanel: View {
  let player: PlayerModel

  var body: some View {
    HugLayout {
      columns.hidden()
      ScrollView(.vertical) { columns }
    }
  }

  private var columns: some View {
    PanelColumns {
      if (player.info?.probe?.audio.count ?? 0) > 1 {
        AudioColumn(player: player)
        panelLine.layoutValue(key: ColumnSeparator.self, value: true)
      }
      SubtitlesColumn(player: player)
      panelLine.layoutValue(key: ColumnSeparator.self, value: true)
      if player.mediaInfo?.hasVideo != false {
        PictureColumn(player: player)
        panelLine.layoutValue(key: ColumnSeparator.self, value: true)
      }
      MarkersColumn(player: player)
        .layoutValue(key: ColumnMinWidth.self, value: 240)
    }
  }
}

private struct AudioColumn: View {
  let player: PlayerModel

  var body: some View {
    let tracks = player.info?.probe?.audio ?? []
    VStack(alignment: .leading, spacing: 0) {
      PanelHeading(text: "Audio")
      ForEach(Array(tracks.enumerated()), id: \.offset) { i, a in
        PanelOption(label: audioTrackName(a, i), on: i == player.audio) { player.switchAudio(i) }
      }
    }
    .padding(.vertical, 18)
    .padding(.horizontal, 20)
  }
}

private struct SubtitlesColumn: View {
  let player: PlayerModel

  var body: some View {
    let tracks = player.info?.subtitles ?? []
    VStack(alignment: .leading, spacing: 0) {
      PanelHeading(text: "Subtitles")
      PanelOption(label: "Off", on: player.subId == nil) { player.selectSubtitle(nil) }
      ForEach(tracks) { s in
        PanelOption(label: s.label, on: s.id == player.subId) { player.selectSubtitle(s.id) }
      }
      PanelOption(label: "Search online…", on: false, more: true) { player.togglePanel(.online) }
      if player.canMakeSubtitles, !tracks.contains(where: { $0.source == "made" }) {
        PanelOption(label: "Make subtitles on this Mac", on: false, more: true) { player.makeSubtitles() }
          .disabled(player.making != nil)
          .help("Hears the dialogue and writes English subtitles, on this Mac (about 30 s for an episode)")
        if let making = player.making {
          // Its own line, as wide as the option, so the panel doesn't change size as it counts.
          Text(making)
            .font(.app(size: 12))
            .monospacedDigit()
            .foregroundStyle(Theme.text2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 180, alignment: .leading)
            .padding(.leading, 30)
            .padding(.bottom, 4)
        }
      }
      if let id = player.subId {
        timing(id, track: tracks.first { $0.id == id })
      }
    }
    .padding(.vertical, 18)
    .padding(.horizontal, 20)
  }

  private func timing(_ id: String, track: SubtitleTrack?) -> some View {
    let d = player.subDelay
    return VStack(alignment: .leading, spacing: 0) {
      Text("Timing (G / H)").font(.app(size: 13)).foregroundStyle(Theme.text2)
      HStack(spacing: 6) {
        PanelButton(label: "Earlier", help: "Show subtitles earlier (G)") { player.setSubDelay(d - 0.25, osd: false) }
        Text(fmtDelay(d)).font(.app(size: 14)).monospacedDigit().frame(minWidth: 52)
        PanelButton(label: "Later", help: "Show subtitles later (H)") { player.setSubDelay(d + 0.25, osd: false) }
      }
      .padding(.top, 6)
      if track?.source == "made" {
        // Timed from the audio itself: nothing to sync.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          Text("Made from the dialogue ").fixedSize(horizontal: false, vertical: true)
          Button("Remove") { player.removeTrack(id) }
            .buttonStyle(PlainTapStyle())
            .underline()
            .padding(.horizontal, 4)
        }
        .font(.app(size: 12))
        .foregroundStyle(Theme.text2)
        .frame(width: 220, alignment: .leading)
        .padding(.top, 8)
      } else {
        PanelButton(
          label: player.syncing == id ? "Listening to the dialogue…" : "Sync to dialogue",
          help: "Match the subtitles to the dialogue in the audio (runs on this Mac)", full: true
        ) {
          player.syncToAudio()
        }
        .disabled(player.syncing != nil)
        .padding(.top, 8)
      }
      if let sync = track?.sync {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          Text("Synced: \(describeSync(sync)) ").fixedSize(horizontal: false, vertical: true)
          Button("Undo") { player.undoSync() }
            .buttonStyle(PlainTapStyle())
            .underline()
            .padding(.horizontal, 4)
        }
        .font(.app(size: 12))
        .foregroundStyle(Theme.text2)
        .frame(width: 220, alignment: .leading)
        .padding(.top, 6)
      }
    }
    .padding(.top, 10)
    .overlay(alignment: .top) { panelLine.frame(height: 1) }
    .padding(.top, 10)
  }
}

/// Original, or doubled by Apple's super resolution (and sharpened), with what that does here.
private struct PictureColumn: View {
  let player: PlayerModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PanelHeading(text: "Picture")
      ForEach(PictureMode.allCases, id: \.self) { m in
        PanelOption(label: m.label, on: m == player.picture) { player.choosePicture(m) }
      }
      if let note {
        Text(note)
          .font(.app(size: 12))
          .foregroundStyle(Theme.text2)
          .fixedSize(horizontal: false, vertical: true)
          .frame(width: 190, alignment: .leading)
          .padding(.top, 8)
      }
    }
    .padding(.vertical, 18)
    .padding(.horizontal, 20)
  }

  private var note: String? {
    guard let m = player.mediaInfo, m.width > 0, m.height > 0 else { return nil }
    // A size never breaks across lines.
    func dims(_ w: Int, _ h: Int) -> String { "\(w)\u{00A0}×\u{00A0}\(h)" }
    let size = dims(m.width, m.height)
    switch player.pictureStatus {
    case .off: return player.picture == .original ? "\(size), as recorded" : nil
    case .starting: return nil
    case let .doubled(w, h): return player.picture == .original ? nil : "\(size) doubled to \(dims(w, h)) by Apple’s super resolution"
    case let .unavailable(why): return player.picture == .original ? nil : why
    }
  }
}

private struct MarkersColumn: View {
  let player: PlayerModel

  var body: some View {
    let m = player.markers
    let introText = m.intro.map { "\(fmtTime($0.start)) – \(fmtTime($0.end))" } ?? "none"
    let creditsText = m.credits.map { fmtTime($0.start) } ?? "none"
    let decoding = decodingLabel(player.mediaInfo)
    VStack(alignment: .leading, spacing: 0) {
      PanelHeading(text: "Intro & credits")
      VStack(alignment: .leading, spacing: 5) {
        Text("Intro: \(introText)")
        Text("Credits: \(creditsText)")
        Text(status(m)).foregroundStyle(Theme.text2)
        if !decoding.isEmpty { Text(decoding).foregroundStyle(Theme.text2) }
      }
      .font(.app(size: 13))
      .padding(.bottom, 10)
      VStack(alignment: .leading, spacing: 6) {
        MarkerButton(clock: player.clock, label: "Intro starts here") {
          let now = player.nowTenths
          let end = max(now + 5, player.markers.intro?.end ?? now + 60)
          player.setMarkers(intro: .set(Span(start: now, end: end)), "Intro start set")
        }
        MarkerButton(clock: player.clock, label: "Intro ends here") {
          let now = player.nowTenths
          player.setMarkers(intro: .set(Span(start: min(player.markers.intro?.start ?? 0, now - 1), end: now)), "Intro end set")
        }
        MarkerButton(clock: player.clock, label: "Credits start here") {
          player.setMarkers(credits: .set(Mark(start: min(player.nowTenths, player.duration))), "Credits start set")
        }
        PanelButton(label: "No intro in this episode", full: true, leading: true, padding: MarkerButton.padding) {
          player.setMarkers(intro: .cleared, "Intro cleared")
        }
        if m.manual {
          PanelButton(label: "Use detected markers", full: true, leading: true, padding: MarkerButton.padding) {
            player.setMarkers(reset: true, "Back to detected markers")
          }
        }
      }
    }
    .padding(.vertical, 18)
    .padding(.horizontal, 20)
  }

  private func status(_ m: Markers) -> String {
    if m.manual { return "Corrected by you" }
    if m.state == "done" {
      let how = [m.method["intro"], m.method["credits"]].compactMap { $0 }.first { !$0.isEmpty }
      return "Detected · \(how ?? "nothing found")"
    }
    return m.state == "queued" ? "Detection queued…" : "Not analysed yet"
  }
}

/// "Intro starts here (12:34)": the time where playback is now.
private struct MarkerButton: View {
  static let padding = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
  let clock: PlayerClock
  let label: String
  let action: () -> Void

  var body: some View {
    PanelButton(label: "\(label) (\(fmtTime(clock.time)))", full: true, leading: true, padding: MarkerButton.padding, action: action)
  }
}

// ---- Subtitles online (OpenSubtitles.com) ------------------------------------------------------------------

private struct OnlinePanel: View {
  let player: PlayerModel
  let size: CGSize
  @Environment(WindowModel.self) private var win

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Button {
          player.togglePanel(.settings)
        } label: {
          HStack(spacing: 2) {
            Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            Text("Subtitles")
          }
          .font(.app(size: 13))
        }
        .buttonStyle(QuietButtonStyle())
        Text("Find Subtitles Online").font(.app(size: 17, weight: .bold))
      }
      .padding(EdgeInsets(top: 14, leading: 8, bottom: 10, trailing: 16))
      if player.info?.onlineConfigured == true, let o = player.online {
        form(o)
        HugLayout(maxHeight: min(size.height * 0.46, 440)) {
          results(o).hidden()
          ScrollView(.vertical) { results(o) }
        }
        footer(o)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Text("Nightcap can find subtitles for this video on OpenSubtitles.com. It needs your own free API key first.")
            .fixedSize(horizontal: false, vertical: true)
          PrimaryButton("Set Up in Settings…", large: false) { win.openSettings(.subtitles) }
        }
        .font(.app(size: 14))
        .foregroundStyle(Theme.text2)
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 18, trailing: 16))
        credit(nil)
          .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
          .overlay(alignment: .top) { panelLine.frame(height: 1) }
      }
    }
    .frame(width: min(640, size.width - 2 * PlayerMetrics.margin))
  }

  private func form(_ o: OnlineSearch) -> some View {
    let langs = subLanguages(o.language)
    let selected = langs.first { $0.code.jsLowercased == o.language.jsLowercased }?.code ?? o.language
    return HStack(spacing: 8) {
      Picker("Language", selection: Binding(get: { selected }, set: { player.setOnlineLanguage($0) })) {
        ForEach(langs, id: \.code) { Text($0.name).tag($0.code) }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()
      TextField("Show and episode, or film", text: Binding(get: { player.onlineQuery }, set: { player.onlineQuery = $0 }))
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .onSubmit { player.submitOnlineQuery() }
        .onExitCommand { player.closePanel() }
      Button("Search") { player.submitOnlineQuery() }
        .buttonStyle(.bordered)
    }
    .padding(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
    .overlay(alignment: .bottom) { panelLine.frame(height: 1) }
  }

  private func results(_ o: OnlineSearch) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if o.loading {
        HStack(spacing: 12) {
          Spinner(size: 18, line: 2)
          Text("Searching OpenSubtitles…")
        }
        .modifier(OnlineNote())
      } else if let error = o.error {
        Text(error).foregroundStyle(Theme.error).modifier(OnlineNote())
      } else if let list = o.results, list.isEmpty {
        Text("No \(languageName(o.language)) subtitles found. Try another search, such as the episode title.")
          .modifier(OnlineNote())
      } else {
        ForEach(Array((o.results ?? []).enumerated()), id: \.offset) { _, r in
          ResultRow(r: r, busy: o.busy == r.id, locked: o.busy != nil, busyText: o.busyText) { player.onlineDownload(r) }
        }
      }
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func footer(_ o: OnlineSearch) -> some View {
    let mine = (player.info?.subtitles ?? []).filter { $0.source == "online" }
    return VStack(alignment: .leading, spacing: 0) {
      if !mine.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          Text("Downloaded for this video").font(.app(size: 13)).foregroundStyle(Theme.text2)
          ForEach(mine) { s in
            HStack(spacing: 10) {
              Text(s.label).font(.app(size: 13)).fixedSize()
              Text(s.release ?? "")
                .font(.app(size: 11.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(s.release ?? "")
              Button("Remove") { player.removeTrack(s.id) }
                .font(.app(size: 12))
                .buttonStyle(QuietButtonStyle())
            }
          }
        }
        .padding(.bottom, 8)
      }
      credit(o.status)
    }
    .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
    .overlay(alignment: .top) { panelLine.frame(height: 1) }
  }

  private func credit(_ status: OpenSubtitles.Status?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text("Subtitles provided by [OpenSubtitles.com](https://www.opensubtitles.com)")
        .tint(.primary)
      Spacer(minLength: 0)
      if let status { Text(OnlinePanel.quota(status)) }
    }
    .font(.app(size: 12))
    .foregroundStyle(Theme.text2)
  }

  static func quota(_ st: OpenSubtitles.Status) -> String {
    if let r = st.remaining { return "\(jsNumber(r)) download\(r == 1 ? "" : "s") left today" }
    if st.signedIn { return "\(st.allowedDownloads.map(jsNumber) ?? "Your") downloads a day" }
    return "5 downloads a day without signing in"
  }
}

private struct OnlineNote: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(.app(size: 14))
      .foregroundStyle(Theme.text2)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, 18)
      .padding(.horizontal, 16)
  }
}

private enum BadgeKind {
  case plain, good, warn
}

private struct Badge: View {
  let text: String
  var kind = BadgeKind.plain
  var help: String? = nil

  var body: some View {
    Text(text)
      .font(.app(size: 11, weight: .semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 1)
      .foregroundStyle(color)
      .background(Capsule().fill(kind == .plain ? Color.white.opacity(0.12) : color.opacity(0.16)))
      .help(help ?? "")
  }

  private var color: Color {
    switch kind {
    case .good: Theme.ok
    case .warn: Theme.boost
    case .plain: .primary
    }
  }
}

private struct ResultRow: View {
  let r: SubtitleResult
  /// Being downloaded.
  let busy: Bool
  /// Something is being downloaded: the rows wait.
  let locked: Bool
  let busyText: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 3) {
        Text(release)
          .font(.app(size: 14))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
        FlowLayout(spacing: 6, lineSpacing: 3) {
          if r.hashMatch { Badge(text: "Made for this file", kind: .good, help: "Timed for this exact video file") }
          if r.hearingImpaired { Badge(text: "SDH", help: "Includes sound descriptions for the deaf and hard of hearing") }
          if r.foreignOnly { Badge(text: "Foreign parts only", kind: .warn) }
          if r.aiTranslated { Badge(text: "AI translated", kind: .warn) }
          if r.machineTranslated { Badge(text: "Machine translated", kind: .warn) }
          Text(meta)
          if busy { Text(busyText).foregroundStyle(.primary) }
        }
        .font(.app(size: 12))
        .foregroundStyle(Theme.text2)
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(busy ? 0.12 : hovering && !locked ? 0.08 : 0)))
      .padding(.horizontal, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(PlainTapStyle())
    .disabled(locked)
    .opacity(locked && !busy ? 0.5 : 1)
    .onHover { hovering = $0 }
    .help(r.release)
  }

  private var release: String {
    !r.release.isEmpty ? r.release : !r.fileName.isEmpty ? r.fileName : "Untitled"
  }

  private var meta: String {
    let fps = r.fps.flatMap { $0 != 0 && !$0.isNaN ? "\(jsNumber($0)) fps" : nil } ?? ""
    let year = r.uploaded.map { String(decoding: Array($0.utf16.prefix(4)), as: UTF16.self) } ?? ""
    return [languageName(r.language), "\(fmtCount(r.downloads)) downloads", fps, year]
      .filter { !$0.isEmpty }
      .joined(separator: " · ")
  }
}

// ---- Speed -------------------------------------------------------------------------------------------------

private struct SpeedPanel: View {
  let player: PlayerModel

  var body: some View {
    let stops =
      PlayerModel.speedStops.contains(player.speed)
      ? PlayerModel.speedStops : (PlayerModel.speedStops + [player.speed]).sorted()
    VStack(alignment: .leading, spacing: 0) {
      Text("Playback Speed").font(.app(size: 17, weight: .bold)).padding(.bottom, 18)
      HStack(alignment: .top, spacing: 0) {
        ForEach(stops, id: \.self) { sp in
          SpeedStop(speed: sp, on: sp == player.speed) { player.setSpeed(sp) }
        }
      }
      .background(alignment: .top) {
        Color.white.opacity(0.22).frame(height: 2).padding(.horizontal, 30).padding(.top, 9)
      }
      Text("[ slower · ] faster · { } fine steps · = normal. Voices keep their pitch.")
        .font(.app(size: 13))
        .foregroundStyle(Theme.text2)
        .padding(.top, 16)
    }
    .padding(EdgeInsets(top: 20, leading: 24, bottom: 16, trailing: 24))
    .fixedSize()
  }
}

private struct SpeedStop: View {
  let speed: Double
  let on: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 8) {
        ZStack {
          if on {
            Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 5).frame(width: 30, height: 30)
            Circle().fill(Color.white).frame(width: 20, height: 20)
          } else {
            Circle().fill(Color.white.opacity(hovering ? 1 : 0.7)).frame(width: 12, height: 12)
              .scaleEffect(hovering ? 1.3 : 1)
          }
        }
        .frame(width: 20, height: 20)
        Text(fmtSpeed(speed)).font(.app(size: 14, weight: on ? .bold : .regular)).monospacedDigit()
        if speed == 1 {
          Text("Normal").font(.app(size: 11)).foregroundStyle(.tertiary).padding(.top, -6)
        }
      }
      .foregroundStyle(on || hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      .frame(minWidth: 60)
      .contentShape(Rectangle())
    }
    .buttonStyle(PlainTapStyle())
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onHover { hovering = $0 }
  }
}

// ---- Episodes ------------------------------------------------------------------------------------------------

private struct EpisodesPanel: View {
  let player: PlayerModel
  let size: CGSize
  @Environment(AppModel.self) private var app
  /// The seasons shown in the episodes' place, to choose one.
  @State private var choosing = false

  /// A row: 12 + a 120-wide 16:9 picture + 12.
  static let rowHeight: CGFloat = 24 + 120 * 9 / 16

  var body: some View {
    if let fid = player.fid, let w = app.location(fid) {
      let t = w.title
      let season = max(0, min(t.seasons.count - 1, player.panelSeason ?? w.seasonIndex))
      let episodes = t.seasons[season].episodes
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Text(t.name).font(.app(size: 17, weight: .bold)).lineLimit(1)
          Spacer(minLength: 0)
          if t.seasons.count > 1 {
            Button { choosing.toggle() } label: {
              PanelSeasonLabel(name: t.seasons[season].name, open: choosing)
            }
            .buttonStyle(PlainTapStyle())
            .fixedSize()
            .help("Choose a season")
          }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) { panelLine.frame(height: 1) }
        // The episodes stay (hidden) under the seasons: the panel keeps its height, and its place in the list.
        ZStack(alignment: .top) {
          ScrollViewReader { proxy in
            ScrollView(.vertical) {
              LazyVStack(spacing: 0) {
                ForEach(episodes, id: \.self) { e in
                  PanelEpisodeRow(fid: e, current: e == fid) { player.playEpisode(e) }
                    .id(e)
                }
              }
            }
            .frame(maxHeight: CGFloat(episodes.count) * EpisodesPanel.rowHeight)
            .onAppear {
              // Once the rows are laid out.
              Task { @MainActor in proxy.scrollTo(fid, anchor: .center) }
            }
            .onChange(of: season) {
              proxy.scrollTo(episodes.contains(fid) ? fid : episodes.first ?? fid, anchor: .center)
            }
          }
          .opacity(choosing ? 0 : 1)
          .allowsHitTesting(!choosing)
          .accessibilityHidden(choosing)
          if choosing {
            HugLayout {
              seasons(t, season).hidden()
              ScrollView(.vertical) { seasons(t, season) }
            }
          }
        }
        .animation(.easeOut(duration: 0.15), value: choosing)
      }
      .frame(width: min(520, size.width * 0.92))
      .task(id: season) { app.engine.prioritizePreviews(episodes) }
    }
  }

  private func seasons(_ t: Title, _ season: Int) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(t.seasons.enumerated()), id: \.offset) { i, s in
        PanelOption(label: s.name, on: i == season) {
          player.panelSeason = i
          choosing = false
        }
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
  }
}

/// The season shown in the Episodes panel, which shows the seasons in the episodes' place: a small grey button.
private struct PanelSeasonLabel: View {
  let name: String
  let open: Bool
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 6) {
      Text(name).font(.app(size: 14, weight: .semibold)).lineLimit(1)
      Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
    }
    .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 9))
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovering || open ? 0.18 : 0.1)))
    .onHover { hovering = $0 }
  }
}

private struct PanelEpisodeRow: View {
  let fid: String
  let current: Bool
  let action: () -> Void
  @Environment(AppModel.self) private var app
  @State private var hovering = false
  @State private var previewing = false

  var body: some View {
    let f = app.file(fid)
    let p = app.progress(fid)
    let dur = f?.duration ?? 0
    HStack(spacing: 14) {
      ArtBox(.file(fid, width: 320), radius: 6, previewing: previewing ? fid : nil) {
        if let p, p.duration != 0 { ProgressEdge(fraction: AppModel.fraction(p)) }
      }
      .frame(width: 120)
      VStack(alignment: .leading, spacing: 3) {
        Text("\(f?.number.map { "\($0). " } ?? "")\(f?.name ?? "")")
          .font(.app(size: 14, weight: .bold))
          .lineLimit(1)
        Text(dur != 0 && !dur.isNaN ? "\(Int(jsRound(dur / 60))) min" : "")
          .font(.app(size: 12))
          .foregroundStyle(Theme.text2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(current ? 0.12 : hovering ? 0.07 : 0)))
    .overlay(alignment: .leading) {
      if current { Capsule().fill(Theme.accent).frame(width: 3, height: 28).offset(x: -6) }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 12)
    .frame(height: EpisodesPanel.rowHeight)
    .contentShape(Rectangle())
    .onTapGesture(perform: action)
    .hoverPreview(hovering: $hovering, previewing: $previewing)
  }
}
