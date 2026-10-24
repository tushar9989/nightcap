import AppKit
import SwiftUI

// What the player shows over the window: the picture, subtitles, the controls
// on a bar of glass (hidden after 3 s of playing untouched), Skip Intro, the
// Next Episode card, the card above the Next button, and the panels
// (PlayerPanels.swift). Always dark, whatever the Mac's appearance.

/// The picture. A click plays or pauses (two: full screen).
final class PlayerSurface: VideoView {
  var onClick: ((Int) -> Void)?

  override func mouseDown(with event: NSEvent) {
    onClick?(event.clickCount)
  }

  // The page under the player doesn't scroll.
  override func scrollWheel(with event: NSEvent) {}
}

private struct SurfaceHost: NSViewRepresentable {
  let surface: PlayerSurface

  func makeNSView(context: Context) -> PlayerSurface { surface }
  func updateNSView(_ view: PlayerSurface, context: Context) {}
}

extension AnyTransition {
  /// Up a little, from transparent.
  static var rise: AnyTransition {
    .opacity.combined(with: .offset(y: 16)).combined(with: .scale(scale: 0.98))
  }
}

/// Where the Next button is, for the card that opens above it.
private struct NextButtonKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// The glass of the player's bar, cards and panels: tinted a little darker, so
/// text stays readable over a bright picture.
let playerGlass = Glass.regular.tint(.black.opacity(0.3))

/// How far the bar keeps from the window's edges, and how tall it is.
enum PlayerMetrics {
  static let margin: CGFloat = 20
  static let barHeight: CGFloat = 92
  /// Above the bar: Skip Intro, the cards and the panels.
  static let aboveBar: CGFloat = margin + barHeight + 14
}

struct PlayerView: View {
  let player: PlayerModel
  let fullScreen: Bool

  var body: some View {
    GeometryReader { g in
      let size = g.size
      ZStack {
        SurfaceHost(surface: player.surface)
        SubtitlesLayer(player: player, clock: player.clock, idle: player.idle, size: size)
        CenterLayer(sign: player.center)
        ControlsLayer(player: player, fullScreen: fullScreen)
        if let failure = player.failure {
          ErrorLayer(player: player, failure: failure)
        }
        CardsLayer(player: player, size: size)
        PlayerPanelHost(player: player, size: size)
      }
      .overlayPreferenceValue(NextButtonKey.self) { anchor in
        PeekLayer(player: player, anchor: anchor)
      }
    }
    .background(Color.black)
    .foregroundStyle(.primary)
    .environment(\.colorScheme, .dark)
  }
}

// ---- Subtitles and the middle of the picture --------------------------------------------------

private struct SubtitlesLayer: View {
  let player: PlayerModel
  let clock: PlayerClock
  let idle: Bool
  let size: CGSize

