import Foundation
import MediaPlayer
import LyricCore

/// Publishes now-playing info and receives system transport commands.
///
/// iOS delivers remote-command events (play/pause/skip/seek-with-target) to the
/// app that owns the audio session even while it's backgrounded — the free,
/// system-delivered substitute for APNs Live Activity push. Seek events carry
/// the exact target position, so slider drags become instant Spotify seeks
/// instead of waiting for the next poll.
@MainActor
final class NowPlayingBridge {
    private var installed = false

    private var onToggle: (() -> Void)?
    private var onNext: (() -> Void)?
    private var onPrevious: (() -> Void)?
    private var onChangePosition: ((TimeInterval) -> Void)?

    func install(toggle: @escaping () -> Void,
                 next: @escaping () -> Void,
                 previous: @escaping () -> Void,
                 changePosition: @escaping (TimeInterval) -> Void) {
        guard !installed else { return }
        installed = true
        onToggle = toggle
        onNext = next
        onPrevious = previous
        onChangePosition = changePosition

        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.onToggle?() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.onNext?() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.onPrevious?() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let pos = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            Task { @MainActor in self.onChangePosition?(pos) }
            return .success
        }
    }

    /// Mirrors current playback into the system now-playing slot so the
    /// lock screen routes transport events here.
    func publish(signature: TrackSignature?, position: TimeInterval,
                 duration: TimeInterval?, rate: Double) {
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyPlaybackRate: max(0, rate),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, position),
        ]
        if let signature {
            info[MPMediaItemPropertyTitle] = signature.title
            info[MPMediaItemPropertyArtist] = signature.artist
            info[MPMediaItemPropertyAlbumTitle] = signature.album ?? ""
        }
        if let duration, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
