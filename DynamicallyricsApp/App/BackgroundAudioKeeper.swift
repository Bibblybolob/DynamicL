import AVFoundation
import Foundation
import os.log

/// Plays silent looping audio so the app can keep updating Live Activities while backgrounded.
final class BackgroundAudioKeeper {
    nonisolated(unsafe) static let shared = BackgroundAudioKeeper()

    private static let log = Logger(subsystem: "com.jonathantran.dynamicallyrics", category: "BackgroundAudio")

    private var player: AVAudioPlayer?
    private(set) var isKeepingAlive = false

    private var interruptionObserver: (any NSObjectProtocol)?

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

            if interruptionObserver == nil {
                interruptionObserver = NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    self?.handleInterruption(notification)
                }
            }
        } catch {
            Self.log.error("keep-alive audio failed: \(error.localizedDescription)")
            isKeepingAlive = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isKeepingAlive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            player?.pause()
        case .ended:
            // Resume whenever we're supposed to be keeping the app alive,
            // even if iOS didn't set .shouldResume (e.g. short interruptions),
            // otherwise the keep-alive silently dies mid-session.
            if isKeepingAlive {
                player?.play()
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
