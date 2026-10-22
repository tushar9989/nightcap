import AppKit
import SwiftUI

// What the player shows over the window: the picture, subtitles, the controls
// (hidden after 3 s of playing untouched), Skip Intro, the Next Episode card,
// the card above the Next button, and the panels (PlayerPanels.swift). Sizes
// follow the player section of the pages' styles.

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
  /// The pages' `rise`: up a little, from transparent.
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

struct PlayerView: View {
  let player: PlayerModel
  let topInset: CGFloat

  var body: some View {
    GeometryReader { g in
      let size = g.size
      ZStack {
        SurfaceHost(surface: player.surface)
        SubtitlesLayer(clock: player.clock, idle: player.idle, size: size)
        CenterLayer(sign: player.center)
        ControlsLayer(player: player, topInset: topInset)
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
    .foregroundStyle(.white)
  }
}

// ---- Subtitles and the middle of the picture --------------------------------------------------

private struct SubtitlesLayer: View {
  let clock: PlayerClock
  let idle: Bool
  let size: CGSize

  var body: some View {
    let fontSize = min(38, max(18, size.width * 0.024))
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      if !clock.subs.isEmpty {
        clock.subs.reduce(Text(verbatim: "")) { text, run in Text("\(text)\(styled(run))") }
          .font(.system(size: fontSize, weight: .semibold))
          .lineSpacing(fontSize * 0.15)
          .multilineTextAlignment(.center)
          .foregroundStyle(.white)
          .shadow(color: .black, radius: 3)
          .shadow(color: .black, radius: 1.5)
          .shadow(color: .black, radius: 1.5, y: 2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, size.width * 0.06)
    .padding(.bottom, idle ? size.height * 0.07 : 150)
    .frame(width: size.width, height: size.height)
    .animation(.easeOut(duration: 0.3), value: idle)
    .allowsHitTesting(false)
  }

  private func styled(_ run: CueRun) -> Text {
    var t = Text(verbatim: run.text)
    if run.italic { t = t.italic() }
    if run.bold { t = t.bold() }
    if run.underline { t = t.underline() }
    return t
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
    Circle().fill(Color.black.opacity(0.5))
      .frame(width: 84, height: 84)
      .overlay { Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.white) }
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
  let topInset: CGFloat

  var body: some View {
    VStack(spacing: 0) {
      TopBar(player: player, topInset: topInset)
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
  let topInset: CGFloat
  @Environment(AppModel.self) private var app

  var body: some View {
    HStack(spacing: 18) {
      PlayerButton(icon: "arrow.left", help: "Back (Esc)") { player.exit() }
      title
      Spacer(minLength: 0)
    }
    // Below the window's close / minimise / zoom buttons.
    .padding(EdgeInsets(top: max(22, topInset + 6), leading: 28, bottom: 60, trailing: 28))
    .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
    .contentShape(Rectangle())
    .onHover { player.hoveringControls = $0 }
  }

  @ViewBuilder private var title: some View {
    if let fid = player.fid {
      let f = app.file(fid)
      let t = player.title
      HStack(spacing: 10) {
        Text(t?.name ?? f?.name ?? "").fontWeight(.bold)
        if t?.isShow == true {
          Text("\(app.epCode(fid))  \(f?.name ?? "")").foregroundStyle(Color(hex: 0xcccccc))
        }
      }
      .font(.system(size: 17))
      .lineLimit(1)
      .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }
  }
}

private struct BottomBar: View {
  let player: PlayerModel

  var body: some View {
    VStack(spacing: 6) {
      ScrubBar(player: player)
      ControlsRow(player: player)
    }
    .padding(EdgeInsets(top: 70, leading: 28, bottom: 18, trailing: 28))
    .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
    .contentShape(Rectangle())
    .onHover { player.hoveringControls = $0 }
  }
}

/// The round buttons of the controls; they grow under the pointer.
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
        .font(.system(size: small ? 20 : 23, weight: .medium))
        .frame(width: 46, height: 46)
        .contentShape(Circle())
    }
    .buttonStyle(PlainTapStyle())
    .foregroundStyle(.white)
    .scaleEffect(hovering ? 1.18 : 1)
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onHover { inside in
      hovering = inside
      onHover?(inside)
    }
    .help(help)
  }
}

// ---- The seek bar -------------------------------------------------------------------------------------

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
          Color.white.opacity(0.25)
          if dur > 0 { segments(width: w, duration: dur) }
          ScrubFill(player: player, width: w, knob: nil)
        }
        .frame(height: lit ? 7 : 4)
        ScrubFill(player: player, width: w, knob: lit)
      }
      .frame(width: w, height: 22)
      .animation(.easeOut(duration: 0.12), value: lit)
      .contentShape(Rectangle())
      .overlay(alignment: .bottomLeading) {
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
      Color(red: 130 / 255, green: 200 / 255, blue: 1, opacity: 0.55)
        .frame(width: max(0, w * CGFloat((intro.end - intro.start) / dur)))
        .offset(x: w * CGFloat(intro.start / dur))
        .help("Intro")
    }
    if let credits = m.credits {
      Color(red: 190 / 255, green: 150 / 255, blue: 1, opacity: 0.55)
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
    let half: CGFloat = trick != nil ? ScrubBar.thumbWidth / 2 + 4 : 30
    let x = max(half, min(w - half, pointerX))
    VStack(spacing: 4) {
      if let trick, let fid = player.fid {
        let h = (trick.height * Double(ScrubBar.thumbWidth) / trick.width).rounded()
        ZStack {
          Color.black
          if let frame = Previews.cachedFrame(fid, trick, t) {
            Image(decorative: frame, scale: 1).resizable()
          }
        }
        .frame(width: ScrubBar.thumbWidth, height: CGFloat(h))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .padding(.horizontal, -4)
        .padding(.top, 1)
      }
      Text(fmtTime(t) + place).font(.system(size: 13)).monospacedDigit()
    }
    .padding(.vertical, 3)
    .padding(.horizontal, 8)
    .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255).opacity(0.9)))
    .fixedSize()
    .alignmentGuide(.leading) { d in d.width / 2 - x }
    .alignmentGuide(.bottom) { d in d.height + 22 }
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
      Circle().fill(Theme.accent).frame(width: 16, height: 16)
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
    HStack(spacing: 10) {
      PlayerButton(icon: player.playing ? "pause.fill" : "play.fill", help: "Play / pause (Space)") { player.togglePlay() }
      PlayerButton(icon: "gobackward.10", help: "Back 10 s (←)") { player.seek(player.time - 10) }
      PlayerButton(icon: "goforward.10", help: "Forward 10 s (→)") { player.seek(player.time + 10) }
      VolumeControl(player: player)
      Text(midTitle)
        .font(.system(size: 15))
        .foregroundStyle(Color(hex: 0xdddddd))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
      TimeLabel(player: player)
      if player.nextId != nil {
        PlayerButton(icon: "forward.end.fill", small: true, help: "Next episode (N)", onHover: { player.buttonHover(.next, $0) }) {
          player.buttonClick(.next)
        }
        .anchorPreference(key: NextButtonKey.self, value: .bounds) { $0 }
      }
      if showsEpisodes {
        PlayerButton(icon: "play.rectangle.on.rectangle.fill", small: true, help: "Episodes", onHover: { player.buttonHover(.episodes, $0) }) {
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
    guard let fid = player.fid, let t = player.title else { return "" }
    return t.isShow ? "\(app.epCode(fid)) · \(app.file(fid)?.name ?? "")" : t.name
  }

  /// Shows, and films in more than one part.
  private var showsEpisodes: Bool {
    guard let t = player.title else { return false }
    return t.isShow || (t.seasons.first?.episodes.count ?? 0) > 1
  }
}

private struct TimeLabel: View {
  let player: PlayerModel

  var body: some View {
    let t = player.clock.time
    let dur = player.duration
    Text(dur > 0 ? "-\(fmtTime(dur - t))" : fmtTime(t))
      .font(.system(size: 14))
      .monospacedDigit()
      .foregroundStyle(Color(hex: 0xdddddd))
      .frame(minWidth: 54, alignment: .trailing)
      .help("\(fmtTime(t)) / \(fmtTime(dur))")
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
        .padding(.trailing, hovering ? 6 : 0)
      Text("\(Int(jsRound(level * 100)))%")
        .font(.system(size: 13, weight: level > 1 ? .bold : .regular))
        .monospacedDigit()
        .foregroundStyle(level > 1 ? Theme.boost : Color(hex: 0xdddddd))
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
        Capsule().fill(Color.white.opacity(0.3)).frame(height: 4)
        Capsule().fill(Color.white).frame(width: x, height: 4)
        Circle().fill(Color.white).frame(width: 12, height: 12).offset(x: max(0, min(w - 12, x - 6)))
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
      player.togglePanel(.speed)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "speedometer").font(.system(size: 20, weight: .medium))
        if changed {
          Text(fmtSpeed(player.speed)).font(.system(size: 13, weight: .bold)).monospacedDigit()
        }
      }
      .padding(.horizontal, 6)
      .frame(minWidth: 46, minHeight: 46)
      .contentShape(Capsule())
    }
    .buttonStyle(PlainTapStyle())
    .foregroundStyle(changed ? Theme.boost : .white)
    .scaleEffect(hovering ? 1.18 : 1)
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onHover { hovering = $0 }
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
        SkipButton { player.skipIntro() }
          .transition(.rise)
      }
      if let next = player.nextCard {
        NextCard(player: player, next: next)
          .frame(width: min(380, size.width * 0.9))
          .transition(.rise)
      }
    }
    .padding(.trailing, size.width * 0.04)
    .padding(.bottom, player.idle ? 60 : 150)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    .animation(.easeOut(duration: 0.3), value: player.skipVisible)
    .animation(.easeOut(duration: 0.35), value: player.nextCard)
    .animation(.easeOut(duration: 0.3), value: player.idle)
  }
}

