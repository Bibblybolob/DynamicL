import CryptoKit
import Foundation

/// Small synchronous read API for extension renderers. The app owns writes
/// through ArtworkRepository. Both sides use the same app-group file names.
public enum ArtworkFileCache {
    private static let directoryName = "ArtworkCacheV2"
    private static let memory = LockedArtworkMemory()
    private static let fileLock = NSLock()
    private static let maximumEntries = 4
    private static let maximumBytes = 2 * 1024 * 1024

    private struct CacheEntry: Codable, Equatable {
        let key: String
        let url: String
        let bytes: Int
        let lastAccess: Date
    }

    public static func key(for urlString: String) -> String? {
        let value = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func directoryURL() -> URL {
        let fileManager = FileManager.default
        let root = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedNowPlaying.appGroupID
        ) ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func data(for urlString: String) -> Data? {
        guard let key = key(for: urlString) else { return nil }
        if let cached = memory.object(forKey: key) { return cached }
        let file = directoryURL().appendingPathComponent("\(key).bin")
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        memory.set(data, forKey: key)
        return data
    }

    /// Stores one normalized artwork payload. The write is atomic and the
    /// index is bounded so extensions never receive a large UserDefaults blob.
    @discardableResult
    public static func store(_ data: Data, for urlString: String) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes,
              let key = key(for: urlString) else { return false }

        fileLock.lock()
        defer { fileLock.unlock() }

        let directory = directoryURL()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent("\(key).bin")
            let temporary = directory.appendingPathComponent(
                ".\(key).\(UUID().uuidString).tmp"
            )
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: temporary
                )
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }

            var entries = readIndex(in: directory)
            entries.removeAll { $0.key == key || $0.url == urlString }
            entries.append(CacheEntry(
                key: key,
                url: urlString,
                bytes: data.count,
                lastAccess: .now
            ))

            while entries.count > maximumEntries
                    || entries.reduce(0, { $0 + $1.bytes }) > maximumBytes {
                guard let victim = entries.min(by: { $0.lastAccess < $1.lastAccess }) else {
                    break
                }
                entries.removeAll { $0.key == victim.key }
                if victim.key != key {
                    try? FileManager.default.removeItem(
                        at: directory.appendingPathComponent("\(victim.key).bin")
                    )
                }
            }

            let indexData = try JSONEncoder().encode(entries)
            try indexData.write(
                to: directory.appendingPathComponent("index.json"),
                options: .atomic
            )
            memory.set(data, forKey: key)
            return true
        } catch {
            return false
        }
    }

    public static func removeAll() {
        fileLock.lock()
        defer { fileLock.unlock() }
        memory.removeAll()
        try? FileManager.default.removeItem(at: directoryURL())
    }

    public static func remember(_ data: Data, forKey key: String) {
        memory.set(data, forKey: key)
    }

    /// Changes only when the cache index changes. Renderers use this to notice
    /// a new image without decoding the same multi-megabyte snapshot data.
    public static func generation() -> String {
        let index = directoryURL().appendingPathComponent("index.json")
        let date = (try? index.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        return String(format: "%.6f", date)
    }

    private static func readIndex(in directory: URL) -> [CacheEntry] {
        let index = directory.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: index),
              let entries = try? JSONDecoder().decode([CacheEntry].self, from: data) else {
            return []
        }
        return entries.filter { entry in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(entry.key).bin").path
            )
        }
    }
}

/// Foundation's NSCache is thread-safe at run time, but it is not marked
/// Sendable. Keep the shared cache behind one small lock so Swift 6 can prove
/// that extension and app reads are safe.
private final class LockedArtworkMemory: @unchecked Sendable {
    private let cache = NSCache<NSString, NSData>()
    private let lock = NSLock()

    func object(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: key as NSString) as Data?
    }

    func set(_ data: Data, forKey key: String) {
        lock.lock()
        cache.setObject(data as NSData, forKey: key as NSString)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        cache.removeAllObjects()
        lock.unlock()
    }
}
