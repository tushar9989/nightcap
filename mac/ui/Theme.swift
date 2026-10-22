import AppKit
import SwiftUI

// The look: dark, with an amber accent. Sizes are points, as the pages' CSS
// pixels were.

enum Theme {
  static let bg = Color(hex: 0x18181a)
  static let side = Color(hex: 0x1f1f22)
  static let panel = Color(hex: 0x232327)
  static let panel2 = Color(hex: 0x2c2c31)
  static let hover = Color.white.opacity(0.055)
  static let sel = Color.white.opacity(0.1)
  static let line = Color.white.opacity(0.08)
  static let text = Color(hex: 0xededf0)
  static let text2 = Color(hex: 0xa0a0a8)
  static let text3 = Color(hex: 0x6a6a72)
  static let accent = Color(hex: 0xe8a33d)
  static let accent2 = Color(hex: 0xf5b552)
  static let onAccent = Color(hex: 0x1d1505)
  static let ok = Color(hex: 0x62c584)
  static let warn = Color(hex: 0xf0a35e)
  static let error = Color(hex: 0xff9a9a)
  static let boost = Color(hex: 0xffb347)
  /// Player overlays (panels, cards).
  static let overlay = Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255).opacity(0.96)

  static let nsBackground = NSColor(srgbRed: 0x18 / 255, green: 0x18 / 255, blue: 0x1a / 255, alpha: 1)

  static let radius: CGFloat = 8
  static let gridMin: CGFloat = 210
  static let gridWideMin: CGFloat = 300
}

/// Widths that change the layout, as the pages' media queries did.
struct Metrics {
  var width: CGFloat
  var sideWidth: CGFloat { width < 760 ? 200 : 244 }
  var pad: CGFloat { width < 760 ? 22 : 40 }
  /// Title pages put the picture above the details, and episode rows drop their numbers.
  var narrow: Bool { width < 900 }
}

extension Color {
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255, opacity: opacity)
  }

  /// CSS hsl(): hue in degrees, saturation and lightness 0...1.
  init(hue: Double, saturation s: Double, lightness l: Double) {
    let c = (1 - abs(2 * l - 1)) * s
    let h = hue.truncatingRemainder(dividingBy: 360) / 60
    let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let (r, g, b): (Double, Double, Double) =
      switch Int(h) {
      case 0: (c, x, 0)
      case 1: (x, c, 0)
      case 2: (0, c, x)
      case 3: (0, x, c)
      case 4: (x, 0, c)
      default: (c, 0, x)
      }
    let m = l - c / 2
    self.init(.sRGB, red: r + m, green: g + m, blue: b + m, opacity: 1)
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

/// The hue for a name's placeholder picture (stable for the same name).
func hashHue(_ s: String) -> Double {
  var x: UInt32 = 0
  for scalar in s.unicodeScalars {
    x = x &* 31 &+ UInt32(scalar.utf16.first!)
  }
  return Double(x % 360)
}

// ---- Buttons ------------------------------------------------------------------------

enum ButtonKind {
  case accent, ghost
}

/// The pages' rounded buttons: accent (Play) or ghost; regular or small; text or icon only.
struct PillButtonStyle: ButtonStyle {
  var kind: ButtonKind = .ghost
  var small = false
  var iconOnly = false

  func makeBody(configuration: Configuration) -> some View {
    PillButtonBody(configuration: configuration, kind: kind, small: small, iconOnly: iconOnly)
  }
}

private struct PillButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let kind: ButtonKind
  let small: Bool
  let iconOnly: Bool
  @State private var hovering = false
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    let height: CGFloat = small ? 30 : 36
    configuration.label
      .font(.system(size: small ? 13 : 14, weight: .semibold))
      .labelStyle(PillLabelStyle(small: small))
      .lineLimit(1)
      .padding(.horizontal, iconOnly ? 0 : (small ? 12 : 16))
      .frame(width: iconOnly ? height : nil, height: height)
      .foregroundStyle(kind == .accent ? Theme.onAccent : Theme.text)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(fill(pressed: configuration.isPressed))
      )
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .opacity(enabled ? 1 : 0.5)
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.15), value: hovering)
  }

  private func fill(pressed: Bool) -> Color {
    let lit = enabled && (hovering || pressed)
    switch kind {
    case .accent: return lit ? Theme.accent2 : Theme.accent
    case .ghost: return Color.white.opacity(lit ? 0.14 : 0.08)
    }
  }
}

private struct PillLabelStyle: LabelStyle {
  let small: Bool
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 8) {
      configuration.icon.font(.system(size: small ? 13 : 15, weight: .semibold))
      configuration.title
    }
  }
}

/// Quiet text buttons ("Mark season watched", "Remove").
struct LinkButtonStyle: ButtonStyle {
  var size: CGFloat = 13
  var padding = EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)

  func makeBody(configuration: Configuration) -> some View {
    LinkButtonBody(configuration: configuration, size: size, padding: padding)
  }
}

private struct LinkButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let size: CGFloat
  let padding: EdgeInsets
  @State private var hovering = false
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    configuration.label
      .font(.system(size: size))
      .lineLimit(1)
      .foregroundStyle(hovering && enabled ? Theme.text : Theme.text2)
      .padding(padding)
      .background(RoundedRectangle(cornerRadius: 6).fill(hovering && enabled ? Theme.hover : .clear))
      .contentShape(Rectangle())
      .opacity(enabled ? 1 : 0.5)
      .onHover { hovering = $0 }
  }
}

/// A button without any chrome of its own (tiles, rows, sidebar items).
struct PlainTapStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.contentShape(Rectangle())
  }
}

// ---- Small pieces ---------------------------------------------------------------------

/// A thin progress line (Settings).
struct ProgressLine: View {
  var fraction: Double

  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.1))
        Rectangle().fill(Theme.accent)
          .frame(width: g.size.width * max(0, min(1, fraction.isFinite ? fraction : 0)))
          .animation(.easeOut(duration: 0.5), value: fraction)
      }
      .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    .frame(height: 5)
  }
}

/// The amber dot that pulses next to background activity.
struct PulsingDot: View {
  @State private var dim = false

  var body: some View {
    Circle().fill(Theme.accent).frame(width: 7, height: 7)
      .opacity(dim ? 0.25 : 1)
      .onAppear {
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
      }
  }
}

/// The loading ring.
struct Spinner: View {
  var size: CGFloat = 64
  var line: CGFloat = 5
  @State private var turn = false

  var body: some View {
    ZStack {
      Circle().stroke(Color.white.opacity(0.2), lineWidth: line)
      Circle().trim(from: 0, to: 0.25).stroke(Theme.accent, style: StrokeStyle(lineWidth: line, lineCap: .butt))
        .rotationEffect(.degrees(turn ? 360 : 0))
    }
    .frame(width: size - line, height: size - line)
    .onAppear {
      withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turn = true }
    }
  }
}

/// A text field drawn like the pages' inputs.
struct FieldBox<Content: View>: View {
  var dark = false
  @ViewBuilder var content: Content

  var body: some View {
    content
      .textFieldStyle(.plain)
      .font(.system(size: 13.5))
      .padding(.vertical, 7)
      .padding(.horizontal, 10)
      .background(RoundedRectangle(cornerRadius: dark ? 4 : 7).fill(dark ? Color(hex: 0x101010) : Color.black.opacity(0.25)))
      .overlay(
        RoundedRectangle(cornerRadius: dark ? 4 : 7)
          .strokeBorder(dark ? Color(hex: 0x444444) : Color.white.opacity(0.12), lineWidth: 1))
  }
}
