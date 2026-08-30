import AVFoundation
import Foundation
import os.log

/// Keeps the app process alive while it owns a Live Activity.
///
/// The sync server is the preferred background authority. This fallback is
/// retained as an opt-in beta path for users who need faster locked-screen
/// recovery. It is silent and mixed with other audio. It stops after a
/// confirmed stop, disconnect, or when the user disables the beta mode.
@MainActor
final class BackgroundAudioKeeper {
    static let shared = BackgroundAudioKeeper()

    private static let log = Logger(
        subsystem: "com.jonathantran.dynamicallyrics",
        category: "BackgroundAudio"
    )

    private var player: AVAudioPlayer?
    private(set) var isKeepingAlive = false

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaServerResetObserver: NSObjectProtocol?
    private var lastResurrectAt = Date.distantPast

    private static let loudVolume: Float = 0.01
    private static let idleVolume: Float = 0.001

    var isPlayerAlive: Bool {
        player?.isPlaying == true
    }

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

            let player = try AVAudioPlayer(contentsOf: Self.silentFileURL())
            player.numberOfLoops = -1
            player.volume = Self.loudVolume
            guard player.play() else {
                throw NSError(
                    domain: "BackgroundAudioKeeper",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The silent player did not start"]
                )
            }

            self.player = player
            isKeepingAlive = true
            installObservers()
            Self.log.info("keep-alive started")
            DiagnosticsLog.append("keep-alive started, playing=\(player.isPlaying)")
        } catch {
            isKeepingAlive = false
            self.player = nil
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            Self.log.error("keep-alive failed: \(error.localizedDescription)")
            DiagnosticsLog.append("keep-alive failed")
        }
    }

    /// Rebuilds the player after an interruption, route change, or media
    /// server reset. The rate limit prevents an audio failure from becoming a
    /// restart loop on the main actor.
    func resurrect() {
        guard Date.now.timeIntervalSince(lastResurrectAt) > 5 else { return }
        lastResurrectAt = .now
        DiagnosticsLog.append("keeper: resurrect")
        player?.stop()
        player = nil
        isKeepingAlive = false
        start()
    }

    func stop() {
        player?.stop()
        player = nil
        isKeepingAlive = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func installObservers() {
        let center = NotificationCenter.default
        if interruptionObserver == nil {
            interruptionObserver = center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor [weak self] in
                    guard let self,
                          let rawType,
                          let type = AVAudioSession.InterruptionType(rawValue: rawType)
                    else { return }
                    switch type {
                    case .began:
                        self.player?.pause()
                        DiagnosticsLog.append("keeper: interruption began")
                    case .ended:
                        guard self.isKeepingAlive else { return }
                        self.player?.play()
                        DiagnosticsLog.append("keeper: interruption ended")
                    @unknown default:
                        break
                    }
                }
            }
        }

        if routeChangeObserver == nil {
            routeChangeObserver = center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isKeepingAlive,
                          let rawReason,
                          let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
                          reason == .oldDeviceUnavailable || reason == .newDeviceAvailable
                    else { return }
                    DiagnosticsLog.append("keeper: route change (\(reason.rawValue))")
                    self.resurrect()
                }
            }
        }

        if mediaServerResetObserver == nil {
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

    private static func silentFileURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "openlyrics-silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate: UInt32 = 8_000
        let seconds: UInt32 = 5
        let sampleCount = sampleRate * seconds
        var data = Data()

        func append32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Data("RIFF".utf8))
        append32(36 + sampleCount * 2)
        data.append(contentsOf: Data("WAVE".utf8))
        data.append(contentsOf: Data("fmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(sampleRate)
        append32(sampleRate * 2)
        append16(2)
        append16(16)
        data.append(contentsOf: Data("data".utf8))
        append32(sampleCount * 2)
        data.append(Data(count: Int(sampleCount * 2)))

        try? data.write(to: url, options: .atomic)
        return url
    }
}
