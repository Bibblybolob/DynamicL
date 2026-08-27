import AVFoundation
import Foundation
import os.log

/// Plays silent looping audio so the app can keep updating Live Activities while backgrounded.
@MainActor
final class BackgroundAudioKeeper {
    static let shared = BackgroundAudioKeeper()

    private static let log = Logger(subsystem: "com.jonathantran.dynamicallyrics", category: "BackgroundAudio")

    private var player: AVAudioPlayer?
    private(set) var isKeepingAlive = false

    private var interruptionObserver: (any NSObjectProtocol)?
    private var routeChangeObserver: (any NSObjectProtocol)?
    private var mediaServerResetObserver: (any NSObjectProtocol)?
    /// Called when an audio interruption ends and playback resumes.
    var onInterruptionEnded: (() -> Void)?

    private var lastResurrectAt: Date = .distantPast

    /// Ground truth: is audio actually flowing right now? `isKeepingAlive`
    /// records intent; iOS can still silently stop the player underneath us
    /// (media server resets, some route changes) — this catches that gap.
    var isPlayerAlive: Bool {
        player?.isPlaying == true
    }

    /// Audible-guard volumes: loud while playing, near-silent while paused/idle.
    private static let loudVolume: Float = 0.01
    private static let idleVolume: Float = 0.001

    /// Drops playback volume while keeping the session active (process alive).
    func setLoud(_ loud: Bool) {
        guard isKeepingAlive else { return }
        player?.volume = loud ? Self.loudVolume : Self.idleVolume
    }

    func start() {
        guard !isKeepingAlive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            player = try AVAudioPlayer(contentsOf: Self.silentFileURL())
            player?.numberOfLoops = -1
            player?.volume = 0.01
            player?.play()
            isKeepingAlive = true
            Self.log.info("keep-alive started, playing=\(self.player?.isPlaying ?? false)")
            DiagnosticsLog.append("keep-alive started, playing=\(player?.isPlaying ?? false)")

            installObservers()
        } catch {
            Self.log.error("keep-alive audio failed: \(error.localizedDescription)")
            isKeepingAlive = false
        }
    }

    /// Rebuilds the player from scratch. Called by the tick guard whenever the
    /// app should be keeping alive but audio has silently stopped (media
    /// server reset, unresumed interruption, route-change kill). Rate-limited
    /// so a hostile environment can't spin us into a restart loop.
    func resurrect() {
        guard Date.now.timeIntervalSince(lastResurrectAt) > 5 else { return }
        lastResurrectAt = .now
        Self.log.info("keeper: resurrect")
        DiagnosticsLog.append("keeper: resurrect")
        if isKeepingAlive {
            player?.stop()
            player = nil
            isKeepingAlive = false
        }
        start()
    }

    func stop() {
        player?.stop()
        player = nil
        isKeepingAlive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        if interruptionObserver == nil {
            interruptionObserver = center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleInterruption(typeValue: typeValue)
                }
            }
        }
        if routeChangeObserver == nil {
            // Route changes (headphones yanked, BT drop) can tear the session
            // down without an interruption event — rebuild on the next tick.
            routeChangeObserver = center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.isKeepingAlive,
                          let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                          reason == .oldDeviceUnavailable || reason == .newDeviceAvailable
                    else { return }
                    DiagnosticsLog.append("keeper: route change (\(reason.rawValue))")
                    self.resurrect()
                }
            }
        }
        if mediaServerResetObserver == nil {
            // The nuclear case: the media server restarted and every session
            // config/player handle is invalid. Full rebuild required.
            mediaServerResetObserver = center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isKeepingAlive else { return }
                    DiagnosticsLog.append("keeper: media services reset")
                    self.resurrect()
                }
            }
        }
    }

    private func handleInterruption(typeValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            DiagnosticsLog.append("keeper: interruption began")
            player?.pause()
        case .ended:
            // Resume whenever we're supposed to be keeping the app alive,
            // even if iOS didn't set .shouldResume (e.g. short interruptions),
            // otherwise the keep-alive silently dies mid-session.
            if isKeepingAlive {
                DiagnosticsLog.append("keeper: interruption ended, resuming")
                player?.play()
                onInterruptionEnded?()
            }
        @unknown default:
            break
        }
    }

    private static func silentFileURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 8000
        let seconds = 5
        let sampleCount = sampleRate * seconds
        var data = Data()

        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append("RIFF".data(using: .ascii)!); append(UInt32(36 + sampleCount * 2))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); append(16)
        append16(1); append16(1); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append16(2); append16(16)
        data.append("data".data(using: .ascii)!); append(UInt32(sampleCount * 2))
        data.append(Data(count: sampleCount * 2))

        try? data.write(to: url)
        return url
    }
}
