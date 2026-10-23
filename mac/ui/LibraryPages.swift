import AppKit
import SwiftUI

// The library's pages: Home, Shows, Movies, search results, and a page for each title.

/// A page's scrolling column, as wide as 1500 at most.
struct PageScroll<Content: View>: View {
  @Environment(\.metrics) private var m
  var maxWidth: CGFloat = 1500
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) { content }
        .padding(EdgeInsets(top: 18, leading: m.pad, bottom: 48, trailing: m.pad))
        .frame(maxWidth: maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Theme.page)
  }
}

struct PageTitle: View {
  let text: String
  var body: some View {
    Text(text).font(.app(size: 30, weight: .bold)).lineLimit(1).padding(.bottom, 20)
  }
}

/// A section with a heading.
struct Block<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.app(.title2, weight: .bold))
      content
    }
    .padding(.bottom, 36)
  }
}

struct TitleGrid: View {
  let titles: [Title]

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMin), spacing: 20, alignment: .top)], alignment: .leading, spacing: 28) {
      ForEach(titles, id: \.id) { TitleTile(title: $0) }
    }
  }
}

/// A page with nothing to show yet.
private struct EmptyPage<Actions: View>: View {
  let title: String
  let symbol: String
  let text: String
  @ViewBuilder var actions: Actions

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: symbol)
    } description: {
      Text(text)
    } actions: {
      actions
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.page)
  }
}

// ---- Home ----------------------------------------------------------------------------------

struct HomePage: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win

  var body: some View {
    let lib = app.lib
    if lib.folders.isEmpty {
      EmptyPage(
        title: "Your films and shows, on your Mac", symbol: "play.rectangle.on.rectangle",
        text:
          "Add the folders where your films and series live. Season folders become seasons, playback picks up where you stopped, and intros and end credits are found on this Mac so you can skip them."
      ) {
        PrimaryButton { win.addFolder() } label: { Label("Add Folder…", systemImage: "plus") }
      }
    } else if lib.titles.isEmpty {
      EmptyPage(
        title: lib.scanning ? "Looking through your folders…" : "No videos found yet",
        symbol: lib.scanning ? "magnifyingglass" : "questionmark.folder",
        text: lib.scanning
          ? "This only takes a moment." : "None of your folders contain videos Nightcap recognises, or a drive is unplugged."
      ) {
        if !lib.scanning {
          Button("Manage Folders…") { win.openSettings(.library) }.glassButton()
        }
      }
    } else {
      let watching = app.continueWatching()
      let recent = Array(lib.titles.stableSorted { numCompare($1.addedAt, $0.addedAt) }.prefix(12))
      PageScroll {
        PageTitle(text: "Home")
        if !watching.isEmpty {
          Block(title: "Watching") {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: Theme.gridWideMin), spacing: 20, alignment: .top)], alignment: .leading,
              spacing: 28
            ) {
              ForEach(watching) { WatchingTile(watching: $0) }
            }
          }
        }
        Block(title: watching.isEmpty ? "Your Library" : "Recently Added") { TitleGrid(titles: recent) }
      }
    }
  }
}

/// A picture that lifts a little under the pointer.
private struct Lift: ViewModifier {
  let hovering: Bool

