import AppKit
import SwiftUI

// The library's pages: Home, Shows, Movies, search results, and a page for each title.

/// A page's scrolling column, as wide as 1500 at most.
struct PageScroll<Content: View>: View {
  @Environment(\.metrics) private var m
  var maxWidth: CGFloat = 1500
  var bottom: CGFloat = 60
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) { content }
        .padding(EdgeInsets(top: 34, leading: m.pad, bottom: bottom, trailing: m.pad))
        .frame(maxWidth: maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct PageTitle: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 26, weight: .bold)).kerning(-0.26).padding(.bottom, 22)
  }
}

/// A section with a heading.
struct Block<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.system(size: 17, weight: .semibold))
      content
    }
    .padding(.bottom, 38)
  }
}

struct EmptyNote: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 14)).foregroundStyle(Theme.text2).padding(.vertical, 20)
  }
}

struct TitleGrid: View {
  let titles: [Title]

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMin), spacing: 18, alignment: .top)], alignment: .leading, spacing: 26) {
      ForEach(titles, id: \.id) { TitleTile(title: $0) }
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

// ---- Home ----------------------------------------------------------------------------------

struct Welcome<Action: View>: View {
  let title: String
  let text: String
  @ViewBuilder var action: Action

  var body: some View {
    VStack(spacing: 0) {
      Text(title).font(.system(size: 30, weight: .bold)).kerning(-0.3).multilineTextAlignment(.center).padding(.bottom, 10)
      Text(text).font(.system(size: 15)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
        .frame(maxWidth: 520).padding(.bottom, 24)
      action
    }
    .padding(60)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct HomePage: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win

  var body: some View {
    let lib = app.lib
    if lib.folders.isEmpty {
      Welcome(
        title: "Your films and shows, on your Mac",
        text:
          "Add the folders where your films and series live. Season folders become seasons, playback picks up where you stopped, and intros and end credits are found on this Mac so you can skip them."
      ) {
        Button { win.addFolder() } label: { Label("Add a folder", systemImage: "plus") }
          .buttonStyle(PillButtonStyle(kind: .accent))
      }
    } else if lib.titles.isEmpty {
      Welcome(
        title: lib.scanning ? "Looking through your folders…" : "No videos found yet",
        text: lib.scanning
          ? "This only takes a moment." : "None of your folders contain videos Nightcap recognises, or a drive is unplugged."
      ) {
        Button("Manage folders") { win.go(.settings) }.buttonStyle(PillButtonStyle())
      }
    } else {
      let watching = app.continueWatching()
      let recent = Array(lib.titles.stableSorted { numCompare($1.addedAt, $0.addedAt) }.prefix(12))
      PageScroll {
        if !watching.isEmpty {
          Block(title: "Watching") {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: Theme.gridWideMin), spacing: 18, alignment: .top)], alignment: .leading,
              spacing: 26
            ) {
              ForEach(watching) { WatchingTile(watching: $0) }
            }
          }
        }
        Block(title: watching.isEmpty ? "Your library" : "Recently added") { TitleGrid(titles: recent) }
      }
    }
  }
}

/// A title in a grid: its picture, with the name and details underneath.
struct TitleTile: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  let title: Title
  @State private var hovering = false

  var body: some View {
    Button { win.go(.title(title.id, season: nil)) } label: {
      VStack(alignment: .leading, spacing: 0) {
        ArtBox(.title(title.id, width: 480), seed: title.name)
          .shadow(color: .black.opacity(hovering ? 0.45 : 0.25), radius: hovering ? 13 : 7, y: hovering ? 10 : 4)
          .offset(y: hovering ? -2 : 0)
        VStack(alignment: .leading, spacing: 1) {
          Text(title.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
          Text(app.titleMeta(title)).font(.system(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(1)
        }
        .padding(EdgeInsets(top: 9, leading: 2, bottom: 0, trailing: 2))
      }
    }
    .buttonStyle(PlainTapStyle())
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.2), value: hovering)
    .help(title.name)
  }
}

