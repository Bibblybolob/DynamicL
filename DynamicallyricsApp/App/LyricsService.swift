import Foundation
import LyricCore
import os.log

private struct CachedLyrics: Codable, Sendable {
    var document: LyricsDocument
    var lastAccessedAt: Date
}

private struct PersistedLyricsEntry: Codable, Sendable {
    var signature: TrackSignature
    var document: LyricsDocument
    var lastAccessedAt: Date
}

private struct PersistedLyricsCache: Codable, Sendable {
    var version: Int
    var entries: [PersistedLyricsEntry]
}

private enum LyricsCacheStore {
    private static let version = 1
    private static let maxEntries = 100
    private static let maxBytes = 2_000_000
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private static var fileURL: URL? {
        guard let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else { return nil }

        return applicationSupport
            .appendingPathComponent("Dynamicallyrics", isDirectory: true)
            .appendingPathComponent("lyrics-cache.json")
    }

    static func load() -> [TrackSignature: CachedLyrics] {
        guard let fileURL else { return [:] }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persisted = try decoder.decode(PersistedLyricsCache.self, from: data)
            guard persisted.version == version else { return [:] }

            let cutoff = Date().addingTimeInterval(-maxAge)
            var cache: [TrackSignature: CachedLyrics] = [:]
            for entry in persisted.entries {
                guard entry.lastAccessedAt >= cutoff else { continue }
                cache[entry.signature] = CachedLyrics(
                    document: entry.document,
                    lastAccessedAt: entry.lastAccessedAt
                )
            }
            return cache
        } catch {
            // A corrupt cache should never prevent lyrics lookup from working.
            return [:]
        }
    }

    static func save(_ cache: [TrackSignature: CachedLyrics]) {
        guard let fileURL else { return }

        var entries = cache.map { signature, cached in
            PersistedLyricsEntry(
                signature: signature,
                document: cached.document,
                lastAccessedAt: cached.lastAccessedAt
            )
        }
        entries.sort { $0.lastAccessedAt > $1.lastAccessedAt }
        entries = Array(entries.prefix(maxEntries))

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            var data = try encoder.encode(PersistedLyricsCache(version: version, entries: entries))
            while data.count > maxBytes && entries.count > 1 {
                entries.removeLast()
                data = try encoder.encode(PersistedLyricsCache(version: version, entries: entries))
            }

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DiagnosticsLog.append("lyrics cache write failed")
        }
    }
}

/// Serializes disk work away from the main actor and coalesces writes caused
/// by rapid track changes.
private actor LyricsCacheRepository {
    static let shared = LyricsCacheRepository()
    private var writeTask: Task<Void, Never>?

    func load() async -> [TrackSignature: CachedLyrics] {
        await Task.detached(priority: .utility) {
            LyricsCacheStore.load()
        }.value
    }

    func save(_ cache: [TrackSignature: CachedLyrics]) {
        writeTask?.cancel()
        writeTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            LyricsCacheStore.save(cache)
        }
    }
}

/// Fetches and caches lyrics documents, feeding the sync engine on track changes.
@MainActor
@Observable
final class LyricsService {
    private static let log = Logger(subsystem: "com.jonathantran.dynamicallyrics", category: "Lyrics")
    private(set) var document: LyricsDocument?
    private(set) var isLoading = false
    private(set) var currentIndex: Int?
    private(set) var displayPosition: TimeInterval = 0
    /// Human-readable reason the current track has no lyrics (nil when fine).
    private(set) var lookupStatus: String?
    /// True while a fetch is in flight OR a retry is scheduled — i.e. lyrics
    /// may still arrive for this track. Distinct from isLoading so callers can
    /// avoid treating a retrying lookup as a final "no lyrics".
    private(set) var isAwaitingLyrics = false

    var userOffset: TimeInterval {
        get { engine.userOffset }
        set {
            let bounded = min(10, max(-10, newValue.isFinite ? newValue : 0))
            engine.userOffset = bounded
            UserDefaults(suiteName: SharedNowPlaying.appGroupID)?.set(bounded, forKey: Self.userOffsetKey)
        }
    }

    private static let userOffsetKey = "lyricsUserOffsetSeconds"

    let engine = SyncEngine()

    private var cache: [TrackSignature: CachedLyrics]
    private var failedSignatures: Set<TrackSignature> = []
    private var loadTask: Task<Void, Never>?
    private var currentSignature: TrackSignature?
    /// Stable identity for the lookup that owns the visible document. Spotify
    /// track IDs take precedence over text metadata so a late request for an
    /// earlier item cannot restore its lyrics after a skip to a different item
    /// with the same title and artist.
    private var currentLookupKey: String?
    private var lookupGeneration: UInt64 = 0
    private var retryTask: Task<Void, Never>?
    private var cacheLoadTask: Task<Void, Never>?

    init() {
        cache = [:]
        let savedOffset = UserDefaults(suiteName: SharedNowPlaying.appGroupID)?
            .double(forKey: Self.userOffsetKey) ?? 0
        engine.userOffset = min(10, max(-10, savedOffset.isFinite ? savedOffset : 0))
        cacheLoadTask = Task { [weak self] in
            let loaded = await LyricsCacheRepository.shared.load()
            guard !Task.isCancelled, let self else { return }
            for (signature, cached) in loaded where self.cache[signature] == nil {
                self.cache[signature] = cached
            }
            // A cold launch can begin a lookup before the cache finishes
            // loading. Apply the cached document only if that lookup has not
            // already produced a document for the same signature.
            if self.currentLookupKey != nil,
               let signature = self.currentSignature,
               self.document == nil,
               let cached = self.cache[signature] {
                self.loadTask?.cancel()
                self.apply(cached.document)
                self.isLoading = false
                self.isAwaitingLyrics = false
                self.lookupStatus = nil
            }
        }
    }

