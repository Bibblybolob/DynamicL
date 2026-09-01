import SwiftUI
import WatchConnectivity
import WidgetKit
import LyricCore

@main
struct DynamicallyricsWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            NowPlayingWatchView(model: model)
        }
    }
}

@MainActor
@Observable
final class WatchModel {
    var trackTitle: String = "OpenLyrics"
    var artistName: String = ""
    var currentLine: String = "Waiting for your iPhone…"
    var isPlaying: Bool = false
    var hasContent = false

    private var delegate: WatchReceiverDelegate?
    private var schedule: [WidgetLyricSnapshot.ScheduledLine] = []
    private var playbackEndDate: Date?
    private var scheduleTask: Task<Void, Never>?
    private var lastAcceptedSnapshotDate: Date

    init() {
        lastAcceptedSnapshotDate = SharedNowPlaying.loadWatch()?.updatedAt ?? .distantPast
        guard WCSession.isSupported() else { return }
        let delegate = WatchReceiverDelegate { [weak self] payload in
            self?.apply(payload)
        } onClear: { [weak self] in
            self?.reset()
        }
        self.delegate = delegate
        WCSession.default.delegate = delegate
        WCSession.default.activate()
        // Show any state queued by the phone before we launched.
        let queuedPayload = WatchPayload(raw: WCSession.default.receivedApplicationContext)
        if queuedPayload.isClear {
            reset()
        } else if queuedPayload.isEmpty, let savedSnapshot = SharedNowPlaying.loadWatch() {
            // An empty received context is normal on the first Watch launch;
            // it is not proof that the phone sent a clear tombstone. Recover
            // the durable snapshot before the first real WCSession callback.
            apply(WatchPayload(snapshot: savedSnapshot))
        } else if queuedPayload.isEmpty {
            reset()
        } else {
            apply(queuedPayload)
        }
        scheduleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.advanceSchedule(at: .now)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func apply(_ payload: WatchPayload) {
        guard let snapshot = payload.snapshot else { return }
        // Application context is latest-value delivery, but an in-flight
        // message can still arrive after a newer context. Ignore that packet
        // so a rapid track change cannot restore an old lyric schedule.
        guard snapshot.updatedAt >= lastAcceptedSnapshotDate else { return }
        lastAcceptedSnapshotDate = snapshot.updatedAt
        trackTitle = snapshot.trackTitle
        artistName = snapshot.artistName
        currentLine = snapshot.currentLine
        // Use the same short-lived command projection as the iPhone widget
        // and Watch complication. A play/pause tap can arrive before Spotify
        // confirms the new state; showing the raw snapshot here makes the
        // Watch disagree with the other surfaces during that window.
        isPlaying = SharedNowPlaying.effectiveIsPlaying(snapshot)
        hasContent = true
        schedule = snapshot.scheduledLines.sorted { $0.date < $1.date }
        playbackEndDate = isPlaying
            ? snapshot.playbackEndEpoch.map(Date.init(timeIntervalSince1970:))
            : nil
        advanceSchedule(at: .now)
        guard hasContent else { return }
        if let url = snapshot.albumImageURL, let data = snapshot.albumImageData {
            Task {
                await ArtworkRepository.shared.save(data, for: url)
            }
        }
        // Keep Watch state separate from the phone/widget snapshot. A
        // delayed Watch packet must not roll back phone surfaces.
        SharedNowPlaying.saveWatch(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func reset(rejectingSnapshotsBefore boundary: Date? = nil) {
        let rejectionBoundary = boundary ?? .now
        if rejectionBoundary > lastAcceptedSnapshotDate {
            lastAcceptedSnapshotDate = rejectionBoundary
        }
        hasContent = false
        trackTitle = "OpenLyrics"
        artistName = ""
        currentLine = "Waiting for your iPhone…"
        isPlaying = false
        schedule = []
        playbackEndDate = nil
        // The Watch reaches this boundary from its local schedule. Do not
        // clear the phone-owned snapshot in the shared app group.
        SharedNowPlaying.clearWatch()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The Watch app may not receive a new Connectivity packet for every lyric
    /// line. Advance from the absolute schedule that arrived with the last
    /// packet so the visible line stays aligned while the phone is suspended.
    private func advanceSchedule(at date: Date) {
        guard hasContent, isPlaying else { return }
        if let playbackEndDate, date >= playbackEndDate {
            // The phone can be suspended at the end of a song. Clear the
            // visible Watch state from the absolute end boundary instead of
            // leaving the last lyric on screen until the next packet.
            reset(rejectingSnapshotsBefore: playbackEndDate)
            return
        }
        if let line = schedule.last(where: { $0.date <= date }) {
            currentLine = line.text
        }
    }
}

/// Receives application context updates from the iOS app.
/// Bridges nonisolated WCSession callbacks into MainActor closures via a Sendable box.
private final class WatchReceiverDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let onUpdate: @MainActor (WatchPayload) -> Void
    private let onClear: @MainActor () -> Void

    init(onUpdate: @escaping @MainActor (WatchPayload) -> Void, onClear: @escaping @MainActor () -> Void) {
        self.onUpdate = onUpdate
        self.onClear = onClear
        super.init()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {}

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        deliver(message)
        replyHandler(["ok": true])
    }

    private nonisolated func deliver(_ raw: [String: Any]) {
        let payload = WatchPayload(raw: raw)
        Task { @MainActor in
            if payload.isClear {
                self.onClear()
            } else if payload.snapshot != nil {
                self.onUpdate(payload)
            }
        }
    }
}

/// Sendable snapshot of a phone payload so it can cross into MainActor isolation.
struct WatchPayload: Sendable {
    let snapshot: WidgetLyricSnapshot?
    let isClear: Bool

    init(snapshot: WidgetLyricSnapshot) {
        self.snapshot = snapshot
        self.isClear = false
    }

    init(raw: [String: Any]) {
        isClear = raw["clear"] as? Bool == true
        if let data = raw["snapshotData"] as? Data,
           var decoded = try? JSONDecoder().decode(WidgetLyricSnapshot.self, from: data) {
            if let artwork = raw["artworkData"] as? Data, artwork.count <= 200_000 {
                decoded.albumImageData = artwork
            }
            snapshot = decoded
            return
        }

        // Keep one-version compatibility with phone builds that sent only the
        // currently visible text fields.
        if let trackTitle = raw["trackTitle"] as? String,
           let currentLine = raw["currentLine"] as? String {
            snapshot = WidgetLyricSnapshot(
                trackTitle: trackTitle,
                artistName: raw["artistName"] as? String ?? "",
                currentLine: currentLine,
                isPlaying: raw["isPlaying"] as? Bool ?? false
            )
        } else {
            snapshot = nil
        }
    }

    var isEmpty: Bool { snapshot == nil && !isClear }
}