/// Something you are watching: plays from where you stopped; resting on it previews it.
struct WatchingTile: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  let watching: Watching
  @State private var hovering = false
  @State private var previewing = false

  var body: some View {
    let t = watching.title
    let nu = watching.next
    let f = app.file(nu.fileId)
    let name = f?.name ?? ""
    let p = app.progress(nu.fileId)
    let left = nu.resume && (f?.duration ?? 0) != 0 ? "\(fmtDur((f?.duration ?? 0) - nu.start)) left" : "Up next"
    ZStack(alignment: .topTrailing) {
      Button { win.play(nu.fileId, at: nu.start) } label: {
        VStack(alignment: .leading, spacing: 0) {
          ArtBox(.file(nu.fileId, width: 640), seed: name, previewing: previewing ? nu.fileId : nil) {
            PlayHint(visible: hovering)
            if nu.resume, let p, p.duration != 0 { ProgressEdge(fraction: AppModel.fraction(p)) }
          }
          .shadow(color: .black.opacity(hovering ? 0.45 : 0.25), radius: hovering ? 13 : 7, y: hovering ? 10 : 4)
          .offset(y: hovering ? -2 : 0)
          VStack(alignment: .leading, spacing: 1) {
            Text(t.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text(t.isShow ? "\(app.epCode(nu.fileId)) · \(name)" : left)
              .font(.system(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(1)
            if t.isShow {
              Text(left).font(.system(size: 12.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
          }
          .padding(EdgeInsets(top: 9, leading: 2, bottom: 0, trailing: 2))
        }
      }
      .buttonStyle(PlainTapStyle())
      .help("\(nu.resume ? "Resume" : "Play") \(name)")

      Button {
        app.setHidden(app.engine.hide(t.id))
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .frame(width: 26, height: 26)
          .background(Circle().fill(Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255).opacity(0.75)))
          .foregroundStyle(Color(hex: 0xdddddd))
      }
      .buttonStyle(PlainTapStyle())
      .help("Remove from Watching")
      .padding(8)
      .offset(y: hovering ? -2 : 0)
      .opacity(hovering ? 1 : 0)
    }
    .hoverPreview(hovering: $hovering, previewing: $previewing)
    .animation(.easeOut(duration: 0.2), value: hovering)
  }
}

// ---- Shows, Movies, Search ---------------------------------------------------------------------

struct GridPage: View {
  @Environment(AppModel.self) private var app
  let shows: Bool

  var body: some View {
    let list = app.lib.titles.filter { $0.isShow == shows }.stableSorted(by: byName)
    PageScroll {
      PageTitle(text: shows ? "Shows" : "Movies")
      if list.isEmpty {
        EmptyNote(text: "No \(shows ? "shows" : "movies") yet.")
      } else {
        TitleGrid(titles: list)
      }
    }
  }
}

/// Lower case, without accents, for matching.
func searchNorm(_ s: String) -> String {
  let scalars = s.jsLowercased.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !(0x300...0x36F).contains($0.value) }
  return String(String.UnicodeScalarView(scalars))
}

struct SearchPage: View {
  @Environment(AppModel.self) private var app
  let query: String

  var body: some View {
    let n = searchNorm(query.jsTrimmed)
    let titles = app.lib.titles.filter { searchNorm($0.name).jsIncludes(n) }.stableSorted(by: byName)
    let eps = episodes(n)
    PageScroll {
      PageTitle(text: "“\(query.jsTrimmed)”")
      if !titles.isEmpty {
        Block(title: "Titles") { TitleGrid(titles: titles) }
      }
      if !eps.isEmpty {
        Block(title: "Episodes") {
          EpisodeList(fids: eps, showNames: true)
        }
      }
      if titles.isEmpty && eps.isEmpty {
        EmptyNote(text: "Nothing matches.")
      }
    }
  }

  /// Matching episodes of shows (not extras), the first 60 in the library's order.
  private func episodes(_ n: String) -> [String] {
    var out: [String] = []
    for fid in app.lib.fileOrder {
      if out.count >= 60 { break }
      guard let f = app.file(fid), let w = app.location(fid) else { continue }
      if w.title.isShow && !w.season.isExtras && searchNorm(f.name).jsIncludes(n) { out.append(fid) }
    }
    return out
  }
}

// ---- Episode lists -------------------------------------------------------------------------------

/// Episodes (or parts, or extras) in a list. `showNames` adds each one's show (search results);
/// `toggles` adds the watched switch (title pages).
struct EpisodeList: View {
  let fids: [String]
  var current: String? = nil
  var showNames = false
  var toggles = false
  @State private var hovered: String?

  var body: some View {
    LazyVStack(spacing: 0) {
      ForEach(Array(fids.enumerated()), id: \.element) { i, fid in
        let lit = { (id: String) in id == hovered || id == current }
        EpisodeRow(fid: fid, current: fid == current, showName: showNames, toggle: toggles, hovered: $hovered)
          .overlay(alignment: .top) {
            if i > 0 && !lit(fids[i - 1]) && !lit(fid) {
              Theme.line.frame(height: 1).padding(.horizontal, 10).allowsHitTesting(false)
            }
          }
          .id(fid)
      }
    }
  }
}

private struct EpisodeRow: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  @Environment(\.metrics) private var m
  let fid: String
  let current: Bool
  let showName: Bool
  let toggle: Bool
  @Binding var hovered: String?
  @State private var hovering = false
  @State private var previewing = false

  var body: some View {
    let f = app.file(fid)
    let name = f?.name ?? ""
    let p = app.progress(fid)
    let mk = app.markers(fid)
    let marks = [
      mk?.intro.map { "Intro \(fmtTime($0.start))–\(fmtTime($0.end))" },
      mk?.credits.map { "Credits \(fmtTime($0.start))" },
    ].compactMap { $0 }.joined(separator: " · ")
    HStack(spacing: 16) {
      if !showName && !m.narrow {
        Text(f?.number.map(String.init) ?? "")
          .font(.system(size: 15)).monospacedDigit()
          .foregroundStyle(current ? Theme.accent : Theme.text3)
          .frame(width: 30, alignment: .trailing)
      }
      ArtBox(.file(fid, width: 320), seed: name, radius: 6, previewing: previewing ? fid : nil) {
        PlayHint(visible: hovering, size: 32)
        if let p, p.duration != 0, p.watched || p.position > 5 { ProgressEdge(fraction: AppModel.fraction(p)) }
      }
      .frame(width: m.narrow ? 120 : 168)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(name).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
          Spacer(minLength: 0)
          Text(fmtDur(f?.duration ?? 0)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.text3).fixedSize()
        }
        if showName, let w = app.location(fid) {
          Text("\(w.title.name) · \(app.epCode(fid))").font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
        }
        if !marks.isEmpty {
          Text(marks).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if toggle {
        WatchToggle(on: p?.watched == true) {
          Task {
            app.setProgress(await app.engine.setWatched([fid], watched: p?.watched != true))
          }
        }
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(current ? Theme.accent.opacity(0.09) : hovering ? Theme.hover : .clear))
    .contentShape(Rectangle())
    .onTapGesture { win.play(fid) }
    .hoverPreview(hovering: $hovering, previewing: $previewing)
    .onChange(of: hovering) { _, h in
      if h { hovered = fid } else if hovered == fid { hovered = nil }
    }
  }
}

private struct WatchToggle: View {
  let on: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "checkmark")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(on ? Theme.onAccent : hovering ? Theme.text3 : .clear)
        .frame(width: 30, height: 30)
        .background(Circle().fill(on ? Theme.ok : .clear))
        .overlay(Circle().strokeBorder(on ? Theme.ok : hovering ? Theme.text2 : Color.white.opacity(0.18), lineWidth: 1.5))
    }
    .buttonStyle(PlainTapStyle())
    .onHover { hovering = $0 }
    .help(on ? "Mark unwatched" : "Mark watched")
  }
}

