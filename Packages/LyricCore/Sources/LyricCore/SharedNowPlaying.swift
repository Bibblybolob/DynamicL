import Foundation

/// Snapshot published by the app into the shared app group so widgets can
/// render the live lyric line without talking to Spotify or LRCLIB themselves.
///
/// `albumImageData` remains only for one compatibility release. New snapshots
/// must use `albumImageURL` and `artworkKey`; image bytes are stored in the
/// shared file cache instead of being copied into every JSON snapshot.
public struct WidgetLyricSnapshot: Codable, Hashable, Sendable {
    public struct ScheduledLine: Codable, Hashable, Sendable {
        public let date: Date
        public let text: String
        /// The next boundary is optional for V1 snapshots. It lets karaoke
        /// and Watch renderers stop the final line at a known time in V2.
        public let endDate: Date?

        public init(date: Date, text: String, endDate: Date? = nil) {
            self.date = date
            self.text = text
            self.endDate = endDate
        }
    }

    public let trackTitle: String
    public let artistName: String
    public var albumImageURL: String?
    /// Legacy field. It is decoded for old snapshots but is never written by
    /// the app's shared store after migration.
    public var albumImageData: Data?
    public var artworkKey: String?
    public var albumDominantRGB: [Double]?
    public var trackID: String?
    public var schemaVersion: Int?
    public var revision: Int64?
    public var generatedAtEpoch: TimeInterval?
    public let currentLine: String
    public let isPlaying: Bool
    public let updatedAt: Date
    public var scheduledLines: [ScheduledLine]

    public init(
        trackTitle: String,
        artistName: String,
        albumImageURL: String? = nil,
        albumImageData: Data? = nil,
        artworkKey: String? = nil,
        albumDominantRGB: [Double]? = nil,
        trackID: String? = nil,
        schemaVersion: Int? = 2,
        revision: Int64? = nil,
        generatedAtEpoch: TimeInterval? = nil,
        currentLine: String,
        isPlaying: Bool,
        updatedAt: Date = .now,
        scheduledLines: [ScheduledLine] = []
    ) {
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.albumImageURL = albumImageURL
        self.albumImageData = albumImageData
        self.artworkKey = artworkKey ?? albumImageURL.map(Self.makeArtworkKey)
        self.albumDominantRGB = albumDominantRGB
        self.trackID = trackID
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.generatedAtEpoch = generatedAtEpoch ?? updatedAt.timeIntervalSince1970
        self.currentLine = currentLine
        self.isPlaying = isPlaying
        self.updatedAt = updatedAt
        self.scheduledLines = scheduledLines
    }

    private enum CodingKeys: String, CodingKey {
        case trackTitle, artistName, albumImageURL, albumImageData
        case artworkKey, albumDominantRGB, trackID, schemaVersion, revision
        case generatedAtEpoch, currentLine, isPlaying, updatedAt, scheduledLines
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackTitle = try container.decode(String.self, forKey: .trackTitle)
        artistName = try container.decode(String.self, forKey: .artistName)
        albumImageURL = try container.decodeIfPresent(String.self, forKey: .albumImageURL)
        albumImageData = try container.decodeIfPresent(Data.self, forKey: .albumImageData)
        artworkKey = try container.decodeIfPresent(String.self, forKey: .artworkKey)
            ?? albumImageURL.map(Self.makeArtworkKey)
        albumDominantRGB = try container.decodeIfPresent([Double].self, forKey: .albumDominantRGB)
        trackID = try container.decodeIfPresent(String.self, forKey: .trackID)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        revision = try container.decodeIfPresent(Int64.self, forKey: .revision)
        generatedAtEpoch = try container.decodeIfPresent(TimeInterval.self, forKey: .generatedAtEpoch)
        currentLine = try container.decode(String.self, forKey: .currentLine)
        isPlaying = try container.decode(Bool.self, forKey: .isPlaying)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        scheduledLines = try container.decodeIfPresent([ScheduledLine].self, forKey: .scheduledLines) ?? []
    }

    private static func makeArtworkKey(_ url: String) -> String {
        SharedNowPlaying.artworkKey(for: url)
    }
}

