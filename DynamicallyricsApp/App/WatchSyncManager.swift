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
    private var lastSentAt: Date?
    private var pendingSendTask: Task<Void, Never>?
    private static let minimumSendInterval: TimeInterval = 2

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
                    self.scheduleSend()
                }
            }
            session.delegate = ActivationDelegate.shared
        }
        if session.activationState == .notActivated {
            session.activate()
        } else {
            activated = true
            scheduleSend()
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
        scheduleSend()
    }

    func clear() {
        pendingSendTask?.cancel()
        pendingSendTask = nil
        pendingSnapshot = nil
        pendingClear = true
        lastPayloadKey = nil
        guard WCSession.isSupported(), activated, WCSession.default.activationState == .activated else { return }
        scheduleSend()
    }

    private func scheduleSend() {
        guard pendingSendTask == nil else { return }
        let delay = max(0, Self.minimumSendInterval - Date.now.timeIntervalSince(lastSentAt ?? .distantPast))
        if delay == 0 {
            flushPending()
            return
        }
        pendingSendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.flushPending()
        }
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
            lastSentAt = .now
        } catch {
            Self.logger.error("updateApplicationContext failed: \(error.localizedDescription)")
        }
    }

    private func sendClear() {
        do {
            try WCSession.default.updateApplicationContext([:])
            pendingClear = false
            lastSentAt = .now
        } catch {
            Self.logger.error("clear context failed: \(error.localizedDescription)")
        }
    }

    private func flushPending() {
        pendingSendTask = nil
        if pendingClear {
            sendClear()
        } else if let pendingSnapshot {
            send(pendingSnapshot)
        }
    }

    var lastPublishedKey: String? { lastPayloadKey }

    private func payloadKey(for snapshot: WidgetLyricSnapshot) -> String {
        // Schedule dates are rebuilt from the live playback clock on every app
        // tick. Keep them out of the key during steady playback, but include a
        // coarse track-end value so a seek or rate change re-sends a corrected
        // schedule to the Watch.
        let schedule = snapshot.scheduledLines.map(\.text).joined(separator: "|")
        let end = snapshot.playbackEndEpoch.map { String(Int(($0 * 2).rounded())) } ?? "-"
        return "\(snapshot.trackTitle)|\(snapshot.artistName)|\(snapshot.currentLine)"
            + "|\(snapshot.isPlaying)|\(snapshot.albumImageURL ?? "")"
            + "|\(snapshot.artworkKey ?? "")|\(snapshot.albumDominantRGB ?? [])|\(end)|\(schedule)"
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
