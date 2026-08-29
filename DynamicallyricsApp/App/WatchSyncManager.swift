import Foundation
import os.log
import WatchConnectivity
import LyricCore

/// Publishes the current lyric snapshot to a paired Apple Watch over WCSession.
/// Uses `updateApplicationContext` so the watch always has the latest state,
/// even if it was unreachable when the snapshot was produced.
@MainActor
final class WatchSyncManager: NSObject {
    static let shared = WatchSyncManager()

    private static let logger = Logger(subsystem: "com.jonathantran.dynamicallyrics", category: "WatchSync")

    private var lastPayloadKey: String?
    private var activated = false
    private var delegateInstalled = false
    private var pendingSnapshot: WidgetLyricSnapshot?
    private var pendingClear = false

    private override init() {
        super.init()
    }

    /// Activates the WCSession once per process. Safe to call repeatedly.
    func activateIfNeeded() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if !delegateInstalled {
            delegateInstalled = true
            ActivationDelegate.shared.onActivation = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activated = true
                    self.flushPending()
                }
            }
            session.delegate = ActivationDelegate.shared
        }
        if session.activationState == .notActivated {
            session.activate()
        } else {
            activated = true
        }
    }

    /// True when a watch app is paired and the session can deliver state.
    var isWatchReachable: Bool {
        WCSession.isSupported()
            && WCSession.default.activationState == .activated
            && WCSession.default.isPaired
    }

    func publish(_ snapshot: WidgetLyricSnapshot) {
        let key = payloadKey(for: snapshot)
        guard key != lastPayloadKey else { return }
        pendingSnapshot = snapshot
        pendingClear = false
        guard WCSession.isSupported(), activated, WCSession.default.activationState == .activated else { return }
        send(snapshot)
    }

    func clear() {
        pendingSnapshot = nil
        pendingClear = true
        lastPayloadKey = nil
        guard WCSession.isSupported(), activated, WCSession.default.activationState == .activated else { return }
        sendClear()
    }

    private func send(_ snapshot: WidgetLyricSnapshot) {
        var compact = snapshot
        compact.albumImageData = nil
        guard let snapshotData = try? JSONEncoder().encode(compact) else {
            Self.logger.error("Could not encode the watch snapshot")
            return
        }
        let payload: [String: Any] = [
            "snapshotData": snapshotData,
            "trackTitle": snapshot.trackTitle,
            "artistName": snapshot.artistName,
            "currentLine": snapshot.currentLine,
            "isPlaying": snapshot.isPlaying,
            "updatedAt": snapshot.updatedAt.timeIntervalSince1970,
        ]
        var payloadWithArtwork = payload
        if let url = snapshot.albumImageURL,
           let artwork = SharedNowPlaying.cachedArtwork(for: url),
           artwork.count <= 200_000 {
            // The Watch cannot always open the phone's app-group container.
            // Send one bounded copy when the track changes; the snapshot itself
            // still stays small for the iOS widget and Live Activity paths.
            payloadWithArtwork["artworkData"] = artwork
        }
        do {
            try WCSession.default.updateApplicationContext(payloadWithArtwork)
            lastPayloadKey = payloadKey(for: snapshot)
            pendingSnapshot = nil
        } catch {
            Self.logger.error("updateApplicationContext failed: \(error.localizedDescription)")
        }
    }

    private func sendClear() {
        do {
            try WCSession.default.updateApplicationContext([:])
            pendingClear = false
        } catch {
            Self.logger.error("clear context failed: \(error.localizedDescription)")
        }
    }

    private func flushPending() {
        if pendingClear {
            sendClear()
        } else if let pendingSnapshot {
            send(pendingSnapshot)
        }
    }

    var lastPublishedKey: String? { lastPayloadKey }

    private func payloadKey(for snapshot: WidgetLyricSnapshot) -> String {
        let schedule = snapshot.scheduledLines.map {
            String(format: "%.1f:%.1f:%@", $0.date.timeIntervalSince1970,
                   $0.endDate?.timeIntervalSince1970 ?? -1, $0.text)
        }.joined(separator: "|")
        return "\(snapshot.trackTitle)|\(snapshot.artistName)|\(snapshot.currentLine)"
            + "|\(snapshot.isPlaying)|\(snapshot.albumImageURL ?? "")"
            + "|\(snapshot.artworkKey ?? "")|\(snapshot.albumDominantRGB ?? [])|\(schedule)"
    }
}

/// Non-MainActor delegate shim; forwards activation errors to the log.
private final class ActivationDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = ActivationDelegate()
    var onActivation: (() -> Void)?

    fileprivate override init() {
        super.init()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        if let error {
            Self.log.error("WCSession activation failed: \(error.localizedDescription, privacy: .public)")
        } else if activationState == .activated {
            onActivation?()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate to support switching between paired watches.
        session.activate()
    }

    private static let log = Logger(subsystem: "com.jonathantran.dynamicallyrics", category: "WatchSync")
}
