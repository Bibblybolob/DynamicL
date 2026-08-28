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

    init() {
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
        apply(WatchPayload(raw: WCSession.default.receivedApplicationContext))
    }

    private func apply(_ payload: WatchPayload) {
        guard let snapshot = payload.snapshot else { return }
        trackTitle = snapshot.trackTitle
        artistName = snapshot.artistName
        currentLine = snapshot.currentLine
        isPlaying = snapshot.isPlaying
        hasContent = true
        if let url = snapshot.albumImageURL, let data = snapshot.albumImageData {
            SharedNowPlaying.saveArtwork(data, for: url)
        }
        SharedNowPlaying.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func reset() {
        hasContent = false
        trackTitle = "OpenLyrics"
        artistName = ""
        currentLine = "Waiting for your iPhone…"
        isPlaying = false
        SharedNowPlaying.clear()
        WidgetCenter.shared.reloadAllTimelines()
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
            if payload.isEmpty {
                self.onClear()
            } else {
                self.onUpdate(payload)
            }
        }
    }
}

/// Sendable snapshot of a phone payload so it can cross into MainActor isolation.
struct WatchPayload: Sendable {
    let snapshot: WidgetLyricSnapshot?

    init(raw: [String: Any]) {
        if let data = raw["snapshotData"] as? Data,
           let decoded = try? JSONDecoder().decode(WidgetLyricSnapshot.self, from: data) {
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

    var isEmpty: Bool { snapshot == nil }
}