private struct SkipButton: View {
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: "forward.fill").font(.system(size: 17))
        Text("Skip Intro")
      }
      .font(.system(size: 17, weight: .bold))
      .foregroundStyle(hovering ? Color.black : Color.white)
      .padding(.vertical, 12)
      .padding(.horizontal, 26)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(hovering ? Color.white : Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255).opacity(0.72))
      )
      .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.75), lineWidth: 2))
      .contentShape(Rectangle())
    }
    .buttonStyle(PlainTapStyle())
    .onHover { hovering = $0 }
    .help("Skip Intro (S)")
  }
}

private struct NextCard: View {
  let player: PlayerModel
  let next: String
  @Environment(AppModel.self) private var app

  var body: some View {
    let name = app.file(next)?.name ?? ""
    VStack(alignment: .leading, spacing: 0) {
      ArtBox(.file(next, width: 480), seed: name, radius: 0, previewing: next)
      VStack(alignment: .leading, spacing: 0) {
        Text("Up next · \(app.epCode(next))")
          .textCase(.uppercase)
          .font(.system(size: 12))
          .tracking(0.96)
          .foregroundStyle(Theme.text2)
        Text(name)
          .font(.system(size: 17, weight: .bold))
          .lineLimit(2)
          .padding(.top, 4)
          .padding(.bottom, 14)
        HStack(spacing: 10) {
          CardButton(accent: true, action: { player.playNext() }) {
            HStack(spacing: 8) {
              Image(systemName: "play.fill").font(.system(size: 15))
              Text("Next Episode")
            }
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
      .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
    }
    .background(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255).opacity(0.94))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
  }
}

/// The Next card's buttons: as wide as each other, accent or ghost.
private struct CardButton<Label: View, Fill: View>: View {
  let accent: Bool
  let action: () -> Void
  @ViewBuilder let label: Label
  @ViewBuilder let fill: Fill
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      label
        .font(.system(size: 15, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(accent ? Theme.onAccent : Theme.text)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(alignment: .leading) {
          ZStack(alignment: .leading) {
            accent ? (hovering ? Theme.accent2 : Theme.accent) : Color.white.opacity(hovering ? 0.14 : 0.08)
            fill
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(PlainTapStyle())
    .onHover { hovering = $0 }
  }
}

/// How much of the countdown to the next episode has run.
private struct CountdownFill: View {
  let clock: PlayerClock

  var body: some View {
    GeometryReader { g in
      Color.black.opacity(0.18).frame(width: g.size.width * CGFloat(max(0, min(1, clock.countdown))))
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
            .alignmentGuide(.top) { d in d.height - (b.minY - 12) }
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
        .textCase(.uppercase)
        .font(.system(size: 12))
        .tracking(0.96)
        .foregroundStyle(Theme.text2)
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
      ArtBox(.file(next, width: 480), seed: f?.name ?? "", radius: 0, previewing: next, previewEvery: 0.9) {
        if let p, p.duration != 0 { ProgressEdge(fraction: AppModel.fraction(p)) }
      }
      VStack(alignment: .leading, spacing: 3) {
        Text("\(app.epCode(next)) · \(f?.name ?? "")")
          .underline(hovering)
          .font(.system(size: 15, weight: .bold))
          .lineLimit(1)
        if dur != 0 && !dur.isNaN {
          Text("\(Int(jsRound(dur / 60))) min").font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
      }
      .padding(EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 14))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.overlay)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    .shadow(color: .black.opacity(0.7), radius: 20, y: 10)
    .contentShape(Rectangle())
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
      Text(failure.title)
        .font(.system(size: 24, weight: .bold))
        .padding(.bottom, 8)
      Text(failure.message)
        .font(.system(size: 15))
        .foregroundStyle(Color(hex: 0xbbbbbb))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 520)
        .padding(.bottom, 18)
      HStack(spacing: 8) {
        Button("Try again") { player.retry() }.buttonStyle(PillButtonStyle(kind: .accent))
        Button("Back") { player.exit() }.buttonStyle(PillButtonStyle())
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.opacity(0.75))
  }
}