// ---- A title's page ---------------------------------------------------------------------------------

private struct RowFrameKey: PreferenceKey {
  static let defaultValue: CGRect? = nil
  static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = value ?? nextValue() }
}

/// A show or film: what to play next, then its seasons and episodes.
struct TitlePage: View {
  @Environment(AppModel.self) private var app
  let titleId: String
  let season: Int?

  var body: some View {
    if let t = app.titles[titleId], app.lib.titles.contains(where: { $0.id == titleId }) {
      TitleContent(t: t, seasonParam: season)
    } else {
      PageScroll { EmptyNote(text: "This title is no longer in your library.") }
    }
  }
}

private struct TitleContent: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  @Environment(\.metrics) private var m
  let t: Title
  let seasonParam: Int?
  @State private var currentRow: CGRect?
  @State private var viewport: CGFloat = 0

  var body: some View {
    let nu = app.nextUp(t)
    let seasonIdx =
      seasonParam.flatMap { $0 >= 0 && $0 < t.seasons.count ? $0 : nil } ?? max(0, app.location(nu.fileId)?.seasonIndex ?? 0)
    GeometryReader { outer in
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            TitleHead(t: t, nu: nu)
              .padding(.bottom, 30)
            TitleList(t: t, nu: nu, seasonIdx: seasonIdx)
          }
          .padding(EdgeInsets(top: 34, leading: m.pad, bottom: 60, trailing: m.pad))
          .frame(maxWidth: 1500, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: "titlePage")
        .onPreferenceChange(RowFrameKey.self) { currentRow = $0 }
        .task(id: t.id) {
          app.engine.prioritizeAnalysis(t.id)
          // Bring the episode up next into view when it is further down the list.
          guard seasonParam == nil else { return }
          try? await Task.sleep(nanoseconds: 200_000_000)
          if let row = currentRow, row.maxY > outer.size.height - 40 {
            withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(nu.fileId, anchor: .center) }
          }
        }
      }
    }
  }
}