  var body: some View {
    let font = Self.font(min(38, max(18, size.width * 0.024)))
    // The pages' line-height 1.35: what it adds to the font's own line height
    // goes between lines, and half of it below the last one.
    let leading = max(0, font.pointSize * 1.35 - (font.ascender - font.descender + font.leading))
    let label = clock.subs.reduce(Text(verbatim: "")) { text, run in Text("\(text)\(styled(run))") }
      .font(Font(font))
      .lineSpacing(leading)
      .multilineTextAlignment(.center)
    // Made lines can be fixed: a click on one while paused (or E) makes it a field.
    let clickToFix = player.canFixLine && !player.playing
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      if player.editing != nil {
        LineEditor(player: player, font: font, leading: leading)
      } else if !clock.subs.isEmpty {
        // A button (a tap gesture here never fired); while playing, clicks go
        // through to the picture.
        Button { player.beginFix() } label: {
          label
            .foregroundStyle(.white)
            .background {
              // The pages' text-shadow (0 0 6px, 0 0 3px, 0 2px 3px, black). CSS draws each
              // shadow from the letters alone; stacked .shadow()s would shadow the shadows
              // too, a hard black outline. A CSS blur of b is a Gaussian of b/2, as .blur's radius.
              ZStack {
                label.foregroundStyle(.black).blur(radius: 3)
                label.foregroundStyle(.black).blur(radius: 1.5)
                label.foregroundStyle(.black).offset(y: 2).blur(radius: 1.5)
              }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(PlainTapStyle())
        .focusable(false)
        .help(clickToFix ? "Click to fix this line (E)" : "")
        .allowsHitTesting(clickToFix)
        // Paused: the lines either side, in the gap under the line. (An overlay ignores an
        // alignment guide on content inside an `if`: a frame of no height hangs it below.)
        .overlay(alignment: .bottom) {
          if clickToFix {
            LineSteps(player: player).frame(height: 0, alignment: .top).offset(y: 5)
          }
        }
      } else if clickToFix {
        // Paused between lines: back to the last one, to fix it.
        Button { player.showLine(-1) } label: {
          Label("Back to the last line", systemImage: "arrow.uturn.backward")
            .font(.app(.body, weight: .semibold))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .help("Shows the last line, paused, to fix it (E)")
      }
    }
    .padding(.horizontal, size.width * 0.06)
    .padding(.bottom, (idle ? size.height * 0.07 : PlayerMetrics.aboveBar + 10) + leading / 2)
    .frame(width: size.width, height: size.height)
    .animation(.easeOut(duration: 0.3), value: idle)
  }

  /// Avenir Next Demi Bold, sized so its lowercase letters are as tall as the
  /// system font's semibold at `size` (the size the pages chose).
  private static func font(_ size: CGFloat) -> NSFont {
    let system = NSFont.systemFont(ofSize: size, weight: .semibold)
    guard let face = NSFont(name: "AvenirNext-DemiBold", size: size) else { return system }
    return NSFont(name: "AvenirNext-DemiBold", size: size * system.xHeight / face.xHeight) ?? system
  }

  private func styled(_ run: CueRun) -> Text {
    var t = Text(verbatim: run.text)
    if run.italic { t = t.italic() }
    if run.bold { t = t.bold() }
    if run.underline { t = t.underline() }
    return t
  }
}

/// Paused on a made line: the lines either side, and how to fix this one.
private struct LineSteps: View {
  let player: PlayerModel

  var body: some View {
    HStack(spacing: 18) {
      Button("‹ Line before") { player.showLine(-1) }
        .underline()
      Text("Click the line to fix it (E)")
      Button("Line after ›") { player.showLine(1) }
        .underline()
    }
    .buttonStyle(PlainTapStyle())
    .font(.app(.callout))
    .foregroundStyle(.white.opacity(0.85))
    .shadow(color: .black, radius: 2)
    .fixedSize()
  }
}

/// A made line being fixed: a field in the line's place and type. Return saves,
/// Option-Return starts a new line, Escape cancels (Return and Escape are taken
/// by PlayerModel.onKey before the field sees them).
private struct LineEditor: View {
  let player: PlayerModel
  let font: NSFont
  let leading: CGFloat
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 8) {
      TextField("Line", text: Binding(get: { player.editing?.text ?? "" }, set: { player.setFixText($0) }), axis: .vertical)
        .textFieldStyle(.plain)
        .font(Font(font))
        .lineSpacing(leading)
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .focused($focused)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1.5))
        .frame(maxWidth: 900)
        .fixedSize(horizontal: false, vertical: true)
      Text("Return saves · ⌥Return new line · Esc cancels · names you correct are learned for this show")
        .font(.app(.callout))
        .foregroundStyle(.white.opacity(0.8))
        .shadow(color: .black, radius: 2)
    }
    .onAppear { focused = true }
  }
}

private struct CenterLayer: View {
  let sign: CenterSign

  var body: some View {
    Group {
      switch sign {
      case .none: EmptyView()
      case .spinner: Spinner()
      case .flash(let id, let icon): FlashSign(icon: icon).id(id)
      }
    }
    .allowsHitTesting(false)
  }
}

/// Play or pause, shown for a moment where the picture was clicked.
private struct FlashSign: View {
  let icon: String
  @State private var done = false