  func body(content: Content) -> some View {
    content
      .shadow(color: .black.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
      .scaleEffect(hovering ? 1.015 : 1)
      .animation(.easeOut(duration: 0.2), value: hovering)
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
        ArtBox(.title(title.id, width: 800))
          .modifier(Lift(hovering: hovering))
        VStack(alignment: .leading, spacing: 2) {
          Text(title.name).font(.app(.headline)).lineLimit(1)
          Text(app.titleMeta(title)).font(.app(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(EdgeInsets(top: 10, leading: 2, bottom: 0, trailing: 2))
      }
    }
    .buttonStyle(PlainTapStyle())
    .onHover { hovering = $0 }
    .help(title.name)
    .contextMenu {
      let nu = app.nextUp(title)
      Button(app.nextUpLabel(title, nu)) { win.play(nu.fileId, at: nu.start) }
      Button("Open") { win.go(.title(title.id, season: nil)) }
    }
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
    let remove = { app.setHidden(app.engine.hide(t.id)) }
    ZStack(alignment: .topTrailing) {
      Button { win.play(nu.fileId, at: nu.start) } label: {
        VStack(alignment: .leading, spacing: 0) {
          ArtBox(.file(nu.fileId, width: 800), previewing: previewing ? nu.fileId : nil) {
            PlayHint(visible: hovering)
            if nu.resume, let p, p.duration != 0 { ProgressEdge(fraction: AppModel.fraction(p)) }
          }
          .modifier(Lift(hovering: hovering))
          VStack(alignment: .leading, spacing: 2) {
            Text(t.name).font(.app(.headline)).lineLimit(1)
            Text(t.isShow ? "\(app.epCode(nu.fileId)) · \(name)" : left)
              .font(.app(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
            if t.isShow {
              Text(left).font(.app(.subheadline)).foregroundStyle(.tertiary).lineLimit(1)
            }
          }
          .padding(EdgeInsets(top: 10, leading: 2, bottom: 0, trailing: 2))
        }
      }
      .buttonStyle(PlainTapStyle())
      .help("\(nu.resume ? "Resume" : "Play") \(name)")
      .contextMenu {
        Button(nu.resume ? "Resume" : "Play") { win.play(nu.fileId, at: nu.start) }
        if nu.resume { Button("Play from Beginning") { win.play(nu.fileId, at: 0) } }
        Button("Open \(t.isShow ? "Show" : "Movie")") { win.go(.title(t.id, season: nil)) }
        Divider()
        Button("Remove from Watching", action: remove)
      }

      if hovering {
        Button(action: remove) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .bold))
            .frame(width: 26, height: 26)
            .foregroundStyle(.white)
            .glassEffect(.regular.tint(.black.opacity(0.25)), in: .circle)
        }
        .buttonStyle(PlainTapStyle())
        .help("Remove from Watching")
        .padding(8)
        .transition(.opacity)
      }
    }
    .hoverPreview(hovering: $hovering, previewing: $previewing)
    .animation(.easeOut(duration: 0.2), value: hovering)
  }
}

// ---- Shows, Movies, Search ---------------------------------------------------------------------

struct GridPage: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  let shows: Bool