private struct TitleHead: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  @Environment(\.metrics) private var m
  let t: Title
  let nu: NextUp
  @State private var hovering = false
  @State private var previewing = false

  var body: some View {
    let all = t.seasons.flatMap(\.episodes)
    let main = app.playOrder(t)
    let p = app.progress(nu.fileId)
    let watchedCount = main.filter { app.progress($0)?.watched == true }.count
    let allWatched = watchedCount == main.count
    let art = ArtBox(.file(nu.fileId, width: 640), seed: t.name, previewing: previewing ? nu.fileId : nil) {
      PlayHint(visible: hovering)
      if nu.resume, let p, p.duration != 0 { ProgressEdge(fraction: AppModel.fraction(p)) }
    }
    .shadow(color: .black.opacity(0.4), radius: 15, y: 10)
    .onTapGesture { win.play(nu.fileId, at: nu.start) }
    .hoverPreview(hovering: $hovering, previewing: $previewing)
    .help(app.nextUpLabel(t, nu))

    let info = VStack(alignment: .leading, spacing: 0) {
      Text(t.name).font(.system(size: 30, weight: .bold)).kerning(-0.45).lineSpacing(0).padding(.bottom, 6)
      Text(facts(main: main, watchedCount: watchedCount)).font(.system(size: 13.5)).foregroundStyle(Theme.text2).padding(.bottom, 12)
      if t.isShow && !nu.fresh {
        (Text(nu.resume ? "Watching" : "Up next").foregroundStyle(Theme.text3) + Text("  \(app.epCode(nu.fileId)) · \(app.file(nu.fileId)?.name ?? "")"))
          .font(.system(size: 14)).padding(.bottom, 14)
      }
      FlowLayout(spacing: 8) {
        Button { win.play(nu.fileId, at: nu.start) } label: { Label(app.nextUpLabel(t, nu), systemImage: "play.fill") }
          .buttonStyle(PillButtonStyle(kind: .accent))
        if nu.resume {
          Button("Start over") { win.play(nu.fileId, at: 0) }
            .buttonStyle(PillButtonStyle())
            .help("Start this one from the beginning")
        }
        Button {
          Task { app.setProgress(await app.engine.setWatched(main, watched: !allWatched)) }
        } label: {
          Label("Mark \(t.isShow ? "all " : "")\(allWatched ? "unwatched" : "watched")", systemImage: "checkmark")
        }
        .buttonStyle(PillButtonStyle())
        .help(allWatched ? "Mark everything unwatched" : "Mark everything watched")
        Button {
          _ = app.engine.reanalyze(t.id)
          app.refresh()
          win.toast("Detecting intros and credits again for this title")
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(PillButtonStyle(iconOnly: true))
        .help("Detect intros and credits again")
      }
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.ok)
        Text(detectNote(all: all)).font(.system(size: 12.5)).foregroundStyle(Theme.text3)
      }
      .padding(.top, 14)
    }

    if m.narrow {
      VStack(alignment: .leading, spacing: 30) {
        art.frame(maxWidth: 420)
        info
      }
    } else {
      let content = m.width - m.sideWidth - 2 * m.pad
      HStack(alignment: .center, spacing: 30) {
        art.frame(width: min(380, max(240, content * 0.42)))
        info.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func facts(main: [String], watchedCount: Int) -> String {
    let seasons = t.seasons.filter { !$0.isExtras }.count
    return [
      app.titleMeta(t), t.isShow && seasons > 1 ? "\(main.count) episodes" : nil,
      watchedCount > 0 ? (t.isShow ? "\(watchedCount) watched" : "Watched") : nil,
    ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private func detectNote(all: [String]) -> String {
    let detected = all.filter { app.markers($0)?.intro != nil }.count
    let credits = all.filter { app.markers($0)?.credits != nil }.count
    let analysable = t.seasons.filter { !$0.isExtras }.flatMap(\.episodes).count
    let working = app.status.analysis.current?.label.jsStartsWith(t.name) ?? false
    if t.isShow {
      return "Skip Intro ready for \(detected) of \(analysable) episodes · Next Episode at the credits for \(credits)\(working ? " · detecting now…" : "")"
    }
    return credits > 0
      ? "End credits found: it counts as watched once they start" : working ? "Looking for the end credits…" : "No end credits found yet"
  }
}

private struct TitleList: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  let t: Title
  let nu: NextUp
  let seasonIdx: Int

  var body: some View {
    let season = seasonIdx < t.seasons.count ? t.seasons[seasonIdx] : t.seasons[0]
    if !t.isShow && season.episodes.count == 1 && t.seasons.count == 1 {
      EmptyView()
    } else {
      let seasonWatched = season.episodes.allSatisfy { app.progress($0)?.watched == true }
      let what = season.isExtras ? "all" : "season"
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 16) {
          if t.seasons.count > 1 {
            SeasonTabs(t: t, selected: seasonIdx)
          } else {
            Text(t.isShow ? "Episodes" : "Parts").font(.system(size: 17, weight: .bold))
          }
          Spacer(minLength: 0)
          Button(seasonWatched ? "Mark \(what) unwatched" : "Mark \(what) watched") {
            Task { app.setProgress(await app.engine.setWatched(season.episodes, watched: !seasonWatched)) }
          }
          .buttonStyle(LinkButtonStyle())
          .fixedSize()
        }
        EpisodeList(fids: season.episodes, current: nu.fileId, toggles: true)
          .background(
            GeometryReader { g in
              Color.clear.preference(key: RowFrameKey.self, value: rowFrame(season, g.frame(in: .named("titlePage"))))
            })
      }
      .task(id: season.id) { app.engine.prioritizePreviews(season.episodes) }
    }
  }

  /// Where the episode up next is in the page (rows are about 115 points apart), for scrolling to it.
  private func rowFrame(_ season: Season, _ list: CGRect) -> CGRect? {
    guard let i = season.episodes.firstIndex(of: nu.fileId), !season.episodes.isEmpty else { return nil }
    let h = list.height / CGFloat(season.episodes.count)
    return CGRect(x: list.minX, y: list.minY + h * CGFloat(i), width: list.width, height: h)
  }
}