  var body: some View {
    Circle().fill(Color.black.opacity(0.45))
      .frame(width: 84, height: 84)
      .overlay { Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.white) }
      .scaleEffect(done ? 1.3 : 0.8)
      .opacity(done ? 0 : 1)
      .onAppear {
        withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.6)) { done = true }
      }
  }
}

// ---- The controls ---------------------------------------------------------------------------------

private struct ControlsLayer: View {
  let player: PlayerModel
  let fullScreen: Bool

  var body: some View {
    VStack(spacing: 0) {
      TopBar(player: player, fullScreen: fullScreen)
      Spacer(minLength: 0)
      BottomBar(player: player)
    }
    .opacity(player.idle ? 0 : 1)
    .allowsHitTesting(!player.idle)
    .animation(.easeInOut(duration: 0.3), value: player.idle)
  }
}

private struct TopBar: View {
  let player: PlayerModel
  let fullScreen: Bool
  @Environment(AppModel.self) private var app

  var body: some View {
    HStack(spacing: 12) {
      Button { player.exit() } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .controlSize(.large)
      .help("Back (Esc)")
      title
      Spacer(minLength: 0)
    }
    // Below the window's close / minimise / zoom buttons.
    .padding(EdgeInsets(top: fullScreen ? 16 : 40, leading: PlayerMetrics.margin, bottom: 36, trailing: PlayerMetrics.margin))
    .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
    .contentShape(Rectangle())
    .onHover { player.hoveringControls = $0 }
  }

  @ViewBuilder private var title: some View {
    if let fid = player.fid {
      let f = app.file(fid)
      let t = player.title
      VStack(alignment: .leading, spacing: 1) {
        Text(t?.name ?? f?.name ?? "").font(.app(.title3, weight: .bold))
        if t?.isShow == true {
          Text("\(app.epCode(fid)) · \(f?.name ?? "")").font(.app(.body)).foregroundStyle(.secondary)
        }
      }
      .lineLimit(1)
      .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }
  }
}

private struct BottomBar: View {
  let player: PlayerModel

  var body: some View {
    GlassEffectContainer {
      VStack(spacing: 2) {
        HStack(spacing: 12) {
          ElapsedLabel(clock: player.clock, player: player)
          ScrubBar(player: player)
          RemainingLabel(clock: player.clock, player: player)
        }
        ControlsRow(player: player)
      }
      .padding(EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 16))
      .frame(height: PlayerMetrics.barHeight)
      .glassEffect(playerGlass, in: .rect(cornerRadius: 26))
    }
    .padding(.horizontal, PlayerMetrics.margin)
    .padding(.bottom, PlayerMetrics.margin)
    .onHover { player.hoveringControls = $0 }
  }
}

/// The buttons of the bar: a symbol, lit by a soft circle under the pointer.
private struct PlayerButton: View {
  let icon: String
  var small = false
  let help: String
  var onHover: ((Bool) -> Void)? = nil
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: small ? 17 : 20, weight: .medium))
        .frame(width: 40, height: 40)
        .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0)))
        .contentShape(Circle())
    }
    .buttonStyle(PressStyle())
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onHover { inside in
      hovering = inside
      onHover?(inside)
    }
    .help(help)
  }
}

/// Dims a chromeless button while it is pressed.
struct PressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
  }
}

// ---- The seek bar -------------------------------------------------------------------------------------

private struct ElapsedLabel: View {
  let clock: PlayerClock
  let player: PlayerModel

  var body: some View {
    Text(fmtTime(player.dragging ? player.dragTime : clock.time))
      .font(.app(.callout))
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .frame(minWidth: 44, alignment: .leading)
  }
}

private struct RemainingLabel: View {
  let clock: PlayerClock
  let player: PlayerModel

  var body: some View {
    let dur = player.duration
    let t = player.dragging ? player.dragTime : clock.time
    Text(dur > 0 ? "-\(fmtTime(max(0, dur - t)))" : "")
      .font(.app(.callout))
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .frame(minWidth: 44, alignment: .trailing)
      .help("\(fmtTime(t)) of \(fmtTime(dur))")
  }
}

