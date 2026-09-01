import Foundation

/// Versioned app-group storage for the small playback contract shared by
/// phone, widgets, Live Activity, Watch, and the server.
///
/// `WidgetLyricSnapshot` remains the renderer-facing compatibility format for
/// one release. New readers can use this store without decoding artwork bytes
/// or depending on Swift `Date` encoding.
public enum SharedPlaybackSnapshotV2Store {
    private static let key = "sharedPlaybackSnapshotV2"

    public static func save(_ snapshot: SharedPlaybackSnapshotV2) {
        saveV2(snapshot, defaults: UserDefaults(suiteName: SharedNowPlaying.appGroupID))
    }

    public static func load() -> SharedPlaybackSnapshotV2? {
        load(defaults: UserDefaults(suiteName: SharedNowPlaying.appGroupID))
    }

    /// Publishes the V2 representation while retaining the V1 snapshot for
    /// older extensions during the migration release.
    static func saveWidget(_ snapshot: WidgetLyricSnapshot, defaults: UserDefaults?) {
        guard let defaults,
              let converted = convert(snapshot),
              let data = try? JSONEncoder().encode(converted) else { return }
        defaults.set(data, forKey: key)
    }

    private static func saveV2(_ snapshot: SharedPlaybackSnapshotV2, defaults: UserDefaults?) {
        guard let defaults,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(defaults: UserDefaults?) -> SharedPlaybackSnapshotV2? {
        guard let defaults,
              let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(
                  SharedPlaybackSnapshotV2.self,
                  from: data
              ) else { return nil }
        return snapshot
    }

    private static func convert(_ snapshot: WidgetLyricSnapshot)
        -> SharedPlaybackSnapshotV2? {
        let intervals = snapshot.scheduledLines.compactMap { line -> SharedPlaybackSnapshotV2.LyricInterval? in
            guard line.date.timeIntervalSince1970.isFinite else { return nil }
            return .init(
                startEpoch: line.date.timeIntervalSince1970,
                endEpoch: line.endDate?.timeIntervalSince1970,
                text: line.text
            )
        }
        let anchor = snapshot.playbackAnchorEpoch
            ?? inferredAnchor(for: snapshot)
        return SharedPlaybackSnapshotV2(
            trackID: snapshot.trackID,
            trackTitle: snapshot.trackTitle,
            artistName: snapshot.artistName,
            albumImageURL: snapshot.albumImageURL,
            artworkKey: snapshot.artworkKey,
            dominantRGB: snapshot.albumDominantRGB,
            isPlaying: snapshot.isPlaying,
            trackDurationSeconds: snapshot.trackDuration,
            playbackEndEpoch: snapshot.playbackEndEpoch,
            playbackAnchorEpoch: anchor,
            generatedAtEpoch: snapshot.generatedAtEpoch
                ?? snapshot.updatedAt.timeIntervalSince1970,
            revision: snapshot.revision ?? 0,
            lyricOffsetSeconds: TimeInterval(snapshot.lyricOffsetMs ?? 0) / 1_000,
            currentLine: snapshot.currentLine,
            nextLine: intervals.first?.text,
            lyricIntervals: intervals
        )
    }

    private static func inferredAnchor(for snapshot: WidgetLyricSnapshot)
        -> TimeInterval? {
        guard snapshot.isPlaying,
              let end = snapshot.playbackEndEpoch,
              let duration = snapshot.trackDuration,
              duration.isFinite,
              duration > 0 else { return nil }
        return end - duration
    }
}
