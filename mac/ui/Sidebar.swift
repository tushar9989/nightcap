import AppKit
import SwiftUI

/// What the sidebar can select.
enum SideItem: Hashable {
  case home, shows, movies
  /// A title, in list 0 (Watching) or 1 (Shows or Movies).
  case title(String, list: Int)
}

// The sidebar: Home, Shows and Movies, then what you're watching and every
// show and film, and what runs in the background at the bottom.
struct Sidebar: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  @AppStorage("sidebar.watching") private var watchingOpen = true
  @AppStorage("sidebar.shows") private var showsOpen = true
  @AppStorage("sidebar.movies") private var moviesOpen = true

  var body: some View {
    let lib = app.lib
    let watching = lib.folders.isEmpty ? [] : app.continueWatching()
    let shows = lib.titles.filter(\.isShow).stableSorted(by: byName)
    let movies = lib.titles.filter { !$0.isShow }.stableSorted(by: byName)
    let selection = Binding<SideItem?>(
      get: { pick(watching) },
      set: { item in if let item { choose(item) } })
    List(selection: selection) {
      Label("Home", systemImage: "house").tag(SideItem.home)
      Label("Shows", systemImage: "tv").tag(SideItem.shows)
      Label("Movies", systemImage: "film").tag(SideItem.movies)
      if !watching.isEmpty {
        Section("Watching", isExpanded: $watchingOpen) {
          ForEach(watching) { w in
            TitleRow(title: w.title, note: w.title.isShow ? app.epCode(w.next.fileId) : nil, watching: w)
              .tag(SideItem.title(w.title.id, list: 0))
          }
        }
      }
      if !shows.isEmpty {
        Section("Shows", isExpanded: $showsOpen) {
          ForEach(shows, id: \.id) { TitleRow(title: $0).tag(SideItem.title($0.id, list: 1)) }
        }
      }
      if !movies.isEmpty {
        Section("Movies", isExpanded: $moviesOpen) {
          ForEach(movies, id: \.id) { TitleRow(title: $0).tag(SideItem.title($0.id, list: 1)) }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) { ActivityStatus() }
  }

  /// The row the page belongs to: the one clicked when a title is in two lists.
  private func pick(_ watching: [Watching]) -> SideItem? {
    switch win.route {
    case .home: return .home
    case .shows: return .shows
    case .movies: return .movies
    case .search: return nil
    case .title(let id, _):
      if win.sideList == 0 && watching.contains(where: { $0.title.id == id }) { return .title(id, list: 0) }
      return .title(id, list: 1)
    }
  }

  private func choose(_ item: SideItem) {
    switch item {
    case .home: win.go(.home)
    case .shows: win.go(.shows)
    case .movies: win.go(.movies)
    case .title(let id, let list):
      win.go(.title(id, season: nil))
      win.sideList = list
    }
  }
}

/// A show or film: a small picture, its name, and (Watching) the episode up next.
private struct TitleRow: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  let title: Title
  var note: String? = nil
  var watching: Watching? = nil

  var body: some View {
    Label {
      Text(title.name).lineLimit(1).truncationMode(.tail)
    } icon: {
      ArtBox(.title(title.id, width: 320), radius: 3)
        .frame(width: 30)
    }
    .badge(note.map { Text($0).monospacedDigit() })
    .help(title.name)
    .contextMenu {
      let nu = watching?.next ?? app.nextUp(title)
      Button(app.nextUpLabel(title, nu)) { win.play(nu.fileId, at: nu.start) }
      if watching != nil {
        Button("Remove from Watching") { app.setHidden(app.engine.hide(title.id)) }
      }
    }
  }
}

/// What runs in the background, if anything.
private struct ActivityStatus: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    if let text = activity {
      HStack(spacing: 8) {
        ProgressView().controlSize(.mini)
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(text)
    }
  }

  private var activity: String? {
    let st = app.status
    if st.scanning { return "Scanning…" }
    if st.analysis.current != nil && st.analysis.enabled {
      return "Detecting intros · \(st.analysis.analyzedFiles)/\(st.analysis.totalFiles)"
    }
    if st.previews.current != nil && st.previews.enabled {
      return "Making previews · \(st.previews.done)/\(st.previews.total)"
    }
    return nil
  }
}