private struct ScrubBar: View {
  let player: PlayerModel
  @State private var hovering = false
  /// Where the pointer is along the bar.
  @State private var pointerX: CGFloat = 0

  static let thumbWidth: CGFloat = 220

  var body: some View {
    GeometryReader { g in
      let w = g.size.width
      let dur = player.duration
      let lit = hovering || player.dragging
      ZStack(alignment: .leading) {
        ZStack(alignment: .leading) {
          Color.white.opacity(0.22)
          if dur > 0 { segments(width: w, duration: dur) }
          ScrubFill(player: player, width: w, knob: nil)
        }
        .frame(height: lit ? 8 : 5)
        .clipShape(Capsule())
        ScrubFill(player: player, width: w, knob: lit)
      }
      .frame(width: w, height: 22)
      .animation(.easeOut(duration: 0.12), value: lit)
      .contentShape(Rectangle())
      .overlay(alignment: .topLeading) {
        if lit { tip(width: w, duration: dur) }
      }
      .onContinuousHover { phase in
        switch phase {
        case .active(let p):
          hovering = true
          pointerX = p.x
        case .ended:
          hovering = false
        }
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { v in
            guard dur > 0 else { return }
            pointerX = v.location.x
            player.dragging = true
            player.dragTime = time(at: v.location.x, width: w, duration: dur)
          }
          .onEnded { _ in
            guard player.dragging else { return }
            player.dragging = false
            player.seek(player.dragTime)
          })
    }
    .frame(height: 22)
  }

  private func time(at x: CGFloat, width: CGFloat, duration: Double) -> Double {
    Double(max(0, min(1, x / max(1, width)))) * duration
  }

  @ViewBuilder private func segments(width w: CGFloat, duration dur: Double) -> some View {
    let m = player.markers
    if let intro = m.intro {
      Color(red: 130 / 255, green: 200 / 255, blue: 1, opacity: 0.5)
        .frame(width: max(0, w * CGFloat((intro.end - intro.start) / dur)))
        .offset(x: w * CGFloat(intro.start / dur))
        .help("Intro")
    }
    if let credits = m.credits {
      Color(red: 190 / 255, green: 150 / 255, blue: 1, opacity: 0.5)
        .frame(width: max(0, w * CGFloat((dur - credits.start) / dur)))
        .offset(x: w * CGFloat(credits.start / dur))
        .help("Credits")
    }
  }

