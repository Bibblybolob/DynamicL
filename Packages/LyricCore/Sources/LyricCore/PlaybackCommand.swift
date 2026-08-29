import Foundation

/// A remote-control command sent from a widget, Live Activity, or Watch.
public enum PlaybackCommand: String, Codable, Sendable, Equatable {
    case togglePlayPause
    case next
    case previous
    case refresh
}

public struct PlaybackCommandEnvelope: Codable, Sendable, Equatable {
    public let id: UUID
    public let command: PlaybackCommand
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        command: PlaybackCommand,
        issuedAt: Date = .now,
        ttl: TimeInterval = 8
    ) {
        self.id = id
        self.command = command
        self.issuedAt = issuedAt
        self.expiresAt = issuedAt.addingTimeInterval(max(1, ttl))
    }

    public var isExpired: Bool { Date.now >= expiresAt }
}

/// Small shared queue for commands. Unlike the old single string mailbox,
/// rapid taps are retained in order and expired commands are discarded.
public enum PlaybackCommandBus {
    private static let storageKey = "pendingPlaybackCommands"
    private static let legacyStorageKey = "pendingPlaybackCommand"
    private static let queueLock = NSLock()

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: SharedNowPlaying.appGroupID)
    }

    public static func send(_ command: PlaybackCommand) {
        send(command, defaults: sharedDefaults)
    }

    public static func consume() -> PlaybackCommand? {
        consumeEnvelope()?.command
    }

    public static func consumeEnvelope() -> PlaybackCommandEnvelope? {
        consumeEnvelope(defaults: sharedDefaults)
    }

    static func send(_ command: PlaybackCommand, defaults: UserDefaults?) {
        send(PlaybackCommandEnvelope(command: command), defaults: defaults)
    }

    static func send(_ envelope: PlaybackCommandEnvelope, defaults: UserDefaults?) {
        guard let defaults else { return }
        queueLock.lock()
        defer { queueLock.unlock() }
        var queue = decodeQueue(defaults: defaults).filter { !$0.isExpired }
        queue.append(envelope)
        queue = Array(queue.suffix(8))
        if let data = try? JSONEncoder().encode(queue) {
            defaults.set(data, forKey: storageKey)
        }
        defaults.removeObject(forKey: legacyStorageKey)
    }

    static func consume(defaults: UserDefaults?) -> PlaybackCommand? {
        consumeEnvelope(defaults: defaults)?.command
    }

    static func consumeEnvelope(defaults: UserDefaults?) -> PlaybackCommandEnvelope? {
        guard let defaults else { return nil }
        queueLock.lock()
        defer { queueLock.unlock() }
        var queue = decodeQueue(defaults: defaults).filter { !$0.isExpired }
        let result = queue.isEmpty ? nil : queue.removeFirst()
        if let data = try? JSONEncoder().encode(queue), !queue.isEmpty {
            defaults.set(data, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
        if result == nil,
           let raw = defaults.string(forKey: legacyStorageKey),
           let command = PlaybackCommand(rawValue: raw) {
            defaults.removeObject(forKey: legacyStorageKey)
            return PlaybackCommandEnvelope(command: command)
        }
        return result
    }

    private static func decodeQueue(defaults: UserDefaults) -> [PlaybackCommandEnvelope] {
        guard let data = defaults.data(forKey: storageKey),
              let queue = try? JSONDecoder().decode([PlaybackCommandEnvelope].self, from: data) else {
            return []
        }
        return queue
    }
}
