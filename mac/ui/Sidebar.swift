import AppKit
import SwiftUI

// The sidebar: the name, search, Home, what you're watching, shows and
// films, background activity, and Settings.
struct Sidebar: View {
  @Environment(AppModel.self) private var app
  @Environment(WindowModel.self) private var win
  var topInset: CGFloat
  var searchFocused: FocusState<Bool>.Binding

  var body: some View {
    let lib = app.lib
    let watching = lib.folders.isEmpty ? [] : app.continueWatching()
    let shows = lib.titles.filter(\.isShow).stableSorted(by: byName)
    let movies = lib.titles.filter { !$0.isShow }.stableSorted(by: byName)
    let key = win.route.key

    VStack(alignment: .leading, spacing: 0) {
      Button { win.go(.home) } label: {
        HStack(spacing: 10) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6))
          Text("Nightcap").font(.system(size: 17, weight: .bold)).kerning(-0.17)
        }
        .padding(EdgeInsets(top: 10, leading: 20, bottom: 14, trailing: 20))
      }
      .buttonStyle(PlainTapStyle())
      .padding(.top, topInset)

      SearchField(searchFocused: searchFocused)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          SideItem(label: "Home", icon: "house.fill", active: key == "home") { win.go(.home) }
          if !watching.isEmpty {
            SideGroup(label: "Watching", route: nil) {
              ForEach(watching) { w in
                titleItem(w.title, note: w.title.isShow ? app.epCode(w.next.fileId) : nil, key: key)
              }
            }
          }
          if !shows.isEmpty {
            SideGroup(label: "Shows", route: .shows) {
              ForEach(shows, id: \.id) { titleItem($0, note: nil, key: key) }
            }
          }
          if !movies.isEmpty {
            SideGroup(label: "Movies", route: .movies) {
              ForEach(movies, id: \.id) { titleItem($0, note: nil, key: key) }
            }
          }
        }
        .padding(EdgeInsets(top: 4, leading: 10, bottom: 12, trailing: 10))
      }
      .scrollIndicators(.automatic)

      VStack(alignment: .leading, spacing: 0) {
        if let text = activity {
          HStack(spacing: 8) {
            PulsingDot()
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
          }
          .padding(EdgeInsets(top: 4, leading: 10, bottom: 8, trailing: 10))
        }
        SideItem(label: "Settings", icon: "gearshape.fill", active: key == "settings") { win.go(.settings) }
      }
      .padding(EdgeInsets(top: 8, leading: 10, bottom: 14, trailing: 10))
      .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Theme.side)
    .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
  }

  private func titleItem(_ t: Title, note: String?, key: String) -> some View {
    SideItem(label: t.name, thumb: .title(t.id, width: 120), seed: t.name, note: note, active: key == "title:\(t.id)") {
      win.go(.title(t.id, season: nil))
    }
  }

  /// What runs in the background, if anything.
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

private struct SideGroup<Items: View>: View {
  @Environment(WindowModel.self) private var win
  let label: String
  let route: Route?
  @ViewBuilder var items: Items
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      let head = Text(label.uppercased())
        .font(.system(size: 11, weight: .bold))
        .kerning(0.66)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let route {
        let active = win.route.key == route.key
        Button { win.go(route) } label: {
          head.foregroundStyle(active ? Theme.accent : hovering ? Theme.text2 : Theme.text3)
        }
        .buttonStyle(PlainTapStyle())
        .onHover { hovering = $0 }
      } else {
        head.foregroundStyle(Theme.text3)
      }
      items
    }
    .padding(.top, 16)
  }
}

private struct SideItem: View {
  let label: String
  var icon: String? = nil
  var thumb: ArtSource? = nil
  var seed = ""
  var note: String? = nil
  var active = false
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        if let icon {
          Image(systemName: icon)
            .font(.system(size: 14))
            .frame(width: 18, height: 18)
            .foregroundStyle(active ? Theme.accent : Theme.text2)
        } else if let thumb {
          ArtBox(thumb, seed: seed, radius: 4).frame(width: 36, height: 21)
        }
        Text(label)
          .font(.system(size: 13.5))
          .foregroundStyle(Theme.text)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let note {
          Text(note).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Theme.text3).lineLimit(1).fixedSize()
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .frame(minHeight: 32)
      .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.sel : hovering ? Theme.hover : .clear))
    }
    .buttonStyle(PlainTapStyle())
    .onHover { hovering = $0 }
    .help(label)
  }
}

/// Search titles and episodes ("/" to start, Esc to leave).
private struct SearchField: View {
  @Environment(WindowModel.self) private var win
  var searchFocused: FocusState<Bool>.Binding

  var body: some View {
    let text = Binding(get: { win.searchText }, set: { win.typeSearch($0) })
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.text2)
      TextField("Search", text: text)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .focused(searchFocused)
        .onExitCommand { win.leaveSearch() }
        .accessibilityLabel("Search titles and episodes")
      if !win.searchText.isEmpty {
        Button { win.typeSearch("") } label: {
          Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
        .buttonStyle(PlainTapStyle())
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(searchFocused.wrappedValue ? 0.09 : 0.07)))
    .overlay(
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(searchFocused.wrappedValue ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1))
    .contentShape(Rectangle())
    .onTapGesture { searchFocused.wrappedValue = true }
  }
}
