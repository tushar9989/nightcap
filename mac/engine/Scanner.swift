import Foundation

// Walks library folders and turns them into shows (with seasons and
// episodes) and movies.
//
// Library folder kinds:
//   auto   - decide per folder: season-like subfolders or episode-numbered
//            files make a show, a folder with one video is a movie
//   shows  - every top-level subfolder is a show, its subfolders are seasons
//   movies - every video file is a movie
// A library folder that is itself a show (it contains "Season 1", "Season 2"
// …) is detected as one show in any mode except movies.

enum Scanner {
  static let videoExt: Set<String> = [".mp4", ".m4v", ".mkv", ".webm", ".mov", ".avi", ".wmv", ".flv", ".mpg", ".mpeg", ".ts", ".m2ts", ".mts", ".3gp", ".ogv", ".vob", ".divx"]
  static let subExt: Set<String> = [".srt", ".vtt", ".ass", ".ssa"]
  static let imgExt: Set<String> = [".jpg", ".jpeg", ".png", ".webp"]
  static let skipDirs = Re(#"^(\$recycle\.bin|system volume information|lost\+found|@eadir|#recycle|\.?trash.*)$"#, "i")
  static let extraDirs = Re(#"^(extras?|featurettes?|behind[ ._\-]the[ ._\-]scenes|deleted[ ._\-]scenes|interviews?|trailers?|samples?|shorts|bonus( features)?)$"#, "i")
  static let subDirs = Re(#"^(subs?|subtitles?)$"#, "i")
  static let partRe = Re(#"(?:^|[\s._\-])(?:cd|disc|disk|part|pt)[\s._\-]*([0-9]{1,2})(?:$|[\s._\-])"#, "i")
  static let maxDepth = 8

  static let tagRe = Re(#"(?:^|[\s.\-_(\[])(?:2160p|1080[pi]|720p|576p|480p|4k|uhd|hdr10\+?|hdr|dv|dovi|blu-?ray|bdrip|brrip|bdremux|remux|web-?dl|web-?rip|webrip|web|hdtv|dvdrip|dvd|hdrip|xvid|divx|x264|x265|h\.?26[45]|hevc|avc|aac(?:2\.0)?|ac3|e-?ac-?3|dts(?:-hd)?|truehd|atmos|dd\+?5\.1|ddp?5\.1|10bit|8bit|proper|repack|extended|unrated|imax|multi|dual[\s.\-]?audio|amzn|nf|hulu|dsnp|hmax|atvp)(?=$|[\s.\-_)\]])"#, "i")

  static func stemOf(_ name: String) -> String { name.jsSlice(0, name.jsLength - extname(name).jsLength) }

  private static let spaceRe = Re(#"\s"#)
  private static let bracketsRe = Re(#"\[[^\]]*\]|\{[^}]*\}"#)
  private static let dotsRe = Re("[._]+")
  private static let underscoresRe = Re("_+")
  private static let emptyParensRe = Re(#"\(\s*\)"#)
  private static let spacesRe = Re(#"\s+"#)
  private static let edgePunctRe = Re(#"^[\s\-–—:.,(]+|[\s\-–—:.,(]+$"#)

  /// dots: treat dots as word separators (release-style names like "Mr.Robot.S01E01").
  static func cleanTitle(_ raw: String, dots: Bool? = nil) -> String {
    let dots = dots ?? !spaceRe.test(raw.jsTrimmed)
    var s = bracketsRe.replace(raw, " ")
    s = dots ? dotsRe.replace(s, " ") : underscoresRe.replace(s, " ")
    let tag = tagRe.search(s)
    if tag > 0 { s = s.jsSlice(0, tag) }
    s = spacesRe.replace(emptyParensRe.replace(s, " "), " ")
    return edgePunctRe.replace(s, "").jsTrimmed
  }

  private static let parenYearRe = Re(#"^(.+?)\s*\(((?:19|20)[0-9]{2})\)"#)
  private static let trailingYearRe = Re(#"^(.+?)\s+((?:19|20)[0-9]{2})$"#)

  /// "Inception (2010)" -> ("Inception", 2010)
  static func parseTitle(_ raw: String) -> (name: String, year: Int?) {
    var s = cleanTitle(raw)
    var year: Int?
    if let paren = parenYearRe.match(s) {
      s = paren[1]!
      year = Int(paren[2]!)
    } else if let m = trailingYearRe.match(s) {
      s = m[1]!
      year = Int(m[2]!)
    }
    let t = s.jsTrimmed
    if !t.isEmpty { return (t, year) }
    let c = cleanTitle(raw)
    return (c.isEmpty ? raw : c, year)
  }

  struct Episode: Equatable {
    var season: Int?
    var episode: Int?
    var title: String
    /// The name itself says it is an episode (S01E02, 1x02, Episode 2, " - 02 ")
    /// rather than just starting with a number.
    var strong: Bool
  }

  private static let episodePatterns: [(Re, Bool)] = [
    // (pattern, has a season group)
    (Re(#"(?:^|[^a-z0-9])season[\s._\-]*([0-9]{1,2})[\s._,\-]*episode[\s._\-]*([0-9]{1,3})(?:\s*(?:\&|\+|and)\s*([0-9]{1,3}))?(?![0-9])"#, "i"), true),
    (Re(#"(?:^|[^a-z0-9])s([0-9]{1,2})[\s._\-]*e([0-9]{1,3})(?:-?e([0-9]{1,3}))?"#, "i"), true),
    (Re(#"(?:^|[^a-z0-9])([0-9]{1,2})x([0-9]{2,3})(?![0-9p])"#, "i"), true),
    (Re(#"(?:^|[^a-z0-9])(?:episode|ep|e)[\s._\-]*([0-9]{1,3})(?:\s*(?:\&|\+|and|-)\s*(?:e|ep)?([0-9]{1,3}))?(?![0-9])"#, "i"), false),
    (Re(#"\s-\s([0-9]{1,3})(?:v[0-9])?(?=$|\s|\[|\()"#, "i"), false),
  ]
  private static let leadSepRe = Re(#"^[\s._\-]+"#)
  private static let leadNumberRe = Re(#"^([0-9]{1,3})(?![0-9])(?:[\s._\-]+(.*))?$"#)

  /// Episode numbering from a file name.
  static func parseEpisode(_ stem: String) -> Episode {
    let dots = !spaceRe.test(stem)
    for (re, hasSeason) in episodePatterns {
      guard let m = re.match(stem) else { continue }
      let season = hasSeason ? Int(m[1]!) : nil
      let episode = Int(m[hasSeason ? 2 : 1]!)
      let rest = stem.jsSlice(m.end)
      return Episode(season: season, episode: episode, title: cleanTitle(leadSepRe.replace(rest, "", global: false), dots: dots), strong: true)
    }
    if let lead = leadNumberRe.match(stem) {
      return Episode(season: nil, episode: Int(lead[1]!), title: cleanTitle(lead[2] ?? "", dots: dots), strong: false)
    }
    return Episode(season: nil, episode: nil, title: cleanTitle(stem), strong: false)
  }

  private static let seasonWord = "(?:season|series|saison|staffel|temporada|stagione)"
  /// "Season 1, 2 & 3", "Seasons 1-9", "S01-S05", "Complete": a whole-show pack, not one season.
  private static let multiSeason = Re("\(seasonWord)s?[\\s._\\-]*[0-9]{1,3}\\s*(?:[,\\&+]|-|and|to)\\s*[0-9]|(?:^|[\\s._\\-])s[0-9]{1,2}\\s*-\\s*s?[0-9]{1,2}(?![0-9])|(?:^|[\\s._\\-])complete(?:$|[\\s._\\-])", "i")
  private static let specialsRe = Re("^specials?$", "i")
  private static let seasonWordRe = Re("(?:^|[\\s._\\-])\(seasonWord)[\\s._\\-]*([0-9]{1,3})(?![0-9])", "i")
  private static let seasonSRe = Re(#"(?:^|[\s._\-])s([0-9]{1,2})(?=$|[\s._\-])"#, "i")
  private static let bareNumberRe = Re("^([0-9]{1,2})$")

  static func seasonNumber(_ name: String) -> Int? {
    if specialsRe.test(name.jsTrimmed) { return 0 }
    if multiSeason.test(name) { return nil }
    if let m = seasonWordRe.match(name) { return Int(m[1]!) }
    if let m = seasonSRe.match(name) { return Int(m[1]!) }
    if let m = bareNumberRe.match(name.jsTrimmed) { return Int(m[1]!) }
    return nil
  }

  private static let seasonOwnerRe = Re("^(.*?)(?:^|[\\s._\\-])(?:\(seasonWord)[\\s._\\-]*[0-9]|s[0-9]{1,2}(?=$|[\\s._\\-]))", "i")

  /// The show a season folder names, if any: "Breaking.Bad.S01.720p" -> "breaking bad",
  /// "Season 01" -> "" (a bare season label).
  private static func seasonOwner(_ name: String) -> String {
    guard let m = seasonOwnerRe.match(name) else { return normName("") }
    let lead = m[1] ?? ""
    return normName(parseTitle(lead.isEmpty ? " " : lead).name)
  }

  private static let yearParensRe = Re(#"\([0-9]{4}\)"#)
  private static let nonAlnumRe = Re("[^a-z0-9]+")

  static func normName(_ s: String) -> String {
    nonAlnumRe.replace(yearParensRe.replace(s.jsLowercased, ""), " ").jsTrimmed
  }

  /// Is `dir` a season of the show folder `parent`? Bare labels always are;
  /// "Show.S01" release folders only when the show name matches the parent.
  private static func isSeasonOf(_ dir: DirNode, _ parent: DirNode) -> Bool {
    if seasonNumber(dir.name) == nil { return false }
    if dir.dirs.contains(where: { seasonNumber($0.name) != nil }) { return false }
    let owner = seasonOwner(dir.name)
    if owner.isEmpty || owner == "the" { return true }
    let parentName = normName(showSuffix.replace(parseTitle(parent.name).name, "", global: false))
    return parentName.jsIncludes(owner) || owner.jsIncludes(parentName)
  }

  // ---- Walking the folders ------------------------------------------------------------

  final class DirNode {
    let name: String
    let path: String
    var videos: [Video] = []
    var subs: [String] = []
    var images: [String] = []
    var dirs: [DirNode] = []
    var total = 0

    init(path: String) {
      self.path = path
      name = basename(path)
    }
  }

  final class Video {
    let name: String
    let path: String
    let size: Int64
    let mtime: Int64
    unowned let dir: DirNode

    init(name: String, path: String, size: Int64, mtime: Int64, dir: DirNode) {
      self.name = name
      self.path = path
      self.size = size
      self.mtime = mtime
      self.dir = dir
    }
  }

  /// Entries as Node's readdir lists them: names sorted by their bytes.
  static func readdir(_ dir: String) -> [(name: String, type: UInt8)]? {
    guard let d = opendir(dir) else { return nil }
    defer { closedir(d) }
    var out: [(String, UInt8)] = []
    while let e = Darwin.readdir(d) {
      let name = withUnsafePointer(to: e.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(e.pointee.d_namlen) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      out.append((name, e.pointee.d_type))
    }
    out.sort { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
    return out
  }

  /// Node's mtimeMs, rounded as the engine stores it.
  static func mtimeMs(_ st: stat) -> Int64 {
    let ms = Double(st.st_mtimespec.tv_sec) * 1000 + Double(st.st_mtimespec.tv_nsec) / 1_000_000
    return Int64(jsRound(ms))
  }

  private static let sampleRe = Re(#"(?:^|[\s._\-])sample$"#, "i")

  private static func walk(_ dir: String, _ depth: Int, _ seen: inout Set<JSKey>) -> DirNode {
    let node = DirNode(path: dir)
    guard let entries = readdir(dir) else { return node }
    // Plain files first, then what needs a second look (links, folders), the
    // order the JavaScript engine's asynchronous walk produced.
    var later: [(String, Bool)] = []  // name, is a symbolic link
    for (name, type) in entries where !name.jsStartsWith(".") {
      if type == DT_REG {
        addFile(node, name)
      } else if type == DT_LNK || type == DT_DIR {
        later.append((name, type == DT_LNK))
      } else if type == DT_UNKNOWN {
        later.append((name, true))
      }
    }
    for (name, isLink) in later {
      let full = join(dir, name)
      var isDir = !isLink
      if isLink {
        var st = stat()
        guard stat(full, &st) == 0 else { continue }
        isDir = (st.st_mode & S_IFMT) == S_IFDIR
        if (st.st_mode & S_IFMT) == S_IFREG { addFile(node, name) }
      }
      guard isDir else { continue }
      if depth >= maxDepth || skipDirs.test(name) { continue }
      guard let real = realpath(full) else { continue }
      if seen.contains(JSKey(real)) { continue }
      seen.insert(JSKey(real))
      let child = walk(full, depth + 1, &seen)
      if child.total > 0 {
        node.dirs.append(child)
      } else if subDirs.test(name) || !child.subs.isEmpty {
        // Subtitle folders next to the video ("Subs/English.srt", "Subs/<episode>/2_English.srt").
        node.subs += child.subs.map { join(name, $0) }
      }
    }
    node.videos.stableSort { naturalCompare($0.name, $1.name) }
    node.dirs.stableSort { naturalCompare($0.name, $1.name) }
    node.total = node.videos.count + node.dirs.reduce(0) { $0 + $1.total }
    return node
  }

  private static func addFile(_ node: DirNode, _ name: String) {
    let ext = extname(name).jsLowercased
    if videoExt.contains(ext) {
      if sampleRe.test(stemOf(name)) { return }
      let full = join(node.path, name)
      var st = stat()
      guard stat(full, &st) == 0 else { return }
      node.videos.append(Video(name: name, path: full, size: Int64(st.st_size), mtime: mtimeMs(st), dir: node))
    } else if subExt.contains(ext) {
      node.subs.append(name)
    } else if imgExt.contains(ext) {
      node.images.append(name)
    }
  }

  static func realpath(_ p: String) -> String? {
    guard let r = Darwin.realpath(p, nil) else { return nil }
    defer { free(r) }
    return String(cString: r)
  }

  // ---- Deciding what is a show ------------------------------------------------------------

  private static func contentDirs(_ node: DirNode) -> [DirNode] { node.dirs.filter { !extraDirs.test($0.name) } }

  private static func collectVideos(_ node: DirNode, _ out: inout [Video]) {
    out += node.videos
    for d in contentDirs(node) { collectVideos(d, &out) }
  }
  private static func collectVideos(_ node: DirNode) -> [Video] {
    var out: [Video] = []
    collectVideos(node, &out)
    return out
  }

  private static let fileShowRe = Re(#"^(.*?)[\s._\-]+(?:s[0-9]{1,2}[\s._\-]*e[0-9]|[0-9]{1,2}x[0-9]{2}|season[\s._\-]*[0-9])"#, "i")

  /// "Severance.S02E01.1080p" -> "Severance"; "" when the name has no show part.
  private static func fileShowName(_ stem: String) -> String {
    let p = parseEpisode(stem)
    if !p.strong || p.season == nil { return "" }
    guard let m = fileShowRe.match(stem) else { return "" }
    return cleanTitle(m[1]!)
  }

  private static func sameShow(_ a: String, _ b: String) -> Bool {
    !a.isEmpty && !b.isEmpty && (a.jsIncludes(b) || b.jsIncludes(a))
  }

  private static func looksLikeShow(_ node: DirNode) -> Bool {
    let dirs = contentDirs(node)
    let seasonDirs = dirs.filter { isSeasonOf($0, node) }
    if !seasonDirs.isEmpty && Double(seasonDirs.count) >= (Double(dirs.count) / 2).rounded(.up) { return true }
    let eps = node.videos.filter { parseEpisode(stemOf($0.name)).strong }
    if node.videos.count < 2 || Double(eps.count) < max(2, Double(node.videos.count) * 0.6) { return false }
    // Episodes of this folder's show, not a Downloads folder holding some episodes.
    var owners: [String] = []
    for v in eps {
      let o = normName(fileShowName(stemOf(v.name)))
      if !o.isEmpty && !owners.contains(o) { owners.append(o) }
    }
    if owners.isEmpty { return true }
    return owners.count == 1 && sameShow(owners[0], normName(showName(node).name))
  }

  enum Kind { case show, movie }

  struct Spec {
    var kind: Kind
    var node: DirNode
    var name: String? = nil
    var videos: [Video]? = nil
    var seasonDirs: [DirNode]? = nil
    var extraDirs: [DirNode]? = nil
    var named = false
  }

  /// Loose files named like episodes ("Severance.S02E01.mkv") become shows,
  /// grouped by the show name in the file name; everything else is a movie.
  private static func looseSpecs(_ node: DirNode, _ videos: [Video]? = nil, named: Bool = false) -> [Spec] {
    var showKeys: [String] = []
    var shows: [String: Spec] = [:]
    var out: [Spec] = []
    for v in videos ?? node.videos {
      let show = fileShowName(stemOf(v.name))
      if !show.isEmpty {
        let key = normName(show)
        if shows[key] == nil {
          showKeys.append(key)
          shows[key] = Spec(kind: .show, node: node, name: show, videos: [], seasonDirs: [])
        }
        shows[key]!.videos!.append(v)
      } else {
        out.append(Spec(kind: .movie, node: node, videos: [v], named: named))
      }
    }
    return showKeys.map { shows[$0]! } + out
  }

  /// A show folder may also hold its films ("Films/Fight the Future/") and
  /// bonus material ("Extras/"). Films become their own titles; extras become an
  /// "Extras" section at the end of the show.
  private static func classifyShow(_ node: DirNode, strict: Bool) -> [Spec] {
    var out: [Spec] = []
    var seasonDirs: [DirNode] = []
    var extras: [DirNode] = []
    for d in node.dirs {
      if extraDirs.test(d.name) {
        extras.append(d)
      } else if strict || isSeasonOf(d, node) {
        seasonDirs.append(d)
      } else {
        let inner = classifyAuto(d)
        if !inner.isEmpty && inner.allSatisfy({ $0.kind == .movie }) { out += inner } else { seasonDirs.append(d) }
      }
    }
    return [Spec(kind: .show, node: node, seasonDirs: seasonDirs, extraDirs: extras)] + out
  }

  private static func classifyAuto(_ node: DirNode) -> [Spec] {
    if looksLikeShow(node) { return classifyShow(node, strict: false) }
    let dirs = contentDirs(node)
    if dirs.isEmpty {
      let vids = node.videos
      if vids.count == 1 { return looseSpecs(node, vids, named: true) }
      if vids.count > 1 && vids.allSatisfy({ partRe.test(stemOf($0.name)) }) {
        return [Spec(kind: .movie, node: node, videos: vids, named: true)]
      }
      let numbered = vids.filter { parseEpisode(stemOf($0.name)).episode != nil }.count
      if vids.count > 1 && Double(numbered) >= Double(vids.count) * 0.6 { return [Spec(kind: .show, node: node)] }
      return looseSpecs(node)
    }
    var out = looseSpecs(node, node.videos, named: node.videos.count == 1)
    for d in dirs { out += classifyAuto(d) }
    return out
  }

  private static func classifyRoot(_ root: DirNode, _ kind: String) -> [Spec] {
    if kind == "movies" {
      return collectVideos(root).map { v in
        Spec(kind: .movie, node: v.dir, videos: [v], named: v.dir.videos.count == 1 && v.dir !== root)
      }
    }
    if looksLikeShow(root) { return classifyShow(root, strict: kind == "shows") }
    var out = looseSpecs(root)
    for d in contentDirs(root) {
      out += kind == "shows" ? classifyShow(d, strict: true) : classifyAuto(d)
    }
    return out
  }

  private static let posterNames = ["poster", "folder", "cover", "show", "default", "movie"]
  private static let backdropNames = ["fanart", "backdrop", "background", "landscape", "art"]

  private static func pickImage(_ node: DirNode, _ names: [String], _ stem: String? = nil) -> String? {
    let want = stem.map { s in [s] + names.map { "\(s)-\($0)" } } ?? names
    for w in want {
      if let hit = node.images.first(where: { stemOf($0).jsLowercased.jsEquals(w.jsLowercased) }) { return join(node.path, hit) }
    }
    return nil
  }

  private static let langNames: [String: String] = ["en": "English", "eng": "English", "es": "Spanish", "spa": "Spanish", "fr": "French", "fre": "French", "fra": "French", "de": "German", "ger": "German", "deu": "German", "it": "Italian", "ita": "Italian", "pt": "Portuguese", "por": "Portuguese", "ja": "Japanese", "jpn": "Japanese", "hi": "Hindi", "hin": "Hindi", "ko": "Korean", "kor": "Korean", "zh": "Chinese", "chi": "Chinese", "zho": "Chinese", "ru": "Russian", "rus": "Russian", "ar": "Arabic", "ara": "Arabic", "nl": "Dutch", "dut": "Dutch"]
  private static let leadNumberUnderscoreRe = Re("^[0-9]+_")
  private static let wordSepRe = Re(#"[\s._\-]+"#)

  private static func subtitleLabel(_ rel: String, _ stem: String) -> String {
    let base = stemOf(basename(rel))
    var rest = base.jsLowercased.jsStartsWith(stem.jsLowercased) ? base.jsSlice(stem.jsLength) : base
    rest = leadNumberUnderscoreRe.replace(leadSepRe.replace(rest, "", global: false), "", global: false)
    let words = wordSepRe.split(rest).filter { !$0.isEmpty }.map { langNames[$0.jsLowercased] ?? $0 }
    let label = words.joined(separator: " ")
    return label.isEmpty ? "External" : label
  }

  private static func subtitlesFor(_ video: Video) -> [SubRef] {
    let node = video.dir
    let stem = stemOf(video.name)
    let only = node.videos.count == 1
    return node.subs
      .filter { rel in
        if only { return true }
        let segs = rel.jsSplit("/")
        return stemOf(segs.last!).jsLowercased.jsStartsWith(stem.jsLowercased) || segs.dropLast().contains { $0.jsEquals(stem) }
      }
      .map { SubRef(path: join(node.path, $0), label: subtitleLabel($0, stem)) }
  }

  static let showSuffix = Re(#"\s+(?:-\s+)?(?:(?:the\s+)?complete(?:\s+(?:series|seasons?|collection))?|(?:seasons?|series)\s*[0-9].*|s[0-9]{1,2}(?:e[0-9]{1,3})?(?:\s*-\s*s?[0-9]{1,2})?(?:\s.*)?)$"#, "i")

  /// "The X-Files Season 1, 2 … + Extras DVDRip" -> "The X-Files". A season
  /// folder added on its own ("Season 1") is named after its parent.
  private static func showName(_ node: DirNode) -> (name: String, year: Int?) {
    for raw in [node.name, basename(dirname(node.path))] {
      let (name, year) = parseTitle(raw)
      let stripped = showSuffix.replace(" \(name)", "", global: false).jsTrimmed
      if !stripped.isEmpty && seasonNumber(stripped) == nil { return (stripped, year) }
    }
    return parseTitle(node.name)
  }

  private static func collectAll(_ node: DirNode, _ out: inout [Video]) {
    out += node.videos
    for d in node.dirs { collectAll(d, &out) }
  }

  final class SeasonGroup {
    var number: Int?
    var name: String
    var poster: String?
    var extras = false
    var videos: [Video]

    init(number: Int?, name: String, poster: String?, extras: Bool = false, videos: [Video] = []) {
      self.number = number
      self.name = name
      self.poster = poster
      self.extras = extras
      self.videos = videos
    }
  }

  final class Built {
    let kind: Kind
    let name: String
    let year: Int?
    let node: DirNode
    var seasons: [SeasonGroup] = []
    var videos: [Video] = []
    var named = false
    var key = ""
    var folderIds: [String] = []

    init(kind: Kind, name: String, year: Int?, node: DirNode) {
      self.kind = kind
      self.name = name
      self.year = year
      self.node = node
    }
  }

  private static func buildShow(_ spec: Spec) -> Built {
    let node = spec.node
    let (name, year) = spec.name.map(parseTitle) ?? showName(node)
    var order: [JSKey] = []
    var seasons: [JSKey: SeasonGroup] = [:]
    func addTo(_ name: String, _ number: Int?, _ label: String, _ poster: String?, _ v: Video) {
      let key = JSKey(name)
      if seasons[key] == nil {
        order.append(key)
        seasons[key] = SeasonGroup(number: number, name: label, poster: poster)
      }
      seasons[key]!.videos.append(v)
    }
    let seasonDirs = spec.seasonDirs ?? contentDirs(node)
    for d in seasonDirs {
      let vids = collectVideos(d)
      var num = seasonNumber(d.name)
      if num == nil {
        let parsed = vids.compactMap { parseEpisode(stemOf($0.name)).season }
        if Double(parsed.count) >= Double(vids.count) * 0.6 && parsed.allSatisfy({ $0 == parsed.first }) { num = parsed.first }
      }
      let key = num.map { "n:\($0)" } ?? "dir:\(d.name)"
      let label: String
      if let n = num { label = n == 0 ? "Specials" : "Season \(n)" } else {
        let c = cleanTitle(d.name)
        label = c.isEmpty ? d.name : c
      }
      for v in vids { addTo(key, num, label, pickImage(d, posterNames), v) }
    }
    // Loose episode files in the show folder: use the season in their name.
    for v in spec.videos ?? node.videos {
      let p = parseEpisode(stemOf(v.name))
      let num = p.season ?? (seasonDirs.isEmpty ? 1 : nil)
      let key = num.map { "n:\($0)" } ?? "other"
      let label = num.map { $0 == 0 ? "Specials" : "Season \($0)" } ?? "Other episodes"
      addTo(key, num, label, nil, v)
    }
    var extras: [Video] = []
    for d in spec.extraDirs ?? [] { collectAll(d, &extras) }
    if !extras.isEmpty {
      if seasons[JSKey("extras")] == nil { order.append(JSKey("extras")) }
      seasons[JSKey("extras")] = SeasonGroup(number: nil, name: "Extras", poster: nil, extras: true, videos: extras)
    }
    let b = Built(kind: .show, name: name, year: year, node: node)
    b.seasons = order.map { seasons[$0]! }
    return b
  }

  private static func buildMovie(_ spec: Spec) -> Built {
    let v = spec.videos![0]
    let src = spec.named ? spec.node.name : stemOf(v.name)
    let (name, year) = parseTitle(src)
    let b = Built(kind: .movie, name: name, year: year, node: spec.node)
    b.videos = spec.videos!
    b.named = spec.named
    return b
  }

  private static func normKey(_ name: String, _ year: Int?) -> String {
    "\(nonAlnumRe.replace(name.jsLowercased, " ").jsTrimmed)|\(year.map(String.init) ?? "")"
  }

  private static func sortEpisodes(_ videos: [Video]) -> [(v: Video, p: Episode?)] {
    var parsed: [(v: Video, p: Episode?)] = videos.map { ($0, parseEpisode(stemOf($0.name))) }
    if parsed.allSatisfy({ $0.p!.episode != nil }) {
      parsed.stableSort { a, b in
        let d = numCompare(a.p!.episode!, b.p!.episode!)
        return d != 0 ? d : naturalCompare(a.v.name, b.v.name)
      }
    } else {
      parsed.stableSort { naturalCompare($0.v.name, $1.v.name) }
    }
    return parsed
  }

  private static func seasonOrder(_ a: SeasonGroup, _ b: SeasonGroup) -> Int {
    func rank(_ s: SeasonGroup) -> Int { s.extras ? 10_000_000 : s.number == nil ? 1_000_000 : s.number == 0 ? 100_000 : s.number! }
    let d = numCompare(rank(a), rank(b))
    return d != 0 ? d : naturalCompare(a.name, b.name)
  }

  /// path.relative(from, to) for absolute paths.
  static func relativePath(from: String, to: String) -> String {
    let a = from.jsSplit("/").filter { !$0.isEmpty }
    let b = to.jsSplit("/").filter { !$0.isEmpty }
    var i = 0
    while i < a.count && i < b.count && a[i].jsEquals(b[i]) { i += 1 }
    return (Array(repeating: "..", count: a.count - i) + b[i...]).joined(separator: "/")
  }

  // ---- The scan ----------------------------------------------------------------------------

  static func scanLibrary(_ folders: [Folder]) -> Library {
    var titleKeys: [String] = []
    var titles: [JSKey: Built] = [:]
    var files: [String: LibraryFile] = [:]
    var fileOrder: [String] = []
    var folderStatus: [String: FolderStatus] = [:]
    // Videos point back at their folder unowned: the trees stay alive until the end.
    var trees: [DirNode] = []
    defer { withExtendedLifetime(trees) {} }
    for folder in folders {
      var st = stat()
      guard stat(folder.path, &st) == 0 else {
        let code = errno
        folderStatus[folder.id] = FolderStatus(
          online: false,
          error: code == ENOENT ? "Folder not found (drive unplugged?)" : "\(String(cString: strerror(code))), stat '\(folder.path)'")
        continue
      }
      guard (st.st_mode & S_IFMT) == S_IFDIR, let real = realpath(folder.path) else {
        folderStatus[folder.id] = FolderStatus(online: false, error: "not a folder")
        continue
      }
      var seen: Set<JSKey> = [JSKey(real)]
      let tree = walk(folder.path, 0, &seen)
      trees.append(tree)
      let specs = classifyRoot(tree, folder.kind)
      var count = 0
      for spec in specs {
        if spec.kind == .show {
          let show = buildShow(spec)
          if show.seasons.isEmpty { continue }
          let key = "show:\(normKey(show.name, show.year))"
          if let existing = titles[JSKey(key)] {
            // Same show split across folders or drives: merge the seasons.
            for s in show.seasons {
              if let twin = existing.seasons.first(where: { ($0.number != nil && $0.number == s.number) || ($0.number == nil && $0.name.jsEquals(s.name)) }) {
                twin.videos += s.videos
              } else {
                existing.seasons.append(s)
              }
            }
            if !existing.folderIds.contains(folder.id) { existing.folderIds.append(folder.id) }
          } else {
            show.key = key
            show.folderIds = [folder.id]
            titles[JSKey(key)] = show
            titleKeys.append(key)
          }
        } else {
          let movie = buildMovie(spec)
          let key = "movie:\(spec.videos![0].path)"
          if titles[JSKey(key)] == nil {
            movie.key = key
            movie.folderIds = [folder.id]
            titles[JSKey(key)] = movie
            titleKeys.append(key)
          }
        }
        count += 1
      }
      folderStatus[folder.id] = FolderStatus(online: true, titles: count, videos: tree.total, scannedAt: nowMs())
    }

    var out: [Title] = []
    for key in titleKeys {
      let t = titles[JSKey(key)]!
      let id = hashId(t.key)
      let node = t.node
      let stem = t.kind == .movie && !t.named ? stemOf(t.videos[0].name) : nil
      var title = Title(
        id: id, kind: t.kind == .show ? "show" : "movie", name: t.name, year: t.year, folderIds: t.folderIds,
        poster: pickImage(node, posterNames, stem), backdrop: pickImage(node, backdropNames, stem), seasons: [], addedAt: 0)
      if t.kind == .show { t.seasons.stableSort(by: seasonOrder) }
      let groups = t.kind == .show ? t.seasons : [SeasonGroup(number: nil, name: "", poster: nil, videos: t.videos)]
      for g in groups {
        var season = Season(id: hashId("\(id)|\(g.name)"), number: g.number, name: g.name, poster: g.poster, episodes: [], extras: g.extras ? true : nil)
        var seen = Set<String>()
        let ordered: [(v: Video, p: Episode?)] = g.extras
          ? g.videos.map { ($0, nil) }.stableSorted { naturalCompare($0.v.path, $1.v.path) }
          : sortEpisodes(g.videos)
        for (v, p) in ordered {
          let fid = hashId(v.path)
          if files[fid] != nil || seen.contains(fid) { continue }
          seen.insert(fid)
          let vstem = stemOf(v.name)
          let part = partRe.match(vstem)
          let name: String
          if t.kind == .movie {
            name = t.videos.count > 1 ? "Part \(part.flatMap { Int($0[1]!) } ?? season.episodes.count + 1)" : t.name
          } else if g.extras {
            let segs = relativePath(from: node.path, to: v.path).jsSplit("/")
            name = segs.enumerated()
              .map { i, x in i == segs.count - 1 ? cleanTitle(stemOf(x)) : x }
              .filter { !extraDirs.test($0) }
              .joined(separator: " › ")
          } else if let p, !p.title.isEmpty, !p.title.jsLowercased.jsEquals(t.name.jsLowercased) {
            name = p.title
          } else if let n = p?.episode {
            name = "Episode \(n)"
          } else {
            name = cleanTitle(vstem)
          }
          files[fid] = LibraryFile(
            id: fid, titleId: id,
            season: title.seasons.count,  // index once this season is added below
            number: t.kind == .show && !g.extras ? (p?.episode ?? season.episodes.count + 1) : nil,
            name: name, path: v.path, size: v.size, mtime: v.mtime,
            thumb: pickImage(v.dir, ["thumb"], vstem), subs: subtitlesFor(v))
          fileOrder.append(fid)
          season.episodes.append(fid)
          title.addedAt = max(title.addedAt, v.mtime)
        }
        if !season.episodes.isEmpty { title.seasons.append(season) }
      }
      if !title.seasons.isEmpty { out.append(title) }
    }
    out.stableSort { naturalCompare($0.name, $1.name) }
    return Library(titles: out, files: files, folderStatus: folderStatus, scannedAt: nowMs(), fileOrder: fileOrder)
  }
}
