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

    private override init() {
        super.init()
    }

    /// Activates the WCSession once per process. Safe to call repeatedly.
    func activateIfNeeded() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if !delegateInstalled {
            delegateInstalled = true
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
            && (WCSession.default.isPaired ?? false)
    }

    func publish(_ snapshot: WidgetLyricSnapshot) {
        let key = payloadKey(for: snapshot)
        guard key != lastPayloadKey else { return }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let payload: [String: Any] = [
            "trackTitle": snapshot.trackTitle,
            "artistName": snapshot.artistName,
            "currentLine": snapshot.currentLine,
            "isPlaying": snapshot.isPlaying,
            "updatedAt": snapshot.updatedAt.timeIntervalSince1970,
        ]
        do {
            try WCSession.default.updateApplicationContext(payload)
            lastPayloadKey = key
        } catch {
            Self.logger.error("updateApplicationContext failed: \(error.localizedDescription)")
        }
    }

    func clear() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext([:])
        lastPayloadKey = nil
    }

    var lastPublishedKey: String? { lastPayloadKey }

    private func payloadKey(for snapshot: WidgetLyricSnapshot) -> String {
        "\(snapshot.trackTitle)|\(snapshot.currentLine)|\(snapshot.isPlaying)"
    }
}

/// Non-MainActor delegate shim; forwards activation errors to the log.
private final class ActivationDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = ActivationDelegate()

    fileprivate override init() {
        super.init()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        if let error {
            Self.log.error("WCSession activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate to support switching between paired watches.
        session.activate()
    }

    private static let log = Logger(subsystem: "com.jonathantran.dynamicallyrics", category: "WatchSync")
}
