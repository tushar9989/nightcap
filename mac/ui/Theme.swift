import AppKit
import SwiftUI

// The look: macOS's own (system colours, type styles and controls, light or
// dark as the Mac is set), with an amber accent.

enum Theme {
  /// The accent: amber, a little deeper in light mode so it holds up on white.
  static let accent = Color(nsColor: NSColor(name: "NightcapAccent") { look in
    look.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0xe8 / 255, green: 0xa3 / 255, blue: 0x3d / 255, alpha: 1)
      : NSColor(srgbRed: 0xd4 / 255, green: 0x89 / 255, blue: 0x1a / 255, alpha: 1)
  })
  /// Behind the pages (white in light mode, the window's grey in dark), which pictures fade into.
  static let page = Color(nsColor: NSColor(name: "NightcapPage") { look in
    look.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .windowBackgroundColor : .textBackgroundColor
  })
  /// Text and symbols on an accent fill.
  static let onAccent = Color(hex: 0x1d1505)
  static let ok = Color.green
  static let warn = Color.orange
  static let error = Color.red
  /// Volume above 100%, speed other than normal (the player is always dark).
  static let boost = Color(hex: 0xffb347)
  static let line = Color(nsColor: .separatorColor)
  static let hover = Color.primary.opacity(0.06)
  static let text2 = Color.secondary
  static let text3 = Color(nsColor: .tertiaryLabelColor)

  /// Pictures' corners.
  static let radius: CGFloat = 10
  static let gridMin: CGFloat = 220
  static let gridWideMin: CGFloat = 300
}

/// Widths that change the layout (of the page, not the window).
struct Metrics {
  var width: CGFloat
  var pad: CGFloat { width < 640 ? 24 : 40 }
  /// Episode rows drop their numbers and use smaller pictures.
  var narrow: Bool { width < 700 }
}

private struct MetricsKey: EnvironmentKey {
  static let defaultValue = Metrics(width: 1000)
}

extension EnvironmentValues {
  var metrics: Metrics {
    get { self[MetricsKey.self] }
    set { self[MetricsKey.self] = newValue }
  }
}

extension Color {
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255, opacity: opacity)
  }
}

// ---- Formatting (as the pages wrote numbers and times) -----------------------------

/// 1:02:03, or 2:03 under an hour.
func fmtTime(_ seconds: Double) -> String {
  let s = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
  let hh = s / 3600, mm = (s % 3600) / 60, ss = s % 60
  let sec = ss < 10 ? "0\(ss)" : "\(ss)"
  if hh > 0 { return "\(hh):\(mm < 10 ? "0\(mm)" : "\(mm)"):\(sec)" }
  return "\(mm):\(sec)"
}

/// "45m", "1h 52m"; "" when unknown.
func fmtDur(_ seconds: Double) -> String {
  guard seconds != 0, !seconds.isNaN else { return "" }
  let m = Int(jsRound(seconds / 60))
  return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

/// A number as JavaScript prints `+x.toFixed(digits)`: "1.5", "2", "0.25".
func fixedNumber(_ x: Double, _ digits: Int) -> String {
  jsNumber(jsNumberValue(toFixed(x, digits)))
}

/// A whole or fractional count as JavaScript prints it.
func countText(_ x: Double) -> String { jsNumber(x) }

// ---- Buttons ------------------------------------------------------------------------

/// The main action (Play, Resume, Add Folder): amber glass, dark label. The label's
/// colour is set inside it: prominent glass draws its own (white, faint on amber)
/// over one set on the button.
struct PrimaryButton<L: View>: View {
  var large = true
  let action: () -> Void
  @ViewBuilder let label: () -> L

  var body: some View {
    Button(action: action) { label().foregroundStyle(Theme.onAccent) }
      .buttonStyle(.glassProminent)
      .tint(Theme.accent)
      .controlSize(large ? .extraLarge : .regular)
  }
}

extension PrimaryButton where L == Text {
  init(_ title: String, large: Bool = true, action: @escaping () -> Void) {
    self.init(large: large, action: action) { Text(title) }
  }
}

extension View {
  /// Other actions beside it: plain glass.
  func glassButton(large: Bool = true) -> some View {
    self
      .buttonStyle(.glass)
      .tint(nil)
      .controlSize(large ? .extraLarge : .regular)
  }
}

/// A button without any chrome of its own (tiles, rows, the player's controls).
struct PlainTapStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.contentShape(Rectangle())
  }
}

/// Quiet text buttons ("Mark Season Watched", "Remove"): secondary, primary under the pointer.
struct QuietButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    QuietButtonBody(configuration: configuration)
  }
}

private struct QuietButtonBody: View {
  let configuration: ButtonStyleConfiguration
  @State private var hovering = false
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    configuration.label
      .lineLimit(1)
      .foregroundStyle(hovering && enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      .padding(.vertical, 4)
      .padding(.horizontal, 8)
      .background(Capsule().fill(hovering && enabled ? Theme.hover : .clear))
      .contentShape(Capsule())
      .opacity(configuration.isPressed ? 0.6 : enabled ? 1 : 0.5)
      .onHover { hovering = $0 }
  }
}

// ---- Small pieces ---------------------------------------------------------------------

/// The player's loading ring.
struct Spinner: View {
  var size: CGFloat = 64
  var line: CGFloat = 5
  @State private var turn = false

  var body: some View {
    ZStack {
      Circle().stroke(Color.white.opacity(0.2), lineWidth: line)
      Circle().trim(from: 0, to: 0.25).stroke(Theme.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
        .rotationEffect(.degrees(turn ? 360 : 0))
    }
    .frame(width: size - line, height: size - line)
    .onAppear {
      withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turn = true }
    }
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
    .foregroundStyle(armed ? AnyShapeStyle(Theme.error) : AnyShapeStyle(.primary))
    .fixedSize()
    .help(help ?? "")
    .task(id: armed) {
      guard armed else { return }
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      if !Task.isCancelled { armed = false }
    }
  }
}

/// Buttons and notes that wrap onto more lines when there isn't room.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 8

  private func lines(_ width: CGFloat, _ subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
    var out: [[(index: Int, size: CGSize)]] = [[]]
    var x: CGFloat = 0
    for (i, v) in subviews.enumerated() {
      let s = v.sizeThatFits(.unspecified)
      if x > 0 && x + s.width > width {
        out.append([])
        x = 0
      }
      out[out.count - 1].append((i, s))
      x += s.width + spacing
    }
    return out
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    let ls = lines(width, subviews)
    let height = ls.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) } + lineSpacing * CGFloat(max(0, ls.count - 1))
    let widest = ls.map { line in line.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, line.count - 1)) }.max() ?? 0
    return CGSize(width: proposal.width ?? widest, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for line in lines(bounds.width, subviews) {
      let h = line.map(\.size.height).max() ?? 0
      var x = bounds.minX
      for item in line {
        subviews[item.index].place(
          at: CGPoint(x: x, y: y + (h - item.size.height) / 2), proposal: ProposedViewSize(item.size))
        x += item.size.width + spacing
      }
      y += h + lineSpacing
    }
  }
}