/// Shared app-group state and the bounded artwork repository used by the app,
/// Live Activity, widgets, and Watch. Snapshot reads do not mutate the cache.
public enum SharedNowPlaying {
    public static let appGroupID = "group.com.jonathantran.dynamicallyrics.la"
    private static let storageKey = "widgetLyricSnapshot"
    private static let artworkIndexKey = "albumArtworkCacheV2"
    private static let artworkCacheKey = "currentAlbumArtwork"
    private static let artworkURLKey = "currentAlbumArtworkURL"
    private static let artworkDataKey = "currentAlbumArtworkData"
    private static let artworkDirectoryName = "ArtworkCache"
    private static let artworkIndexFileName = "index.json"

    private static let maxArtworkEntries = 4
    private static let maxArtworkBytes = 2_000_000
    private static let artworkLock = NSLock()
    private nonisolated(unsafe) static let memoryCache = NSCache<NSString, NSData>()

    private struct LegacyArtworkCache: Codable {
        let url: String
        let data: Data
    }

    private struct ArtworkEntry: Codable {
        let url: String
        let fileName: String
        let byteCount: Int
        let savedAt: Date
    }

    private struct ArtworkIndex: Codable {
        var entries: [ArtworkEntry]
    }

    private struct OldArtworkEntry: Codable {
        let url: String
        let data: Data
        let savedAt: Date
    }

    private struct OldArtworkIndex: Codable {
        let entries: [OldArtworkEntry]
    }

    public static func save(_ snapshot: WidgetLyricSnapshot) {
        // Do not duplicate image bytes in the app-group snapshot. Existing
        // callers may still pass the legacy field during migration.
        if let url = snapshot.albumImageURL, let data = snapshot.albumImageData {
            saveArtwork(data, for: url)
        }
        var compact = snapshot
        compact.albumImageData = nil
        guard let data = try? JSONEncoder().encode(compact) else { return }
        store()?.set(data, forKey: storageKey)
    }

