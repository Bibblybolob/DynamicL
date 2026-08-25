import Foundation

/// Wall-clock mapping of a playback status so WidgetKit's timerInterval views
/// (ProgressView/Text) can advance playback UI with zero app involvement:
/// the system renders progress between startDate and endDate on its own clock.
public struct PlaybackAnchors: Equatable, Sendable {
    public let startDate: Date
    public let endDate: Date?
    /// Set only while paused: fraction of the song elapsed, for a static bar
    /// (timerInterval views would keep advancing a paused range, so pause is
    /// rendered as a fixed value instead of an interval).
    public let frozenFraction: Double?

    /// - Parameters:
    ///   - status: current playback state; position/rate/timestamp map onto wall time.
    ///   - duration: total track length in seconds; falls back to position+1 when unknown.
    public init(status: PlaybackStatus, duration: TimeInterval?) {
        let dur = max(duration ?? (status.position + 1), status.position + 0.001)
        if status.state == .playing {
            let rate = max(status.rate, 0.001)
            self.startDate = status.timestamp.addingTimeInterval(-status.position / rate)
            self.endDate = self.startDate.addingTimeInterval(dur / rate)
            self.frozenFraction = nil
        } else {
            // Paused/stopped: pin both ends at the observation instant and
            // expose the elapsed fraction for a static render.
            self.startDate = status.timestamp
            self.endDate = nil
            self.frozenFraction = min(max(status.position / dur, 0), 1)
        }
    }
}