  /// The time under the pointer, with the preview frame there.
  @ViewBuilder private func tip(width w: CGFloat, duration dur: Double) -> some View {
    let t = time(at: pointerX, width: w, duration: dur)
    let m = player.markers
    let place =
      m.intro.map { t >= $0.start && t < $0.end } == true
      ? " · Intro" : m.credits.map { t >= $0.start } == true ? " · Credits" : ""
    let trick = player.trick
    let half: CGFloat = trick != nil ? ScrubBar.thumbWidth / 2 + 5 : 34
    let x = max(half, min(w - half, pointerX))
    VStack(spacing: 5) {
      if let trick {
        let h = (trick.height * Double(ScrubBar.thumbWidth) / trick.width).rounded()
        ZStack {
          Color.black
          if let frame = player.trickFrame(t) {
            Image(decorative: frame, scale: 1).resizable()
          }
        }
        .frame(width: ScrubBar.thumbWidth, height: CGFloat(h))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
      Text(fmtTime(t) + place).font(.app(.callout, weight: .medium)).monospacedDigit()
    }
    .padding(EdgeInsets(top: trick != nil ? 5 : 4, leading: trick != nil ? 5 : 10, bottom: 5, trailing: trick != nil ? 5 : 10))
    .background(RoundedRectangle(cornerRadius: trick != nil ? 13 : 9).fill(Color.black.opacity(0.82)))
    .overlay(RoundedRectangle(cornerRadius: trick != nil ? 13 : 9).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    .fixedSize()
    // Centred on x, above the bar: a zero-size frame there, which the tip
    // overflows upwards. (An overlay ignores the alignment guides of `if` content.)
    .frame(width: 0, height: 0, alignment: .bottom)
    .offset(x: x, y: -14)
    .allowsHitTesting(false)
  }
}

/// The played part of the seek bar, or (`knob` set: shown or not) its knob:
/// redrawn as the clock runs.
private struct ScrubFill: View {
  let player: PlayerModel
  let width: CGFloat
  let knob: Bool?

  var body: some View {
    let dur = player.duration
    let t = player.dragging ? player.dragTime : player.clock.time
    let x = dur > 0 ? width * CGFloat(max(0, min(1, t / dur))) : 0
    if let knob {
      Circle().fill(Color.white).frame(width: 16, height: 16)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .scaleEffect(knob ? 1 : 0)
        .offset(x: x - 8)
    } else {
      Theme.accent.frame(width: x)
    }
  }
}

// ---- The row of buttons --------------------------------------------------------------------------------

private struct ControlsRow: View {
  let player: PlayerModel
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win

  var body: some View {
    HStack(spacing: 2) {
      PlayerButton(icon: player.playing ? "pause.fill" : "play.fill", help: "Play / pause (Space)") { player.togglePlay() }
      PlayerButton(icon: "gobackward.10", help: "Back 10 s (←)") { player.seek(player.time - 10) }
      PlayerButton(icon: "goforward.10", help: "Forward 10 s (→)") { player.seek(player.time + 10) }
      VolumeControl(player: player)
      Text(midTitle)
        .font(.app(.body))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
      if player.nextId != nil {
        PlayerButton(icon: "forward.end.fill", small: true, help: "Next episode (N)", onHover: { player.buttonHover(.next, $0) }) {
          player.buttonClick(.next)
        }
        .anchorPreference(key: NextButtonKey.self, value: .bounds) { $0 }
      }
      if showsEpisodes {
        PlayerButton(icon: "rectangle.stack.fill", small: true, help: "Episodes", onHover: { player.buttonHover(.episodes, $0) }) {
          player.buttonClick(.episodes)
        }
      }
      SpeedButton(player: player)
      PlayerButton(
        icon: "captions.bubble.fill", small: true, help: "Audio, subtitles, intro markers",
        onHover: { player.buttonHover(.settings, $0) }
      ) {
        player.buttonClick(.settings)
      }
      PlayerButton(
        icon: win.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", small: true,
        help: "Full screen (F)"
      ) {
        player.toggleFullScreen()
      }
    }
  }

  private var midTitle: String {
    guard let fid = player.fid else { return "" }
    guard let t = player.title else { return app.file(fid)?.name ?? "" }
    return t.isShow ? "\(app.epCode(fid)) · \(app.file(fid)?.name ?? "")" : t.name
  }

  /// Shows, and films in more than one part.
  private var showsEpisodes: Bool {
    guard let t = player.title else { return false }
    return t.isShow || (t.seasons.first?.episodes.count ?? 0) > 1
  }
}

/// Mute, and the volume (up to 200%) with its level, shown under the pointer.
private struct VolumeControl: View {
  let player: PlayerModel
  @State private var hovering = false

  var body: some View {
    let level = player.level
    HStack(spacing: 0) {
      PlayerButton(icon: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", small: true, help: "Mute (M)") {
        player.toggleMute()
      }
      VolumeSlider(value: player.volume) { player.setVolume($0) }
        .frame(width: hovering ? 110 : 0)
        .opacity(hovering ? 1 : 0)
        .padding(.trailing, hovering ? 8 : 0)
      Text("\(Int(jsRound(level * 100)))%")
        .font(.app(size: 13, weight: level > 1 ? .bold : .regular))
        .monospacedDigit()
        .foregroundStyle(level > 1 ? AnyShapeStyle(Theme.boost) : AnyShapeStyle(.secondary))
        .lineLimit(1)
        .fixedSize()
        .frame(width: hovering ? 44 : 0, alignment: .leading)
        .clipped()
        .opacity(hovering ? 1 : 0)
    }
    .animation(.easeOut(duration: 0.2), value: hovering)
    .onHover { hovering = $0 }
  }
}

/// 0...200%, in steps of 5%.
private struct VolumeSlider: View {
  let value: Double
  let onChange: (Double) -> Void

  var body: some View {
    GeometryReader { g in
      let w = g.size.width
      let x = w * CGFloat(max(0, min(1, value / Prefs.maxVolume)))
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.25)).frame(height: 5)
        Capsule().fill(Color.white).frame(width: x, height: 5)
        Circle().fill(Color.white).frame(width: 13, height: 13)
          .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
          .offset(x: max(0, min(w - 13, x - 6.5)))
      }
      .frame(width: w, height: g.size.height)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { v in
          let f = Double(max(0, min(1, v.location.x / max(1, w))))
          onChange((f * Prefs.maxVolume * 20).rounded() / 20)
        })
    }
    .frame(height: 20)
    .help("Volume")
  }
}

