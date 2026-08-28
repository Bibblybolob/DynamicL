import Foundation

/// Snapshot published by the app into the shared app group so widgets can
/// render the live lyric line without talking to Spotify or LRCLIB themselves.
public struct WidgetLyricSnapshot: Codable, Hashable, Sendable {
    /// A lyric line scheduled to become "current" at an absolute point in time,
    /// precomputed by the app so the widget can lay out its own timeline.
    public struct ScheduledLine: Codable, Hashable, Sendable {
        public let date: Date
        public let text: String

        public init(date: Date, text: String) {
            self.date = date
            self.text = text
        }
    }

    public let trackTitle: String
    public let artistName: String
    public var albumImageURL: String?
    public var albumImageData: Data?
    public let currentLine: String
    public let isPlaying: Bool
    public let updatedAt: Date
    public var scheduledLines: [ScheduledLine]

    public init(
        trackTitle: String,
        artistName: String,
        albumImageURL: String? = nil,
        albumImageData: Data? = nil,
        currentLine: String,
        isPlaying: Bool,
        updatedAt: Date = .now,
        scheduledLines: [ScheduledLine] = []
    ) {
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.albumImageURL = albumImageURL
        self.albumImageData = albumImageData
        self.currentLine = currentLine
        self.isPlaying = isPlaying
        self.updatedAt = updatedAt
        self.scheduledLines = scheduledLines
    }
}

/// Reads/writes the widget snapshot through the shared app-group container.
public enum SharedNowPlaying {
    public static let appGroupID = "group.com.jonathantran.dynamicallyrics.la"
    private static let storageKey = "widgetLyricSnapshot"
    private static let artworkIndexKey = "albumArtworkCacheV2"
    private static let artworkCacheKey = "currentAlbumArtwork"
    // Read these keys for one release so users can migrate from the earlier
    // two-value cache without showing a missing image.
    private static let artworkURLKey = "currentAlbumArtworkURL"
    private static let artworkDataKey = "currentAlbumArtworkData"

    private static let maxArtworkEntries = 4
    private static let maxArtworkBytes = 2_000_000

    private struct LegacyArtworkCache: Codable {
        let url: String
        let data: Data
    }

    private struct ArtworkEntry: Codable {
        let url: String
        let data: Data
        let savedAt: Date
    }

    private struct ArtworkIndex: Codable {
        var entries: [ArtworkEntry]
    }

    public static func save(_ snapshot: WidgetLyricSnapshot) {
        save(snapshot, defaults: store())
    }

    public static func load() -> WidgetLyricSnapshot? {
        load(defaults: store())
    }

    public static func clear() {
        clear(defaults: store())
    }

    /// Removes artwork only during an explicit account reset or sign-out.
    public static func clearArtworkCache() {
        clearArtworkCache(defaults: store())
    }

    public static func clearAll() {
        clear(defaults: store())
        clearArtworkCache(defaults: store())
    }

    /// Returns artwork only when it belongs to the requested URL.
    /// This prevents a previous track's image from appearing for a new track.
    public static func cachedArtwork(for urlString: String?) -> Data? {
        cachedArtwork(for: urlString, defaults: store())
    }

    /// Stores artwork in a bounded app-group cache. The newest four images
    /// share a 2 MB limit, so recent tracks survive short data gaps.
    public static func saveArtwork(_ data: Data, for urlString: String) {
        saveArtwork(data, for: urlString, defaults: store())
    }

    static func save(_ snapshot: WidgetLyricSnapshot, defaults: UserDefaults?) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: storageKey)
    }

    static func cachedArtwork(for urlString: String?, defaults: UserDefaults?) -> Data? {
        guard let urlString else { return nil }
        var entries = artworkEntries(defaults: defaults)
        if let index = entries.lastIndex(where: { $0.url == urlString }),
           !entries[index].data.isEmpty {
            if index == entries.index(before: entries.endIndex) {
                return entries[index].data
            }
            let entry = entries.remove(at: index)
            entries.append(ArtworkEntry(url: entry.url, data: entry.data, savedAt: .now))
            if let encoded = try? JSONEncoder().encode(ArtworkIndex(entries: entries)) {
                defaults?.set(encoded, forKey: artworkIndexKey)
            }
            return entry.data
        }
        if let encoded = defaults?.data(forKey: artworkCacheKey),
           let cache = try? JSONDecoder().decode(LegacyArtworkCache.self, from: encoded),
           cache.url == urlString,
           !cache.data.isEmpty {
            return cache.data
        }
        guard defaults?.string(forKey: artworkURLKey) == urlString else { return nil }
        return defaults?.data(forKey: artworkDataKey)
    }

    static func saveArtwork(_ data: Data, for urlString: String, defaults: UserDefaults?) {
        guard !data.isEmpty else { return }
        var entries = artworkEntries(defaults: defaults).filter { $0.url != urlString }
        entries.append(ArtworkEntry(url: urlString, data: data, savedAt: .now))
        while entries.count > maxArtworkEntries || entries.reduce(0, { $0 + $1.data.count }) > maxArtworkBytes {
            entries.removeFirst()
        }
        guard let encoded = try? JSONEncoder().encode(ArtworkIndex(entries: entries)) else { return }
        // Write the complete index atomically. Readers never observe a URL
        // paired with bytes from another track.
        defaults?.set(encoded, forKey: artworkIndexKey)
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
        // A command can fail while its optimistic override is still in the
        // app-group mailbox. Do not let that stale flip affect the next song.
        defaults?.removeObject(forKey: playingOverrideKey)
    }

    static func clearArtworkCache(defaults: UserDefaults?) {
        defaults?.removeObject(forKey: artworkIndexKey)
        defaults?.removeObject(forKey: artworkCacheKey)
        defaults?.removeObject(forKey: artworkURLKey)
        defaults?.removeObject(forKey: artworkDataKey)
    }

    private static func artworkEntries(defaults: UserDefaults?) -> [ArtworkEntry] {
        guard let data = defaults?.data(forKey: artworkIndexKey),
              let index = try? JSONDecoder().decode(ArtworkIndex.self, from: data) else {
            return []
        }
        return index.entries
    }

    private static let playingOverrideKey = "widgetPlayingOverride"

    /// Optimistic play/pause flip written by the widget's App Intent so the UI
    /// reacts instantly; the app clears it once real player state arrives.
    public static func setPlayingOverride(_ isPlaying: Bool?) {
        setPlayingOverride(isPlaying, defaults: store())
    }

    public static func playingOverride() -> Bool? {
        playingOverride(defaults: store())
    }

    static func setPlayingOverride(_ isPlaying: Bool?, defaults: UserDefaults?) {
        if let isPlaying {
            defaults?.set(isPlaying, forKey: playingOverrideKey)
        } else {
            defaults?.removeObject(forKey: playingOverrideKey)
        }
    }

    static func playingOverride(defaults: UserDefaults?) -> Bool? {
        defaults?.object(forKey: playingOverrideKey) as? Bool
    }

    private static func store() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
}
