import Foundation
#if canImport(Darwin)
import Darwin
#endif

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
    /// The signed user timing adjustment used to build the schedule. Keep it
    /// in the shared snapshot so Watch can detect an offset change even when
    /// the visible lyric text has not changed yet.
    public var lyricOffsetMs: Int?
    /// Track duration in seconds. Widgets use this to schedule an explicit
    /// idle entry when the phone is suspended at the end of a song.
    public var trackDuration: TimeInterval?
    /// Predicted track end on the shared wall clock. It is nil while paused.
    public var playbackEndEpoch: TimeInterval?
    /// Wall-clock playback anchor used by V2 consumers. It is nil while
    /// paused and remains stable while a playing schedule is active.
    public var playbackAnchorEpoch: TimeInterval?
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
        lyricOffsetMs: Int? = nil,
        trackDuration: TimeInterval? = nil,
        playbackEndEpoch: TimeInterval? = nil,
        playbackAnchorEpoch: TimeInterval? = nil,
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
        self.lyricOffsetMs = lyricOffsetMs
        self.trackDuration = trackDuration
        self.playbackEndEpoch = playbackEndEpoch
        self.playbackAnchorEpoch = playbackAnchorEpoch
        self.currentLine = currentLine
        self.isPlaying = isPlaying
        self.updatedAt = updatedAt
        self.scheduledLines = scheduledLines
    }

    private enum CodingKeys: String, CodingKey {
        case trackTitle, artistName, albumImageURL, albumImageData
        case artworkKey, albumDominantRGB, trackID, schemaVersion, revision
        case generatedAtEpoch, lyricOffsetMs, trackDuration, playbackEndEpoch
        case playbackAnchorEpoch
        case currentLine, isPlaying, updatedAt, scheduledLines
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
        lyricOffsetMs = try container.decodeIfPresent(Int.self, forKey: .lyricOffsetMs)
        trackDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .trackDuration)
        playbackEndEpoch = try container.decodeIfPresent(TimeInterval.self, forKey: .playbackEndEpoch)
        playbackAnchorEpoch = try container.decodeIfPresent(TimeInterval.self, forKey: .playbackAnchorEpoch)
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
    static let storageKeyV2 = "sharedPlaybackSnapshotV2"
    private static let watchStorageKey = "watchLyricSnapshot"
    private static let artworkIndexKey = "albumArtworkCacheV2"
    private static let artworkCacheKey = "currentAlbumArtwork"
    private static let artworkURLKey = "currentAlbumArtworkURL"
    private static let artworkDataKey = "currentAlbumArtworkData"
    private static let artworkDirectoryName = "ArtworkCache"
    private static let artworkIndexFileName = "index.json"

    private static let maxArtworkEntries = 4
    private static let maxArtworkBytes = 2_000_000
    private static let artworkLock = NSLock()
    private static let requestLock = NSLock()
    /// Changes whenever the process stores new artwork. The Watch sender uses
    /// this small in-memory generation to notice that a cover became
    /// available after the first packet for a track was already delivered.
    /// It avoids probing the disk cache on every model tick.
    private nonisolated(unsafe) static var artworkGeneration: UInt64 = 0
    /// A failed legacy lookup must not decode the old UserDefaults artwork
    /// index on every widget or Live Activity render while a new cover is
    /// downloading. Successful writes remove the key, so a later cache hit
    /// still works normally.
    private nonisolated(unsafe) static var legacyArtworkMisses: Set<String> = []
    /// Keep the in-process cache bounded as well as the on-disk cache. The
    /// widget and Live Activity extensions may stay alive for many track
    /// changes; an unbounded NSCache retains one Data object per album URL and
    /// can create memory pressure that looks like a frozen surface.
    private nonisolated(unsafe) static let memoryCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = maxArtworkEntries
        cache.totalCostLimit = maxArtworkBytes
        return cache
    }()

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
        SharedPlaybackSnapshotV2Store.saveWidget(
            compact,
            defaults: store()
        )
    }

    /// Stores a snapshot for the Watch app and Watch widgets.
    ///
    /// The Watch receives state from the phone, but it must not write that
    /// state into the phone/widget snapshot. A delayed Watch packet could
    /// otherwise roll back the phone's current track or clear it when the
    /// Watch reaches an old track end boundary.
    public static func saveWatch(_ snapshot: WidgetLyricSnapshot) {
        if let url = snapshot.albumImageURL, let data = snapshot.albumImageData {
            saveArtwork(data, for: url)
        }
        var compact = snapshot
        compact.albumImageData = nil
        guard let data = try? JSONEncoder().encode(compact) else { return }
        store()?.set(data, forKey: watchStorageKey)
    }

    public static func load() -> WidgetLyricSnapshot? {
        if let data = store()?.data(forKey: storageKey),
           let snapshot = try? JSONDecoder().decode(WidgetLyricSnapshot.self, from: data) {
            return migrateLegacyArtworkToFiles(in: snapshot, storageKey: storageKey)
        }
        return SharedPlaybackSnapshotV2Store.load().map(Self.widgetSnapshot(from:))
    }

    public static func loadWatch() -> WidgetLyricSnapshot? {
        guard let data = store()?.data(forKey: watchStorageKey) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(WidgetLyricSnapshot.self, from: data) else {
            return nil
        }
        return migrateLegacyArtworkToFiles(in: snapshot, storageKey: watchStorageKey)
    }

    /// Converts the compact V2 contract to the V1 renderer shape during the
    /// migration release. New writers publish both formats; this fallback
    /// lets a newly installed extension recover when only V2 is available.
    private static func widgetSnapshot(from snapshot: SharedPlaybackSnapshotV2)
        -> WidgetLyricSnapshot {
        let updatedAt = Date(timeIntervalSince1970: snapshot.generatedAtEpoch)
        return WidgetLyricSnapshot(
            trackTitle: snapshot.trackTitle,
            artistName: snapshot.artistName,
            albumImageURL: snapshot.albumImageURL,
            artworkKey: snapshot.artworkKey,
            albumDominantRGB: snapshot.dominantRGB,
            trackID: snapshot.trackID,
            schemaVersion: snapshot.schemaVersion,
            revision: snapshot.revision,
            generatedAtEpoch: snapshot.generatedAtEpoch,
            lyricOffsetMs: Int((snapshot.lyricOffsetSeconds * 1_000).rounded()),
            trackDuration: snapshot.trackDurationSeconds,
            playbackEndEpoch: snapshot.playbackEndEpoch,
            playbackAnchorEpoch: snapshot.playbackAnchorEpoch,
            currentLine: snapshot.currentLine,
            isPlaying: snapshot.isPlaying,
            updatedAt: updatedAt,
            scheduledLines: snapshot.lyricIntervals.map {
                .init(
                    date: Date(timeIntervalSince1970: $0.startEpoch),
                    text: $0.text,
                    endDate: $0.endEpoch.map(Date.init(timeIntervalSince1970:))
                )
            }
        )
    }

    public static func clear() {
        guard let defaults = store() else { return }
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: storageKeyV2)
        // A command can fail while its optimistic override is still in the
        // app-group mailbox. Do not let that stale flip affect the next song.
        defaults.removeObject(forKey: playingOverrideKey)
        defaults.removeObject(forKey: playingOverrideExpiryKey)
        defaults.removeObject(forKey: playingOverrideTrackKey)
    }

    /// Removes one-shot requests only during an explicit account reset or
    /// disconnect. Ordinary playback cleanup must preserve a pending
    /// first-use Live Activity action while Spotify authentication completes.
    public static func clearPendingRequests() {
        guard let defaults = store() else { return }
        requestLock.lock()
        defaults.removeObject(forKey: localSessionRequestKey)
        defaults.removeObject(forKey: localSessionRequestActivityIDKey)
        defaults.removeObject(forKey: liveActivityControlRequestKey)
        defaults.removeObject(forKey: liveActivityControlRequestDateKey)
        defaults.removeObject(forKey: liveActivityEnableRequestKey)
        requestLock.unlock()
    }

    public static func clearWatch() {
        store()?.removeObject(forKey: watchStorageKey)
    }

    /// Removes artwork only during an explicit account reset or sign-out.
    public static func clearArtworkCache() {
        artworkLock.lock()
        defer { artworkLock.unlock() }
        memoryCache.removeAllObjects()
        legacyArtworkMisses.removeAll()
        withArtworkFileLock {
            guard let directory = artworkDirectory() else { return }
            // Keep the shared lock file in place. Removing the directory while
            // another process has the lock open can fail with a non-empty
            // directory error and leave a mixture of old index and image files.
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for item in contents where item.lastPathComponent != ".lock" {
                try? FileManager.default.removeItem(at: item)
            }
        }
        clearLegacyArtwork(defaults: store())
    }

    public static func clearAll() {
        clear()
        clearPendingRequests()
        clearArtworkCache()
        resetLiveActivityFirstUse()
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
        // The file name uses a compact hash, but the process cache must use
        // the complete URL. A hash collision must never return another
        // track's artwork before the file index can verify ownership.
        let memoryKey = urlString as NSString
        if let cached = memoryCache.object(forKey: memoryKey) {
            return Data(referencing: cached)
        }

        artworkLock.lock()
        defer { artworkLock.unlock() }
        return withArtworkFileLock {
            if let directory = artworkDirectory(),
               let index = readFileIndex(in: directory),
               let entry = index.entries.last(where: { $0.url == urlString }),
               let data = try? Data(contentsOf: directory.appending(path: entry.fileName)),
               !data.isEmpty {
                memoryCache.setObject(data as NSData, forKey: memoryKey, cost: data.count)
                return data
            }

            // Migrate the old UserDefaults cache on first successful access.
            // Cache misses for this URL because this function is called from
            // hot render paths while artwork is being fetched. Without this
            // guard, every 250-ms app tick could decode the old multi-megabyte
            // index again.
            guard !legacyArtworkMisses.contains(urlString) else { return nil }
            guard let legacy = legacyArtwork(for: urlString, defaults: store()) else {
                legacyArtworkMisses.insert(urlString)
                return nil
            }
            // Migrate the complete legacy set in one locked operation. A
            // previous implementation wrote only the requested image and
            // then deleted the legacy index, which silently discarded the
            // other recent covers and caused a music-note fallback after a
            // later track change.
            _ = migrateLegacyArtworkLocked(
                preferred: LegacyArtworkEntry(url: urlString, data: legacy, savedAt: .now),
                defaults: store()
            )
            return legacy
        }
    }

    /// Stores artwork in a bounded app-group file cache. Metadata is changed
    /// only on writes, not on reads, so widget render loops cannot rewrite a
    /// multi-megabyte UserDefaults blob.
    public static func saveArtwork(_ data: Data, for urlString: String) {
        guard !data.isEmpty, !urlString.isEmpty, data.count <= maxArtworkBytes else { return }
        artworkLock.lock()
        defer { artworkLock.unlock() }
        withArtworkFileLock {
            // If a user is upgraded while the old UserDefaults cache still
            // exists, carry every valid recent image into the file cache. Do
            // not let saving the current image erase covers for other tracks.
            _ = migrateLegacyArtworkLocked(
                preferred: LegacyArtworkEntry(url: urlString, data: data, savedAt: .now),
                defaults: store()
            )
        }
    }

    /// A process-local cache version for consumers that need to distinguish a
    /// valid cache miss from a later asynchronous artwork write.
    public static func artworkCacheGeneration() -> UInt64 {
        artworkLock.lock()
        defer { artworkLock.unlock() }
        return artworkGeneration
    }

    // MARK: Test and migration compatibility

    static func save(_ snapshot: WidgetLyricSnapshot, defaults: UserDefaults?) {
        if let url = snapshot.albumImageURL, let imageData = snapshot.albumImageData {
            saveArtwork(imageData, for: url, defaults: defaults)
        }
        var compact = snapshot
        compact.albumImageData = nil
        guard let data = try? JSONEncoder().encode(compact) else { return }
        defaults?.set(data, forKey: storageKey)
        SharedPlaybackSnapshotV2Store.saveWidget(compact, defaults: defaults)
    }

    static func saveWatch(_ snapshot: WidgetLyricSnapshot, defaults: UserDefaults?) {
        if let url = snapshot.albumImageURL, let imageData = snapshot.albumImageData {
            saveArtwork(imageData, for: url, defaults: defaults)
        }
        var compact = snapshot
        compact.albumImageData = nil
        guard let data = try? JSONEncoder().encode(compact) else { return }
        defaults?.set(data, forKey: watchStorageKey)
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
        saveArtworkLegacyLocked(data, for: urlString, defaults: defaults)
    }

    /// Writes the compatibility UserDefaults cache without taking the
    /// production artwork lock. The production file-backed path can call this
    /// helper while `artworkLock` is already held when the app-group container
    /// is not available. Re-entering `saveArtwork` there would deadlock the
    /// caller and present as a frozen widget or Live Activity.
    private static func saveArtworkLegacyLocked(
        _ data: Data,
        for urlString: String,
        defaults: UserDefaults?
    ) {
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
        guard let snapshot = try? JSONDecoder().decode(WidgetLyricSnapshot.self, from: data) else {
            return nil
        }
        return migrateLegacyArtwork(in: snapshot, defaults: defaults, storageKey: storageKey)
    }

    static func loadWatch(defaults: UserDefaults?) -> WidgetLyricSnapshot? {
        guard let data = defaults?.data(forKey: watchStorageKey) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(WidgetLyricSnapshot.self, from: data) else {
            return nil
        }
        return migrateLegacyArtwork(in: snapshot, defaults: defaults, storageKey: watchStorageKey)
    }

    static func clear(defaults: UserDefaults?) {
        defaults?.removeObject(forKey: storageKey)
        defaults?.removeObject(forKey: playingOverrideKey)
        defaults?.removeObject(forKey: playingOverrideExpiryKey)
        defaults?.removeObject(forKey: playingOverrideTrackKey)
    }

    static func clearPendingRequests(defaults: UserDefaults?) {
        guard let defaults else { return }
        requestLock.lock()
        defaults.removeObject(forKey: localSessionRequestKey)
        defaults.removeObject(forKey: localSessionRequestActivityIDKey)
        defaults.removeObject(forKey: liveActivityControlRequestKey)
        defaults.removeObject(forKey: liveActivityControlRequestDateKey)
        defaults.removeObject(forKey: liveActivityEnableRequestKey)
        requestLock.unlock()
    }

    static func clearAll(defaults: UserDefaults?) {
        clear(defaults: defaults)
        clearPendingRequests(defaults: defaults)
        clearArtworkCache(defaults: defaults)
        resetLiveActivityFirstUse(defaults: defaults)
    }

    static func clearWatch(defaults: UserDefaults?) {
        defaults?.removeObject(forKey: watchStorageKey)
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

    static func setPlayingOverride(
        _ isPlaying: Bool?,
        trackID: String? = nil,
        defaults: UserDefaults?
    ) {
        if let isPlaying {
            defaults?.set(isPlaying, forKey: playingOverrideKey)
            defaults?.set(Date.now.addingTimeInterval(8).timeIntervalSince1970, forKey: playingOverrideExpiryKey)
            if let trackID, !trackID.isEmpty {
                defaults?.set(trackID, forKey: playingOverrideTrackKey)
            } else {
                // A missing identity is valid for legacy snapshots. In that
                // case the short-lived override remains global for one
                // compatibility window instead of becoming unusable.
                defaults?.removeObject(forKey: playingOverrideTrackKey)
            }
        } else {
            defaults?.removeObject(forKey: playingOverrideKey)
            defaults?.removeObject(forKey: playingOverrideExpiryKey)
            defaults?.removeObject(forKey: playingOverrideTrackKey)
        }
    }

    static func playingOverride(defaults: UserDefaults?) -> Bool? {
        guard let defaults else { return nil }
        let expiry = defaults.double(forKey: playingOverrideExpiryKey)
        if expiry > 0, Date.now.timeIntervalSince1970 >= expiry {
            defaults.removeObject(forKey: playingOverrideKey)
            defaults.removeObject(forKey: playingOverrideExpiryKey)
            defaults.removeObject(forKey: playingOverrideTrackKey)
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

    /// Migrates the one-release compatibility field out of the shared
    /// snapshot. Old builds stored image bytes beside every lyric update;
    /// leaving those bytes in place would make every widget and Live Activity
    /// read decode a potentially multi-megabyte UserDefaults value. The
    /// migrated return value is also compact, so the current render never
    /// needs to hold the legacy blob after this read.
    private static func migrateLegacyArtwork(
        in snapshot: WidgetLyricSnapshot,
        defaults: UserDefaults?,
        storageKey: String
    ) -> WidgetLyricSnapshot {
        guard snapshot.albumImageData != nil else { return snapshot }

        if let url = snapshot.albumImageURL,
           let imageData = snapshot.albumImageData {
            saveArtwork(imageData, for: url, defaults: defaults)
        }

        var compact = snapshot
        compact.albumImageData = nil
        if let data = try? JSONEncoder().encode(compact) {
            defaults?.set(data, forKey: storageKey)
        }
        return compact
    }

    /// Production counterpart to the UserDefaults compatibility helper above.
    /// The overload with `defaults:` is intentionally kept for package tests,
    /// but must never be used by the app-group reader: writing image bytes back
    /// to UserDefaults would recreate the multi-megabyte decode cost that this
    /// file-backed cache is meant to remove.
    private static func migrateLegacyArtworkToFiles(
        in snapshot: WidgetLyricSnapshot,
        storageKey: String
    ) -> WidgetLyricSnapshot {
        guard snapshot.albumImageData != nil else { return snapshot }

        if let url = snapshot.albumImageURL,
           let imageData = snapshot.albumImageData {
            saveArtwork(imageData, for: url)
        }

        var compact = snapshot
        compact.albumImageData = nil
        if let data = try? JSONEncoder().encode(compact) {
            store()?.set(data, forKey: storageKey)
        }
        return compact
    }

    @discardableResult
    private static func saveArtworkLocked(
        _ data: Data,
        for urlString: String,
        clearLegacy: Bool = true
    ) -> Bool {
        guard !data.isEmpty, !urlString.isEmpty, data.count <= maxArtworkBytes else {
            return false
        }
        guard let directory = artworkDirectory() else {
            // The app-group container is unavailable only in tests or before
            // entitlements are installed. Keep a small compatibility fallback.
            saveArtworkLegacyLocked(data, for: urlString, defaults: store())
            legacyArtworkMisses.remove(urlString)
            artworkGeneration &+= 1
            return true
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
            return false
        }

        var entries = readFileIndex(in: directory)?.entries ?? []
        entries.removeAll { $0.url == urlString || $0.fileName == fileName }
        entries.append(ArtworkEntry(url: urlString, fileName: fileName, byteCount: data.count, savedAt: .now))
        var evictedEntries: [ArtworkEntry] = []
        while entries.count > maxArtworkEntries || entries.reduce(0, { $0 + $1.byteCount }) > maxArtworkBytes {
            evictedEntries.append(entries.removeFirst())
        }
        // Keep the legacy fallback until the new index is durable. The image
        // file may already exist, but consumers cannot find it without the
        // index. Clearing the fallback at this point would turn a recoverable
        // write error into a missing-album placeholder.
        guard writeFileIndex(ArtworkIndex(entries: entries), in: directory) else {
            return false
        }
        // Do not remove files until the index points at the new complete set.
        // If the atomic index write failed, the previous index can still read
        // every old file and the newly written file can be recovered on retry.
        for removed in evictedEntries {
            try? FileManager.default.removeItem(at: directory.appending(path: removed.fileName))
            memoryCache.removeObject(forKey: removed.url as NSString)
        }
        memoryCache.setObject(data as NSData, forKey: urlString as NSString, cost: data.count)
        legacyArtworkMisses.remove(urlString)
        artworkGeneration &+= 1
        if clearLegacy {
            clearLegacyArtwork(defaults: store())
        }
        return true
    }

    /// Migrates all still-valid images from the old UserDefaults cache while
    /// the caller holds both the process and file locks. The preferred entry
    /// is the image just received from Spotify and replaces any old copy for
    /// the same URL. Keep the legacy cache until every entry is represented in
    /// the new bounded cache; a failed file write must not create a missing
    /// artwork placeholder.
    @discardableResult
    private static func migrateLegacyArtworkLocked(
        preferred: LegacyArtworkEntry,
        defaults: UserDefaults?
    ) -> Bool {
        var entries = legacyArtworkEntries(defaults: defaults)
        entries.removeAll { $0.url == preferred.url }
        entries.append(preferred)

        let migrated = entries.allSatisfy { entry in
            saveArtworkLocked(entry.data, for: entry.url, clearLegacy: false)
        }
        if migrated {
            clearLegacyArtwork(defaults: defaults)
        }
        return migrated
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

    @discardableResult
    private static func writeFileIndex(_ index: ArtworkIndex, in directory: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(index) else { return false }
        let destination = directory.appending(path: artworkIndexFileName)
        do {
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// NSLock protects calls inside one process only. The app and widget
    /// extension are separate processes, so they also need a lock file in the
    /// shared app-group container. The index remains atomically written, but
    /// this lock prevents a read/delete race from returning a missing album or
    /// one writer from replacing another writer's index update.
    private static func withArtworkFileLock<T>(_ body: () throws -> T) rethrows -> T {
#if canImport(Darwin)
        guard let directory = artworkDirectory() else { return try body() }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let lockURL = directory.appending(path: ".lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return try body() }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else { return try body() }
        return try body()
#else
        return try body()
#endif
    }

    private static let playingOverrideKey = "widgetPlayingOverride"
    private static let playingOverrideExpiryKey = "widgetPlayingOverrideExpiresAt"
    /// The Spotify item ID that received the optimistic play/pause command.
    /// A command must not predict the state of a different track after a
    /// rapid skip. Missing IDs remain supported for legacy snapshots.
    private static let playingOverrideTrackKey = "widgetPlayingOverrideTrackID"
    private static let localSessionRequestKey = "localLyricsSessionRequested"
    private static let localSessionRequestActivityIDKey = "localLyricsSessionRequestedActivityID"
    private static let liveActivityControlRequestKey = "liveActivityControlRequested"
    private static let liveActivityControlRequestDateKey = "liveActivityControlRequestedAt"
    private static let liveActivityControlEnabledKey = "liveActivityControlEnabled"
    private static let liveActivityEnableRequestKey = "liveActivityEnableRequested"
    private static let liveActivityFirstUseCompletedKey = "liveActivityFirstUseCompleted"
    private static let liveActivityFirstUseActivityIDKey = "liveActivityFirstUseActivityID"
    /// Spotify authorization can require a trip through the Spotify app. Keep
    /// the one-shot Show Lyrics handoff alive long enough for that round trip,
    /// but still discard an abandoned request instead of starting a later
    /// playback session unexpectedly.
    private static let localSessionRequestTTL: TimeInterval = 120

    public static func setPlayingOverride(_ isPlaying: Bool?, trackID: String? = nil) {
        setPlayingOverride(isPlaying, trackID: trackID, defaults: store())
    }

    public static func playingOverride() -> Bool? {
        playingOverride(defaults: store())
    }

    /// Returns the playback state that shared surfaces should display while a
    /// widget or Live Activity command is waiting for Spotify to confirm it.
    /// The override is short-lived and automatically falls back to the
    /// snapshot state when it expires.
    public static func effectiveIsPlaying(_ snapshot: WidgetLyricSnapshot,
                                           defaults: UserDefaults? = nil) -> Bool {
        let defaults = defaults ?? store()
        guard let override = playingOverride(defaults: defaults) else {
            return snapshot.isPlaying
        }
        guard let defaults,
              let overrideTrackID = defaults.string(forKey: playingOverrideTrackKey),
              let snapshotTrackID = snapshot.trackID,
              !overrideTrackID.isEmpty,
              !snapshotTrackID.isEmpty else {
            // Legacy state without an identity is still honored until the
            // eight-second compatibility window expires.
            return override
        }
        return overrideTrackID == snapshotTrackID ? override : snapshot.isPlaying
    }

    /// Returns the end of the short optimistic command window. Widget
    /// timelines use this as a refresh boundary so a failed or unanswered
    /// command cannot remain visible after its override expires.
    public static func playingOverrideExpiration() -> Date? {
        guard let defaults = store() else { return nil }
        let expiry = defaults.double(forKey: playingOverrideExpiryKey)
        return expiry > 0 ? Date(timeIntervalSince1970: expiry) : nil
    }

    /// Requests that the main app start the phone-owned lyric session. This is
    /// used by the iOS 18 Control Center control and by Shortcuts. The request
    /// is one-shot and expires quickly so an old control tap cannot restart a
    /// later playback session.
    public static func requestLocalSessionStart(at date: Date = .now,
                                                activityID: String? = nil,
                                                defaults: UserDefaults? = nil) {
        guard let defaults = defaults ?? store() else { return }
        requestLock.lock()
        defaults.set(date.timeIntervalSince1970, forKey: localSessionRequestKey)
        if let activityID, !activityID.isEmpty {
            defaults.set(activityID, forKey: localSessionRequestActivityIDKey)
        } else {
            // Control Center and Shortcuts can start a session without an
            // existing Activity. Do not reuse the binding from an older tap.
            defaults.removeObject(forKey: localSessionRequestActivityIDKey)
        }
        requestLock.unlock()
    }

    /// Stores the last state of the iOS 18 Control Center quick switch. The
    /// value is separate from the one-shot request so Control Center can show
    /// the current state without starting the app.
    public static func liveActivityControlEnabled(defaults: UserDefaults? = nil) -> Bool {
        (defaults ?? store())?.bool(forKey: liveActivityControlEnabledKey) ?? false
    }

    public static func setLiveActivityControlEnabled(_ enabled: Bool,
                                                       defaults: UserDefaults? = nil) {
        (defaults ?? store())?.set(enabled, forKey: liveActivityControlEnabledKey)
    }

    /// Requests a state change from the iOS 18 Control Center quick switch.
    /// The app consumes it on its main ticker, where it can start or end the
    /// Activity and update Spotify ownership in one serialized path.
    public static func requestLiveActivityControl(_ enabled: Bool,
                                                   at date: Date = .now,
                                                   defaults: UserDefaults? = nil) {
        guard let defaults = defaults ?? store() else { return }
        requestLock.lock()
        defaults.set(enabled, forKey: liveActivityControlRequestKey)
        defaults.set(date.timeIntervalSince1970, forKey: liveActivityControlRequestDateKey)
        requestLock.unlock()
    }

    /// Consumes one fresh Control Center state change. Old requests must not
    /// turn the Live Activity back on after a later playback session starts.
    public static func consumeLiveActivityControlRequest(now: Date = .now,
                                                         defaults: UserDefaults? = nil) -> Bool? {
        guard let defaults = defaults ?? store() else { return nil }
        requestLock.lock()
        defer { requestLock.unlock() }
        let requestedAt = defaults.double(forKey: liveActivityControlRequestDateKey)
        let value = defaults.object(forKey: liveActivityControlRequestKey) as? Bool
        defaults.removeObject(forKey: liveActivityControlRequestDateKey)
        defaults.removeObject(forKey: liveActivityControlRequestKey)
        guard requestedAt > 0, let value else { return nil }
        let age = now.timeIntervalSince1970 - requestedAt
        guard age >= -5, age <= 30 else { return nil }
        return value
    }

    /// Checks for a still-valid local-session request without consuming it.
    /// The app uses this before starting an authentication flow because the
    /// first-use Live Activity action may open OpenLyrics before Spotify is
    /// connected. The request remains available for the next app tick after
    /// authentication completes.
    public static func hasLocalSessionStartRequest(now: Date = .now,
                                                    defaults: UserDefaults? = nil) -> Bool {
        guard let defaults = defaults ?? store() else { return false }
        requestLock.lock()
        defer { requestLock.unlock() }
        let requestedAt = defaults.double(forKey: localSessionRequestKey)
        guard requestedAt > 0 else { return false }
        let age = now.timeIntervalSince1970 - requestedAt
        if age > localSessionRequestTTL {
            defaults.removeObject(forKey: localSessionRequestKey)
            defaults.removeObject(forKey: localSessionRequestActivityIDKey)
            return false
        }
        return age >= -5
    }

    /// Cancels a pending local-session request after an explicit user action,
    /// such as turning the Live Activity control off. This is intentionally
    /// separate from the identity-checked consume operation.
    public static func discardLocalSessionStartRequest(defaults: UserDefaults? = nil) {
        guard let defaults = defaults ?? store() else { return }
        requestLock.lock()
        defaults.removeObject(forKey: localSessionRequestKey)
        defaults.removeObject(forKey: localSessionRequestActivityIDKey)
        requestLock.unlock()
    }

    /// Returns the timestamp for the current local-session request without
    /// consuming it. The app uses this identity to distinguish a new button
    /// press from repeated ticker passes for the same request.
    public static func localSessionStartRequestDate(now: Date = .now,
                                                     defaults: UserDefaults? = nil) -> Date? {
        guard let defaults = defaults ?? store() else { return nil }
        requestLock.lock()
        defer { requestLock.unlock() }
        let requestedAt = defaults.double(forKey: localSessionRequestKey)
        guard requestedAt > 0 else { return nil }
        let age = now.timeIntervalSince1970 - requestedAt
        guard age >= -5 && age <= localSessionRequestTTL else {
            if age > localSessionRequestTTL {
                defaults.removeObject(forKey: localSessionRequestKey)
                defaults.removeObject(forKey: localSessionRequestActivityIDKey)
            }
            return nil
        }
        return Date(timeIntervalSince1970: requestedAt)
    }

    /// Consumes a local-session request written by an extension or shortcut.
    /// The operation is protected by the shared defaults lock so two extension
    /// invocations cannot both leave a stale request behind. Requests older
    /// than two minutes are discarded because they may belong to an earlier
    /// playback session.
    public static func consumeLocalSessionStartRequest(now: Date = .now,
                                                        activityID: String? = nil,
                                                        defaults: UserDefaults? = nil) -> Bool {
        guard let defaults = defaults ?? store() else { return false }
        requestLock.lock()
        defer { requestLock.unlock() }
        let requestedAt = defaults.double(forKey: localSessionRequestKey)
        guard requestedAt > 0 else { return false }
        let age = now.timeIntervalSince1970 - requestedAt
        guard age >= -5 && age <= localSessionRequestTTL else {
            if age > localSessionRequestTTL {
                defaults.removeObject(forKey: localSessionRequestKey)
                defaults.removeObject(forKey: localSessionRequestActivityIDKey)
            }
            return false
        }

        // A Show Lyrics action belongs to the Activity that displayed the
        // button. Keep it pending while the app adopts that Activity, but
        // consume it when a different Activity is now current. This prevents
        // a delayed OAuth callback from reviving a newer card.
        if let requestedActivityID = defaults.string(forKey: localSessionRequestActivityIDKey) {
            guard let activityID else { return false }
            guard requestedActivityID == activityID else {
                defaults.removeObject(forKey: localSessionRequestKey)
                defaults.removeObject(forKey: localSessionRequestActivityIDKey)
                return false
            }
        }

        defaults.removeObject(forKey: localSessionRequestKey)
        defaults.removeObject(forKey: localSessionRequestActivityIDKey)
        return true
    }

    /// Returns true after the user has completed the handoff for the current
    /// Live Activity. Keep this in the app group so a process relaunch does
    /// not restore the first-use button while that Activity is still active.
    public static func hasCompletedLiveActivityFirstUse(defaults: UserDefaults? = nil) -> Bool {
        (defaults ?? store())?.bool(forKey: liveActivityFirstUseCompletedKey) ?? false
    }

    /// Returns true only when the explicit handoff belongs to the current
    /// Activity. A bare Boolean cannot distinguish a surviving Activity from
    /// one that iOS ended while the app process was not running.
    public static func hasCompletedLiveActivityFirstUse(
        for activityID: String?,
        defaults: UserDefaults? = nil
    ) -> Bool {
        guard let activityID, !activityID.isEmpty,
              let defaults = defaults ?? store(),
              defaults.bool(forKey: liveActivityFirstUseCompletedKey),
              let savedActivityID = defaults.string(forKey: liveActivityFirstUseActivityIDKey)
        else { return false }
        return savedActivityID == activityID
    }

    /// Records the explicit handoff. This is a small preference, not a
    /// credential. The app clears it when the Activity ends or the user
    /// disconnects the account.
    public static func markLiveActivityFirstUseCompleted(
        for activityID: String? = nil,
        defaults: UserDefaults? = nil
    ) {
        guard let defaults = defaults ?? store() else { return }
        defaults.set(true, forKey: liveActivityFirstUseCompletedKey)
        if let activityID, !activityID.isEmpty {
            defaults.set(activityID, forKey: liveActivityFirstUseActivityIDKey)
        } else {
            // Do not let a process-only completion survive as permission for
            // an unrelated Activity. The compatibility Boolean remains for
            // older callers, while app lifecycle code uses the ID overload.
            defaults.removeObject(forKey: liveActivityFirstUseActivityIDKey)
        }
    }

    public static func resetLiveActivityFirstUse(defaults: UserDefaults? = nil) {
        guard let defaults = defaults ?? store() else { return }
        defaults.removeObject(forKey: liveActivityFirstUseCompletedKey)
        defaults.removeObject(forKey: liveActivityFirstUseActivityIDKey)
    }

    /// Requests that the app enable the Live Activity and show its first-use
    /// action. This is separate from `requestLocalSessionStart`: Shortcuts and
    /// the in-app switch follow the documented first-use flow, while the
    /// Control Center quick toggle can start the local session immediately.
    public static func requestLiveActivityEnable(at date: Date = .now,
                                                 defaults: UserDefaults? = nil) {
        guard let defaults = defaults ?? store() else { return }
        requestLock.lock()
        defaults.set(date.timeIntervalSince1970, forKey: liveActivityEnableRequestKey)
        requestLock.unlock()
    }

    /// Consumes a still-valid request to enable the Live Activity. Old
    /// automation runs must not enable a later session unexpectedly.
    public static func consumeLiveActivityEnableRequest(now: Date = .now,
                                                         defaults: UserDefaults? = nil) -> Bool {
        guard let defaults = defaults ?? store() else { return false }
        requestLock.lock()
        defer { requestLock.unlock() }
        let requestedAt = defaults.double(forKey: liveActivityEnableRequestKey)
        defaults.removeObject(forKey: liveActivityEnableRequestKey)
        guard requestedAt > 0 else { return false }
        let age = now.timeIntervalSince1970 - requestedAt
        return age >= -5 && age <= 30
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
        guard let urlString else { return nil }
        return ArtworkFileCache.data(for: urlString)
    }

    public func save(_ data: Data, for urlString: String) {
        _ = ArtworkFileCache.store(data, for: urlString)
    }

    public func clear() {
        ArtworkFileCache.removeAll()
    }
}