private struct SpeedButton: View {
  let player: PlayerModel
  @State private var hovering = false

  var body: some View {
    let changed = player.speed != 1
    Button {
      player.buttonClick(.speed)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 17, weight: .medium))
        if changed {
          Text(fmtSpeed(player.speed)).font(.app(size: 13, weight: .bold)).monospacedDigit()
        }
      }
      .padding(.horizontal, changed ? 10 : 0)
      .frame(minWidth: 40, minHeight: 40)
      .background(Capsule().fill(Color.white.opacity(hovering ? 0.14 : 0)))
      .contentShape(Capsule())
    }
    .buttonStyle(PressStyle())
    .foregroundStyle(changed ? AnyShapeStyle(Theme.boost) : AnyShapeStyle(.primary))
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onHover { inside in
      hovering = inside
      player.buttonHover(.speed, inside)
    }
    .help("Playback speed ([ and ])")
  }
}

// ---- Skip Intro and the Next Episode card --------------------------------------------------------------

private struct CardsLayer: View {
  let player: PlayerModel
  let size: CGSize

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if player.skipVisible {
        Button { player.skipIntro() } label: {
          Label("Skip Intro", systemImage: "forward.fill")
            .font(.app(.title3, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .buttonStyle(.glass)
        .controlSize(.extraLarge)
        .help("Skip Intro (S)")
        .transition(.rise)
      }
      if let next = player.nextCard {
        NextCard(player: player, next: next)
          .frame(width: min(360, size.width * 0.9))
          .transition(.rise)
      }
    }
    .padding(.trailing, PlayerMetrics.margin)
    .padding(.bottom, player.idle ? 40 : PlayerMetrics.aboveBar)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    .animation(.easeOut(duration: 0.3), value: player.skipVisible)
    .animation(.easeOut(duration: 0.35), value: player.nextCard)
    .animation(.easeOut(duration: 0.3), value: player.idle)
  }
}

private struct NextCard: View {
  let player: PlayerModel
  let next: String
  @Environment(AppModel.self) private var app