    func update(
        signature: TrackSignature?,
        trackID: String? = nil,
        status: PlaybackStatus?
    ) {
        engine.update(status: status)

        let lookupKey = Self.lookupKey(trackID: trackID, signature: signature)
        guard lookupKey != currentLookupKey else {
            // Same Spotify item, but a later complete response can fill album
            // or duration fields that were absent in an earlier sample.
            currentSignature = signature
            return
        }
        currentLookupKey = lookupKey
        currentSignature = signature
        lookupGeneration &+= 1
        let generation = lookupGeneration
        loadTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        // The cancelled task only resets isLoading when it still owns the current
        // signature, so reset it here on every signature change (nil, cached,
        // failed, or a fresh load) or it stays wedged true forever.
        isLoading = false
        lookupStatus = nil
        isAwaitingLyrics = false

        guard let signature, let lookupKey else {
            apply(nil)
            return
        }

        if let cached = cache[signature] {
            cache[signature]?.lastAccessedAt = .now
            apply(cached.document)
            return
        }

        apply(nil)

        guard !failedSignatures.contains(signature) else {
            lookupStatus = "No lyrics found for this track"
            return
        }

        isLoading = true
        isAwaitingLyrics = true
        loadTask = Task { [weak self] in
            await self?.loadAndApply(
                signature,
                lookupKey: lookupKey,
                generation: generation
            )
        }
    }

    /// Starts a fresh lookup for the active track. This clears the session-only
    /// not-found marker so a temporary provider or network problem can recover.
    func retryCurrentLookup() {
        guard let signature = currentSignature,
              let lookupKey = currentLookupKey else { return }
        loadTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        lookupGeneration &+= 1
        let generation = lookupGeneration
        failedSignatures.remove(signature)
        lookupStatus = nil
        isLoading = true
        isAwaitingLyrics = true
        loadTask = Task { [weak self] in
            await self?.loadAndApply(
                signature,
                lookupKey: lookupKey,
                generation: generation
            )
        }
    }

    private func loadAndApply(
        _ signature: TrackSignature,
        lookupKey: String,
        generation: UInt64
    ) async {
        Self.log.info("lookup start: \(signature.title) — \(signature.artist)")
        let outcome = await LRCLIBClient.shared.fetchOutcome(for: signature)
        guard !Task.isCancelled else { return }

        let ownsVisibleLookup = currentLookupKey == lookupKey
            && lookupGeneration == generation

        switch outcome {
        case .document(let fetched):
            Self.log.info("lookup ok: \(fetched.lines.count) lines")
            cache[signature] = CachedLyrics(document: fetched, lastAccessedAt: .now)
            await LyricsCacheRepository.shared.save(cache)
            if currentLookupKey == lookupKey,
               lookupGeneration == generation {
                lookupStatus = nil
                apply(fetched)
                isLoading = false
                isAwaitingLyrics = false
            }
        case .notFound:
            Self.log.error("lookup notFound: \(signature.title) — \(signature.artist)")
            failedSignatures.insert(signature)
            if ownsVisibleLookup {
                lookupStatus = "No lyrics found for this track"
                isLoading = false
                isAwaitingLyrics = false
            }
        case .failed(let reason):
            Self.log.error("lookup failed: \(reason, privacy: .public)")
            DiagnosticsLog.append("lookup failed: \(reason)")
            // Transient (network, rate limit): don't blacklist — surface it and
            // retry after a delay so a mid-song hiccup self-heals.
            if ownsVisibleLookup {
                lookupStatus = "Lyrics lookup failed — retrying (\(reason))"
                isLoading = false
                scheduleRetry(
                    for: signature,
                    lookupKey: lookupKey,
                    generation: generation
                )
            }
        }
    }

    private func scheduleRetry(
        for signature: TrackSignature,
        lookupKey: String,
        generation: UInt64
    ) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled,
                  let self,
                  self.currentLookupKey == lookupKey,
                  self.lookupGeneration == generation else { return }
            self.retryTask = nil
            self.isLoading = true
            self.lookupStatus = "Retrying lyrics…"
            await self.loadAndApply(
                signature,
                lookupKey: lookupKey,
                generation: generation
            )
        }
    }

    func tick() {
        displayPosition = engine.currentPosition() ?? 0
        let index = engine.currentIndex()
        if index != currentIndex {
            currentIndex = index
        }
    }

    func loadForDemo(_ doc: LyricsDocument) {
        cache[doc.track] = CachedLyrics(document: doc, lastAccessedAt: .now)
        // loadForDemo bypasses update(signature:) but still changes the signature;
        // reset isLoading so an in-flight fetch can't leave it wedged true.
        isLoading = false
        lookupStatus = nil
        isAwaitingLyrics = false
        currentSignature = doc.track
        currentLookupKey = Self.lookupKey(trackID: nil, signature: doc.track)
        lookupGeneration &+= 1
        apply(doc)
    }

    private static func lookupKey(
        trackID: String?,
        signature: TrackSignature?
    ) -> String? {
        guard let signature else { return nil }
        if let trackID = trackID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trackID.isEmpty {
            return "spotify:\(trackID)"
        }
        return "metadata:\(signature.title)|\(signature.artist)|\(signature.album ?? "")|\(signature.duration ?? -1)"
    }

    private func apply(_ doc: LyricsDocument?) {
        engine.update(document: doc)
        document = doc
        currentIndex = engine.currentIndex()
    }
}
