import AppKit
import MediaPlayer

// Control Center's Now Playing and the media keys (play, pause, skip, next
// episode), as the pages' Media Session did. The player that reported last
// owns them. The only file that imports MediaPlayer: the player class has the
// same name.

/// What a media key or Control Center asked for.
enum RemoteCommand {
  case play, pause, toggle, back, forward
  case seek(Double)
  case next
}

@MainActor
enum NowPlaying {
  private static weak var owner: PlayerModel?
  /// The open players that have reported, latest last: when the owner closes,
  /// the latest one still playing (or else still open) takes over.
  private static var reported: [WeakPlayer] = []
  private struct WeakPlayer { weak var player: PlayerModel? }
  private static var registered = false
  /// The video whose picture `artwork` is (or is being loaded for).
  private static var artworkFor: String?
  private static var artwork: MPMediaItemArtwork?

  static func update(
    _ p: PlayerModel, fileId: String, title: String, artist: String, duration: Double, elapsed: Double, rate: Double,
    hasNext: Bool
  ) {
    register()
    owner = p
    reported.removeAll { $0.player == nil || $0.player === p }
    reported.append(WeakPlayer(player: p))
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
      MPNowPlayingInfoPropertyPlaybackRate: rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
    ]
    if !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    if artworkFor != fileId {
      artworkFor = fileId
      artwork = nil
      let src = ArtSource.file(fileId, width: 480)
      if let image = ArtCache.shared.cached(src) {
        artwork = makeArtwork(image)
      } else {
        Task {
          guard let image = await ArtCache.shared.load(src), artworkFor == fileId, owner != nil else { return }
          let art = makeArtwork(image)
          artwork = art
          MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = art
        }
      }
    }
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = info
    center.playbackState = rate > 0 ? .playing : .paused
    enable(true, next: hasNext)
  }

  /// The player closed: another open player takes Now Playing, or it empties.
  static func release(_ p: PlayerModel) {
    reported.removeAll { $0.player == nil || $0.player === p }
    guard owner === p else { return }
    owner = nil
    artworkFor = nil
    artwork = nil
    let open = reported.compactMap(\.player).filter { $0.fid != nil }
    if let next = open.last(where: \.playing) ?? open.last {
      next.updateNowPlaying()
      return
    }
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
    enable(false)
  }

  /// The commands answer only while a player has Now Playing, so the media
  /// keys go to another app once it closes.
  private static func enable(_ on: Bool, next: Bool = false) {
    let c = MPRemoteCommandCenter.shared()
    for command in [
      c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.skipBackwardCommand, c.skipForwardCommand,
      c.changePlaybackPositionCommand,
    ] {
      command.isEnabled = on
    }
    c.nextTrackCommand.isEnabled = on && next
  }

  private static func register() {
    guard !registered else { return }
    registered = true
    addTargets()
  }

  /// Outside the main actor: the handlers may be called on any thread.
  nonisolated private static func addTargets() {
    let c = MPRemoteCommandCenter.shared()
    func on(_ command: MPRemoteCommand, _ make: @escaping @Sendable (MPRemoteCommandEvent) -> RemoteCommand?) {
      command.isEnabled = true
      command.addTarget { event in
        guard let cmd = make(event) else { return .commandFailed }
        Task { @MainActor in NowPlaying.owner?.remote(cmd) }
        return .success
      }
    }
    on(c.playCommand) { _ in .play }
    on(c.pauseCommand) { _ in .pause }
    on(c.togglePlayPauseCommand) { _ in .toggle }
    c.skipBackwardCommand.preferredIntervals = [10]
    c.skipForwardCommand.preferredIntervals = [10]
    on(c.skipBackwardCommand) { _ in .back }
    on(c.skipForwardCommand) { _ in .forward }
    on(c.changePlaybackPositionCommand) { e in
      (e as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) }
    }
    on(c.nextTrackCommand) { _ in .next }
  }

  nonisolated private static func makeArtwork(_ image: CGImage) -> MPMediaItemArtwork {
    let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    return MPMediaItemArtwork(boundsSize: picture.size) { _ in picture }
  }
}