private struct SeasonTabs: View {
  @Environment(WindowModel.self) private var win
  let t: Title
  let selected: Int

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(Array(t.seasons.enumerated()), id: \.offset) { i, s in
            SeasonTab(name: s.name, on: i == selected) { win.setSeason(i) }.id(i)
          }
        }
        .padding(3)
      }
      .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
      .fixedSize(horizontal: false, vertical: true)
      .onAppear { proxy.scrollTo(selected) }
      .onChange(of: selected) { _, i in withAnimation { proxy.scrollTo(i) } }
      // The strip narrows when the button beside it grows ("Mark season unwatched"): keep the selected tab in view.
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in proxy.scrollTo(selected) }
    }
  }
}

private struct SeasonTab: View {
  let name: String
  let on: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Text(name)
        .font(.system(size: 13, weight: on ? .semibold : .regular))
        .foregroundStyle(on || hovering ? Theme.text : Theme.text2)
        .lineLimit(1)
        .fixedSize()
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .background(
          RoundedRectangle(cornerRadius: 7)
            .fill(on ? Color.white.opacity(0.13) : .clear)
            .shadow(color: on ? .black.opacity(0.3) : .clear, radius: 1, y: 1))
    }
    .buttonStyle(PlainTapStyle())
    .onHover { hovering = $0 }
  }
}