  var body: some View {
    let list = app.lib.titles.filter { $0.isShow == shows }.stableSorted(by: byName)
    if list.isEmpty {
      EmptyPage(
        title: shows ? "No Shows Yet" : "No Movies Yet", symbol: shows ? "tv" : "film",
        text: shows
          ? "Shows appear here once a folder holding them is added. Each subfolder of a show becomes a season."
          : "Movies appear here once a folder holding them is added."
      ) {
        Button("Manage Folders…") { win.openSettings(.library) }.glassButton()
      }
    } else {
      PageScroll {
        PageTitle(text: shows ? "Shows" : "Movies")
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
    if titles.isEmpty && eps.isEmpty {
      ContentUnavailableView.search(text: query.jsTrimmed)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page)
    } else {
      PageScroll {
        PageTitle(text: "Results for “\(query.jsTrimmed)”")
        if !titles.isEmpty {
          Block(title: "Titles") { TitleGrid(titles: titles) }
        }
        if !eps.isEmpty {
          Block(title: "Episodes") {
            EpisodeList(fids: eps, showNames: true)
          }
        }
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
/// `toggles` adds the watched button (title pages).
struct EpisodeList: View {
  let fids: [String]
  var current: String? = nil
  var showNames = false
  var toggles = false

  var body: some View {
    LazyVStack(spacing: 4) {
      ForEach(fids, id: \.self) { fid in
        EpisodeRow(fid: fid, current: fid == current, showName: showNames, toggle: toggles)
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
    let watched = p?.watched == true
    let setWatched = { (on: Bool) -> Void in
      Task { app.setProgress(await app.engine.setWatched([fid], watched: on)) }
    }
    HStack(spacing: 16) {
      if !showName && !m.narrow {
        Text(f?.number.map(String.init) ?? "")
          .font(.app(.title3)).monospacedDigit()
          .foregroundStyle(current ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
          .frame(width: 30, alignment: .trailing)
      }
      ArtBox(.file(fid, width: 480), radius: 8, previewing: previewing ? fid : nil) {
        PlayHint(visible: hovering, size: 34)
        if let p, p.duration != 0, p.watched || p.position > 5 { ProgressEdge(fraction: AppModel.fraction(p)) }
      }
      .frame(width: m.narrow ? 128 : 176)
      VStack(alignment: .leading, spacing: 3) {
        Text(name).font(.app(.headline)).lineLimit(2)
        if showName, let w = app.location(fid) {
          Text("\(w.title.name) · \(app.epCode(fid))").font(.app(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
        }
        if !marks.isEmpty {
          Text(marks).font(.app(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(fmtDur(f?.duration ?? 0)).font(.app(.subheadline)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
      if toggle {
        WatchToggle(on: watched) { setWatched(!watched) }
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 14)
        .fill(current ? Theme.accent.opacity(0.13) : hovering ? Theme.hover : .clear))
    .contentShape(RoundedRectangle(cornerRadius: 14))
    .onTapGesture { win.play(fid) }
    .hoverPreview(hovering: $hovering, previewing: $previewing)
    .contextMenu {
      Button("Play") { win.play(fid) }
      Button("Play from Beginning") { win.play(fid, at: 0) }
      Divider()
      Button(watched ? "Mark as Unwatched" : "Mark as Watched") { setWatched(!watched) }
    }
  }
}

private struct WatchToggle: View {
  let on: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: on ? "checkmark.circle.fill" : hovering ? "checkmark.circle" : "circle")
        .font(.system(size: 22, weight: .regular))
        .foregroundStyle(on ? AnyShapeStyle(Theme.accent) : hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }
    .buttonStyle(PlainTapStyle())
    .onHover { hovering = $0 }
    .help(on ? "Mark as unwatched" : "Mark as watched")
  }
}

// ---- A title's page ---------------------------------------------------------------------------------

private struct RowFrameKey: PreferenceKey {
  static let defaultValue: CGRect? = nil
  static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = value ?? nextValue() }
}

/// A show or film: its picture with what to play next, then its seasons and episodes.
struct TitlePage: View {
  @Environment(AppModel.self) private var app
  let titleId: String
  let season: Int?

  var body: some View {
    if let t = app.titles[titleId], app.lib.titles.contains(where: { $0.id == titleId }) {
      TitleContent(t: t, seasonParam: season)
    } else {
      ContentUnavailableView("Not in Your Library", systemImage: "questionmark.folder", description: Text("This title is no longer in your library."))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page)
    }
  }
}

private struct TitleContent: View {
  @Environment(AppModel.self) private var app
  @Environment(\.metrics) private var m
  let t: Title
  let seasonParam: Int?
  @State private var currentRow: CGRect?

  var body: some View {
    let nu = app.nextUp(t)
    let seasonIdx =
      seasonParam.flatMap { $0 >= 0 && $0 < t.seasons.count ? $0 : nil } ?? max(0, app.location(nu.fileId)?.seasonIndex ?? 0)
    GeometryReader { outer in
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            TitleHero(t: t, nu: nu, height: heroHeight(outer.size))
            VStack(alignment: .leading, spacing: 0) {
              if isSingleFilm {
                FilmDetails(t: t, fid: nu.fileId)
              } else {
                TitleList(t: t, nu: nu, seasonIdx: seasonIdx)
              }
            }
            .padding(EdgeInsets(top: 8, leading: m.pad - 10, bottom: 48, trailing: m.pad - 10))
            .frame(maxWidth: 1500, alignment: .leading)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.page)
        .ignoresSafeArea(edges: .top)
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

  private var isSingleFilm: Bool { !t.isShow && t.seasons.count == 1 && t.seasons[0].episodes.count == 1 }

  /// The picture's height: about half the window, more on a wide one.
  private func heroHeight(_ size: CGSize) -> CGFloat {
    max(340, min(560, size.width * 0.42, size.height * 0.62))
  }
}

/// The title's picture across the top of the page (and under the sidebar),
/// with its name, what plays next and the buttons over its lower part.
private struct TitleHero: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  @Environment(\.metrics) private var m
  let t: Title
  let nu: NextUp
  let height: CGFloat

  var body: some View {
    let main = app.playOrder(t)
    let watchedCount = main.filter { app.progress($0)?.watched == true }.count
    let allWatched = watchedCount == main.count
    ZStack(alignment: .bottomLeading) {
      ArtBox(.title(t.id, type: "backdrop", width: 1280), radius: 0, fill: true)
        .frame(height: height)
        .overlay {
          LinearGradient(
            stops: [
              .init(color: Theme.page.opacity(0), location: 0.28),
              .init(color: Theme.page.opacity(0.55), location: 0.62),
              .init(color: Theme.page, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .backgroundExtensionEffect()
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 0) {
        Text(t.name)
          .font(.app(size: m.narrow ? 32 : 42, weight: .bold))
          .lineLimit(2)
          .minimumScaleFactor(0.7)
          .padding(.bottom, 6)
        Text(facts(main: main, watchedCount: watchedCount))
          .font(.app(.title3)).foregroundStyle(.secondary).lineLimit(1)
          .padding(.bottom, 16)
        HStack(spacing: 10) {
          PrimaryButton { win.play(nu.fileId, at: nu.start) } label: {
            Label(app.nextUpLabel(t, nu), systemImage: "play.fill").padding(.horizontal, 4)
          }
          .help(t.isShow ? "\(app.epCode(nu.fileId)) · \(app.file(nu.fileId)?.name ?? "")" : "")
          if nu.resume {
            Button("Start Over") { win.play(nu.fileId, at: 0) }
              .glassButton()
              .help("Start this one from the beginning")
          }
          Menu {
            Button(allWatched ? "Mark All as Unwatched" : "Mark All as Watched") {
              Task { app.setProgress(await app.engine.setWatched(main, watched: !allWatched)) }
            }
            Button("Detect Intros and Credits Again") {
              _ = app.engine.reanalyze(t.id)
              app.refresh()
              win.toast("Detecting intros and credits again for this title")
            }
          } label: {
            Image(systemName: "ellipsis")
          }
          .menuIndicator(.hidden)
          .glassButton()
          .buttonBorderShape(.circle)
          .fixedSize()
          .help("More")
        }
        DetectNote(t: t)
          .padding(.top, 14)
      }
      .padding(.horizontal, m.pad)
      .padding(.bottom, 22)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func facts(main: [String], watchedCount: Int) -> String {
    let seasons = t.seasons.filter { !$0.isExtras }.count
    let upNext = t.isShow && !nu.fresh ? "\(nu.resume ? "Watching" : "Up next") \(app.epCode(nu.fileId)) · \(app.file(nu.fileId)?.name ?? "")" : nil
    return [
      app.titleMeta(t), t.isShow && seasons > 1 ? "\(main.count) episodes" : nil,
      upNext ?? (watchedCount > 0 ? (t.isShow ? "\(watchedCount) watched" : "Watched") : nil),
    ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

/// What detection found for a title.
private struct DetectNote: View {
  @Environment(AppModel.self) private var app
  let t: Title

  var body: some View {
    let all = t.seasons.flatMap(\.episodes)
    let detected = all.filter { app.markers($0)?.intro != nil }.count
    let credits = all.filter { app.markers($0)?.credits != nil }.count
    let analysable = t.seasons.filter { !$0.isExtras }.flatMap(\.episodes).count
    let working = app.status.analysis.current?.label.jsStartsWith(t.name) ?? false
    let text =
      t.isShow
      ? "Skip Intro ready for \(detected) of \(analysable) episodes · Next Episode at the credits for \(credits)\(working ? " · detecting now…" : "")"
      : credits > 0
        ? "End credits found: it counts as watched once they start" : working ? "Looking for the end credits…" : "No end credits found yet"
    Label(text, systemImage: working ? "waveform" : "checkmark.seal")
      .font(.app(.callout))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .help(text)
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
    let seasonWatched = season.episodes.allSatisfy { app.progress($0)?.watched == true }
    let what = season.isExtras ? "All" : "Season"
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 16) {
        if t.seasons.count > 1 {
          SeasonMenu(t: t, selected: seasonIdx)
        } else {
          Text(t.isShow ? "Episodes" : "Parts").font(.app(.title2, weight: .bold))
        }
        Spacer(minLength: 0)
        Button(seasonWatched ? "Mark \(what) as Unwatched" : "Mark \(what) as Watched") {
          Task { app.setProgress(await app.engine.setWatched(season.episodes, watched: !seasonWatched)) }
        }
        .buttonStyle(QuietButtonStyle())
        .fixedSize()
      }
      .padding(.horizontal, 10)
      EpisodeList(fids: season.episodes, current: nu.fileId, toggles: true)
        .background(
          GeometryReader { g in
            Color.clear.preference(key: RowFrameKey.self, value: rowFrame(season, g.frame(in: .named("titlePage"))))
          })
    }
    .task(id: season.id) { app.engine.prioritizePreviews(season.episodes) }
  }

  /// Where the episode up next is in the page, for scrolling to it.
  private func rowFrame(_ season: Season, _ list: CGRect) -> CGRect? {
    guard let i = season.episodes.firstIndex(of: nu.fileId), !season.episodes.isEmpty else { return nil }
    let h = list.height / CGFloat(season.episodes.count)
    return CGRect(x: list.minX, y: list.minY + h * CGFloat(i), width: list.width, height: h)
  }
}

/// The season shown: its name as a heading, which opens the list of seasons.
private struct SeasonMenu: View {
  @Environment(WindowModel.self) private var win
  let t: Title
  let selected: Int

  var body: some View {
    Menu {
      Picker("Season", selection: Binding(get: { selected }, set: { win.setSeason($0) })) {
        ForEach(Array(t.seasons.enumerated()), id: \.offset) { i, s in Text(s.name).tag(i) }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      HStack(spacing: 6) {
        Text(t.seasons[selected].name).font(.app(.title2, weight: .bold))
        Image(systemName: "chevron.down").font(.callout.weight(.bold)).foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Choose a season")
  }
}

/// A film in one part: moments from it to start from.
private struct FilmDetails: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  let t: Title
  let fid: String
  @State private var moments: [Double] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if !moments.isEmpty {
        Text("Scenes").font(.app(.title2, weight: .bold)).padding(.horizontal, 10)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 20, alignment: .top)], alignment: .leading, spacing: 22) {
          ForEach(moments, id: \.self) { time in
            SceneTile(fid: fid, time: time) { win.play(fid, at: time) }
          }
        }
        .padding(.horizontal, 10)
      }
    }
    .task(id: fid) {
      app.engine.prioritizePreviews([fid])
      // The previews may still be being made: look again for a while.
      for _ in 0..<40 {
        let found = (try? await app.engine.sceneTimes(fid, count: 8)) ?? []
        if Task.isCancelled { return }
        if !found.isEmpty {
          withAnimation(.easeOut(duration: 0.3)) { moments = found }
          return
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if Task.isCancelled { return }
      }
    }
  }
}

private struct SceneTile: View {
  let fid: String
  let time: Double
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 6) {
        ArtBox(.moment(fid, at: time, width: 800)) {
          PlayHint(visible: hovering, size: 38)
        }
        .modifier(Lift(hovering: hovering))
        Text(fmtTime(time)).font(.app(.subheadline)).monospacedDigit().foregroundStyle(.secondary)
          .padding(.horizontal, 2)
      }
    }
    .buttonStyle(PlainTapStyle())
    .onHover { hovering = $0 }
    .help("Play from \(fmtTime(time))")
  }
}
