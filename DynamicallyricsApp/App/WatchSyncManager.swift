import Foundation
import ImageIO
import os.log
import WatchConnectivity
import LyricCore
import UniformTypeIdentifiers

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
    private var sendRetryCount = 0
    private var pendingSendTask: Task<Void, Never>?
    private static let minimumSendInterval: TimeInterval = 2
    private static let maximumSendRetries = 5
    private static let pendingClearKey = "watchSync.pendingClear.v1"
    // Leave room for property-list overhead and future fields. A large lyric
    // schedule plus a detailed cover must not make the complete application
    // context fail and leave the Watch on an old track.
    private static let maximumSnapshotBytes = 36_000
    private static let maximumArtworkBytes = 20_000

    private override init() {
        pendingClear = UserDefaults(suiteName: SharedNowPlaying.appGroupID)?
            .bool(forKey: Self.pendingClearKey) ?? false
        if !pendingClear {
            // The phone snapshot is the durable queue for the latest Watch
            // state. Without this recovery, a process termination while
            // WCSession was inactive could lose the only pending update.
            pendingSnapshot = SharedNowPlaying.load()
        }
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
                    self.sendRetryCount = 0
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
        if key == lastPayloadKey {
            // The state returned to the last packet we delivered before a
            // queued transition was flushed (for example, a rapid skip back).
            // Drop that obsolete transition instead of sending it after the
            // current state and making the Watch appear stale.
            pendingSnapshot = nil
            pendingSendTask?.cancel()
            pendingSendTask = nil
            return
        }
        pendingSnapshot = snapshot
        pendingClear = false
        sendRetryCount = 0
        persistPendingClear(false)
        guard WCSession.isSupported(), activated, WCSession.default.activationState == .activated else { return }
        scheduleSend()
    }

    func clear() {
        pendingSendTask?.cancel()
        pendingSendTask = nil
        pendingSnapshot = nil
        pendingClear = true
        sendRetryCount = 0
        persistPendingClear(true)
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
        let encoder = JSONEncoder()
        var snapshotData = try? encoder.encode(compact)
        // Keep the nearest schedule boundaries first. The Watch can continue
        // from the local schedule, and the track-end boundary remains in the
        // snapshot, so distant lines are the safest data to remove when a
        // long lyric file would exceed the application-context budget.
        while let encoded = snapshotData,
              encoded.count > Self.maximumSnapshotBytes,
              !compact.scheduledLines.isEmpty {
            compact.scheduledLines.removeLast()
            snapshotData = try? encoder.encode(compact)
        }
        guard let snapshotData,
              snapshotData.count <= Self.maximumSnapshotBytes else {
            Self.logger.error("Could not encode the watch snapshot")
            return
        }
        let payload: [String: Any] = [
            "snapshotData": snapshotData,
            // Keep the small legacy fields for a Watch app that has not yet
            // received the matching extension update.
            "trackTitle": snapshot.trackTitle,
            "artistName": snapshot.artistName,
            "currentLine": snapshot.currentLine,
            "isPlaying": snapshot.isPlaying,
            "updatedAt": snapshot.updatedAt.timeIntervalSince1970,
        ]
        var payloadWithArtwork = payload
        if let url = snapshot.albumImageURL,
           let artwork = ArtworkFileCache.data(for: url),
           let boundedArtwork = Self.boundedArtwork(artwork) {
            // The Watch cannot always open the phone's app-group container.
            // Send one small copy when the track changes; the snapshot itself
            // still stays small for the iOS widget and Live Activity paths.
            payloadWithArtwork["artworkData"] = boundedArtwork
        }
        do {
            try WCSession.default.updateApplicationContext(payloadWithArtwork)
            lastPayloadKey = payloadKey(for: snapshot)
            pendingSnapshot = nil
            sendRetryCount = 0
            persistPendingClear(false)
            lastSentAt = .now
        } catch {
            Self.logger.error("updateApplicationContext failed: \(error.localizedDescription)")
            scheduleRetryAfterFailure()
        }
    }

    /// Reduces artwork for WatchConnectivity. A cached image is already a
    /// thumbnail, but JPEG size still varies with album detail. Re-encode only
    /// when needed, and never send an image large enough to crowd out the lyric
    /// schedule in application context.
    private static func boundedArtwork(_ data: Data) -> Data? {
        guard data.count > maximumArtworkBytes else { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 128,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary
              ) else {
            return nil
        }

        for quality in [0.72, 0.56, 0.42] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { return nil }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { return nil }
            if output.length <= maximumArtworkBytes {
                return output as Data
            }
        }
        return nil
    }

    private func sendClear() {
        do {
            // An explicit marker distinguishes a real clear from the empty
            // context returned before WatchConnectivity has delivered its
            // first packet on a cold Watch launch.
            try WCSession.default.updateApplicationContext(["clear": true])
            pendingClear = false
            sendRetryCount = 0
            persistPendingClear(false)
            lastSentAt = .now
        } catch {
            Self.logger.error("clear context failed: \(error.localizedDescription)")
            scheduleRetryAfterFailure()
        }
    }

    private func scheduleRetryAfterFailure() {
        guard sendRetryCount < Self.maximumSendRetries else { return }
        sendRetryCount += 1
        // Keep retries bounded. WCSession can report a transient error while
        // activation is changing; an immediate loop would waste battery.
        lastSentAt = .now
        scheduleSend()
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

    private func persistPendingClear(_ value: Bool) {
        let defaults = UserDefaults(suiteName: SharedNowPlaying.appGroupID)
        if value {
            defaults?.set(true, forKey: Self.pendingClearKey)
        } else {
            defaults?.removeObject(forKey: Self.pendingClearKey)
        }
    }

    private func payloadKey(for snapshot: WidgetLyricSnapshot) -> String {
        // Schedule dates are rebuilt from the live playback clock on every app
        // tick. Keep them out of the key during steady playback, but include a
        // coarse track-end value so a seek or rate change re-sends a corrected
        // schedule to the Watch.
        let schedule = snapshot.scheduledLines.map(\.text).joined(separator: "|")
        let end = snapshot.playbackEndEpoch.map { String(Int(($0 * 2).rounded())) } ?? "-"
        let duration = snapshot.trackDuration.map { String(format: "%.3f", $0) } ?? "-"
        return "\(snapshot.trackID ?? "-")|\(snapshot.trackTitle)|\(snapshot.artistName)|\(snapshot.currentLine)"
            + "|\(snapshot.isPlaying)|\(snapshot.albumImageURL ?? "")"
            + "|\(snapshot.artworkKey ?? "")|\(snapshot.albumDominantRGB ?? [])"
            + "|artworkGeneration=\(ArtworkFileCache.generation())"
            + "|offset=\(snapshot.lyricOffsetMs ?? 0)|duration=\(duration)|\(end)|\(schedule)"
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