    public static func load() -> WidgetLyricSnapshot? {
        guard let data = store()?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WidgetLyricSnapshot.self, from: data)
    }

    public static func clear() {
        store()?.removeObject(forKey: storageKey)
        // A command can fail while its optimistic override is still in the
        // app-group mailbox. Do not let that stale flip affect the next song.
        store()?.removeObject(forKey: playingOverrideKey)
        store()?.removeObject(forKey: playingOverrideExpiryKey)
    }

    /// Removes artwork only during an explicit account reset or sign-out.
    public static func clearArtworkCache() {
        artworkLock.lock()
        defer { artworkLock.unlock() }
        memoryCache.removeAllObjects()
        guard let directory = artworkDirectory() else {
            clearLegacyArtwork(defaults: store())
            return
        }
        try? FileManager.default.removeItem(at: directory)
        clearLegacyArtwork(defaults: store())
    }

    public static func clearAll() {
        clear()
        clearArtworkCache()
    }

    /// Returns a stable, non-sensitive key for an artwork URL.
    public static func artworkKey(for urlString: String) -> String {
        // FNV-1a is sufficient here. The URL is still stored in index.json so
        // a collision is rejected before bytes are returned.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in urlString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    /// Returns artwork only when it belongs to the requested URL.
    public static func cachedArtwork(for urlString: String?) -> Data? {
        guard let urlString, !urlString.isEmpty else { return nil }
        let key = artworkKey(for: urlString)
        if let cached = memoryCache.object(forKey: key as NSString) {
            return Data(referencing: cached)
        }

        artworkLock.lock()
        defer { artworkLock.unlock() }
        if let directory = artworkDirectory(),
           let index = readFileIndex(in: directory),
           let entry = index.entries.last(where: { $0.url == urlString }),
           let data = try? Data(contentsOf: directory.appending(path: entry.fileName)),
           !data.isEmpty {
            memoryCache.setObject(data as NSData, forKey: key as NSString)
            return data
        }

        // Migrate the old UserDefaults cache on first successful access.
        guard let legacy = legacyArtwork(for: urlString, defaults: store()) else { return nil }
        saveArtworkLocked(legacy, for: urlString)
        return legacy
    }

    /// Stores artwork in a bounded app-group file cache. Metadata is changed
    /// only on writes, not on reads, so widget render loops cannot rewrite a
    /// multi-megabyte UserDefaults blob.
    public static func saveArtwork(_ data: Data, for urlString: String) {
        guard !data.isEmpty, !urlString.isEmpty, data.count <= maxArtworkBytes else { return }
        artworkLock.lock()
        defer { artworkLock.unlock() }
        saveArtworkLocked(data, for: urlString)
    }

    // MARK: Test and migration compatibility

    static func save(_ snapshot: WidgetLyricSnapshot, defaults: UserDefaults?) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: storageKey)
    }

    static func cachedArtwork(for urlString: String?, defaults: UserDefaults?) -> Data? {
        guard let urlString else { return nil }
        var entries = legacyArtworkEntries(defaults: defaults)
        if let index = entries.lastIndex(where: { $0.url == urlString }),
           !entries[index].data.isEmpty {
            if index == entries.index(before: entries.endIndex) {
                return entries[index].data
            }
            let entry = entries.remove(at: index)
            entries.append(LegacyArtworkEntry(url: entry.url, data: entry.data, savedAt: .now))
            let encodedEntries = entries.map {
                ArtworkEntry(url: $0.url, fileName: "", byteCount: $0.data.count, savedAt: $0.savedAt)
            }
            if let encoded = try? JSONEncoder().encode(ArtworkIndex(entries: encodedEntries)) {
                defaults?.set(encoded, forKey: artworkIndexKey)
            }
            return entry.data
        }
        return legacyArtwork(for: urlString, defaults: defaults)
    }

    static func saveArtwork(_ data: Data, for urlString: String, defaults: UserDefaults?) {
        guard !data.isEmpty else { return }
        var entries = legacyArtworkEntries(defaults: defaults).filter { $0.url != urlString }
        entries.append(LegacyArtworkEntry(url: urlString, data: data, savedAt: .now))
        while entries.count > maxArtworkEntries || entries.reduce(0, { $0 + $1.data.count }) > maxArtworkBytes {
            entries.removeFirst()
        }
        let encodedEntries = entries.map {
            ArtworkEntry(url: $0.url, fileName: "", byteCount: $0.data.count, savedAt: $0.savedAt)
        }
        guard let encoded = try? JSONEncoder().encode(ArtworkIndex(entries: encodedEntries)) else { return }
        defaults?.set(encoded, forKey: artworkIndexKey)
        for entry in entries {
            defaults?.set(entry.data, forKey: "albumArtworkData.\(entry.url)")
        }
        defaults?.removeObject(forKey: artworkCacheKey)
        defaults?.removeObject(forKey: artworkURLKey)
        defaults?.removeObject(forKey: artworkDataKey)
    }

    static func load(defaults: UserDefaults?) -> WidgetLyricSnapshot? {
        guard let data = defaults?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WidgetLyricSnapshot.self, from: data)
    }

    static func clear(defaults: UserDefaults?) {
        defaults?.removeObject(forKey: storageKey)
        defaults?.removeObject(forKey: playingOverrideKey)
        defaults?.removeObject(forKey: playingOverrideExpiryKey)
    }

    static func clearArtworkCache(defaults: UserDefaults?) {
        guard let defaults else { return }
        defaults.removeObject(forKey: artworkIndexKey)
        defaults.removeObject(forKey: artworkCacheKey)
        defaults.removeObject(forKey: artworkURLKey)
        defaults.removeObject(forKey: artworkDataKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("albumArtworkData.") {
            defaults.removeObject(forKey: key)
        }
    }

    static func setPlayingOverride(_ isPlaying: Bool?, defaults: UserDefaults?) {
        if let isPlaying {
            defaults?.set(isPlaying, forKey: playingOverrideKey)
            defaults?.set(Date.now.addingTimeInterval(8).timeIntervalSince1970, forKey: playingOverrideExpiryKey)
        } else {
            defaults?.removeObject(forKey: playingOverrideKey)
            defaults?.removeObject(forKey: playingOverrideExpiryKey)
        }
    }

    static func playingOverride(defaults: UserDefaults?) -> Bool? {
        guard let defaults else { return nil }
        let expiry = defaults.double(forKey: playingOverrideExpiryKey)
        if expiry > 0, Date.now.timeIntervalSince1970 >= expiry {
            defaults.removeObject(forKey: playingOverrideKey)
            defaults.removeObject(forKey: playingOverrideExpiryKey)
            return nil
        }
        return defaults.object(forKey: playingOverrideKey) as? Bool
    }

    private struct LegacyArtworkEntry {
        let url: String
        let data: Data
        let savedAt: Date
    }

    private static func legacyArtworkEntries(defaults: UserDefaults?) -> [LegacyArtworkEntry] {
        guard let data = defaults?.data(forKey: artworkIndexKey) else { return [] }
        if let index = try? JSONDecoder().decode(ArtworkIndex.self, from: data) {
            return index.entries.compactMap { entry in
                guard let data = defaults?.data(forKey: "albumArtworkData.\(entry.url)"), !data.isEmpty else { return nil }
                return LegacyArtworkEntry(url: entry.url, data: data, savedAt: entry.savedAt)
            }
        }
        // Decode the previous single-UserDefaults blob so the first V2 read
        // can migrate it to files without losing the user's recent artwork.
        if let old = try? JSONDecoder().decode(OldArtworkIndex.self, from: data) {
            return old.entries.map { LegacyArtworkEntry(url: $0.url, data: $0.data, savedAt: $0.savedAt) }
        }
        return []
    }

    private static func legacyArtwork(for urlString: String, defaults: UserDefaults?) -> Data? {
        if let entry = legacyArtworkEntries(defaults: defaults).last(where: { $0.url == urlString }) {
            return entry.data
        }
        if let encoded = defaults?.data(forKey: artworkCacheKey),
           let cache = try? JSONDecoder().decode(LegacyArtworkCache.self, from: encoded),
           cache.url == urlString, !cache.data.isEmpty {
            return cache.data
        }
        guard defaults?.string(forKey: artworkURLKey) == urlString else { return nil }
        return defaults?.data(forKey: artworkDataKey)
    }

    private static func clearLegacyArtwork(defaults: UserDefaults?) {
        clearArtworkCache(defaults: defaults)
    }

    private static func saveArtworkLocked(_ data: Data, for urlString: String) {
        guard let directory = artworkDirectory() else {
            // The app-group container is unavailable only in tests or before
            // entitlements are installed. Keep a small compatibility fallback.
            saveArtwork(data, for: urlString, defaults: store())
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(artworkKey(for: urlString)).img"
        let destination = directory.appending(path: fileName)
        let temporary = directory.appending(path: "\(fileName).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return
        }

        var entries = readFileIndex(in: directory)?.entries ?? []
        entries.removeAll { $0.url == urlString || $0.fileName == fileName }
        entries.append(ArtworkEntry(url: urlString, fileName: fileName, byteCount: data.count, savedAt: .now))
        while entries.count > maxArtworkEntries || entries.reduce(0, { $0 + $1.byteCount }) > maxArtworkBytes {
            let removed = entries.removeFirst()
            try? FileManager.default.removeItem(at: directory.appending(path: removed.fileName))
        }
        writeFileIndex(ArtworkIndex(entries: entries), in: directory)
        memoryCache.setObject(data as NSData, forKey: artworkKey(for: urlString) as NSString)
        clearLegacyArtwork(defaults: store())
    }

    private static func artworkDirectory() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        return container.appending(path: artworkDirectoryName, directoryHint: .isDirectory)
    }

    private static func readFileIndex(in directory: URL) -> ArtworkIndex? {
        let url = directory.appending(path: artworkIndexFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ArtworkIndex.self, from: data)
    }

    private static func writeFileIndex(_ index: ArtworkIndex, in directory: URL) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        let destination = directory.appending(path: artworkIndexFileName)
        try? data.write(to: destination, options: .atomic)
    }

    private static let playingOverrideKey = "widgetPlayingOverride"
    private static let playingOverrideExpiryKey = "widgetPlayingOverrideExpiresAt"

    public static func setPlayingOverride(_ isPlaying: Bool?) {
        setPlayingOverride(isPlaying, defaults: store())
    }

    public static func playingOverride() -> Bool? {
        playingOverride(defaults: store())
    }

    private static func store() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
}

/// Async facade for artwork reads and writes.
///
/// Widget rendering can still use the synchronous compatibility methods, but
/// app and Watch coordination can call this actor so file I/O is not performed
/// on their main actors.
public actor ArtworkRepository {
    public static let shared = ArtworkRepository()

    public init() {}

    public func data(for urlString: String?) -> Data? {
        SharedNowPlaying.cachedArtwork(for: urlString)
    }

    public func save(_ data: Data, for urlString: String) {
        SharedNowPlaying.saveArtwork(data, for: urlString)
    }

    public func clear() {
        SharedNowPlaying.clearArtworkCache()
    }
}