  var body: some View {
    let name = app.file(next)?.name ?? ""
    let code = app.epCode(next)
    VStack(alignment: .leading, spacing: 0) {
      ArtBox(.file(next, width: 480), radius: 14, previewing: next)
      VStack(alignment: .leading, spacing: 2) {
        Text(code.isEmpty ? "Up Next" : "Up Next · \(code)")
          .font(.app(.caption, weight: .semibold))
          .foregroundStyle(.secondary)
        Text(name)
          .font(.app(.headline))
          .lineLimit(2)
      }
      .padding(EdgeInsets(top: 10, leading: 4, bottom: 12, trailing: 4))
      HStack(spacing: 8) {
        CardButton(accent: true, action: { player.playNext() }) {
          Label("Next Episode", systemImage: "play.fill")
        } fill: {
          CountdownFill(clock: player.clock)
        }
        CardButton(accent: false, action: { player.dismissNext() }) {
          Text("Watch Credits")
        } fill: {
          EmptyView()
        }
      }
    }
    .padding(10)
    .glassEffect(playerGlass, in: .rect(cornerRadius: 24))
  }
}

/// The Next card's buttons: as wide as each other, amber or quiet.
private struct CardButton<Label: View, Fill: View>: View {
  let accent: Bool
  let action: () -> Void
  @ViewBuilder let label: Label
  @ViewBuilder let fill: Fill
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      label
        .font(.app(size: 14, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(accent ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(alignment: .leading) {
          ZStack(alignment: .leading) {
            accent ? Theme.accent.opacity(hovering ? 0.88 : 1) : Color.white.opacity(hovering ? 0.2 : 0.12)
            fill
          }
        }
        .clipShape(Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(PressStyle())
    .onHover { hovering = $0 }
  }
}

/// How much of the countdown to the next episode has run.
private struct CountdownFill: View {
  let clock: PlayerClock

  var body: some View {
    GeometryReader { g in
      Color.black.opacity(0.16).frame(width: g.size.width * CGFloat(max(0, min(1, clock.countdown))))
    }
  }
}

// ---- The card above the Next button ----------------------------------------------------------------------

private struct PeekLayer: View {
  let player: PlayerModel
  let anchor: Anchor<CGRect>?

  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .topLeading) {
        Color.clear
        if player.peekVisible, let anchor, let next = player.nextId {
          let b = g[anchor]
          let w = min(320, g.size.width - 32)
          let left = max(16, min(g.size.width - w - 16, b.midX - w / 2))
          PeekCard(player: player, next: next)
            .frame(width: w)
            .alignmentGuide(.leading) { _ in -left }
            // Above the bar, not just the button.
            .alignmentGuide(.top) { d in d.height - (g.size.height - PlayerMetrics.aboveBar) }
            .opacity(player.idle ? 0 : 1)
            .allowsHitTesting(!player.idle)
            .transition(.rise)
        }
      }
      .animation(.easeOut(duration: 0.2), value: player.peekVisible)
    }
  }
}

private struct PeekCard: View {
  let player: PlayerModel
  let next: String
  @Environment(AppModel.self) private var app
  @State private var hovering = false

  var body: some View {
    let f = app.file(next)
    let p = app.progress(next)
    let dur = f?.duration ?? 0
    VStack(alignment: .leading, spacing: 0) {
      Text("Next Episode")
        .font(.app(.caption, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(EdgeInsets(top: 2, leading: 4, bottom: 8, trailing: 4))
      ArtBox(.file(next, width: 480), radius: 12, previewing: next, previewEvery: 0.9) {
        if let p, p.duration != 0 { ProgressEdge(fraction: AppModel.fraction(p)) }
      }
      VStack(alignment: .leading, spacing: 2) {
        Text([app.epCode(next), f?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
          .underline(hovering)
          .font(.app(.headline))
          .lineLimit(1)
        if dur != 0 && !dur.isNaN {
          Text("\(Int(jsRound(dur / 60))) min").font(.app(.subheadline)).foregroundStyle(.secondary)
        }
      }
      .padding(EdgeInsets(top: 10, leading: 4, bottom: 4, trailing: 4))
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassEffect(playerGlass, in: .rect(cornerRadius: 22))
    .contentShape(RoundedRectangle(cornerRadius: 22))
    .onTapGesture { player.playNext() }
    .onHover { inside in
      hovering = inside
      player.peekHover(inside)
    }
  }
}

// ---- When a video can't be played -------------------------------------------------------------------------

private struct ErrorLayer: View {
  let player: PlayerModel
  let failure: PlayerFailure

  var body: some View {
    VStack(spacing: 0) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 34))
        .foregroundStyle(Theme.warn)
        .padding(.bottom, 14)
      Text(failure.title)
        .font(.app(.title2, weight: .bold))
        .padding(.bottom, 6)
      Text(failure.message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 520)
        .padding(.bottom, 20)
      HStack(spacing: 10) {
        PrimaryButton("Try Again", large: false) { player.retry() }
        Button("Back") { player.exit() }.glassButton(large: false)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.opacity(0.75))
  }
}
