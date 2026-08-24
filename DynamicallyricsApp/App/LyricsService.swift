import Foundation
import LyricCore
import os.log

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

    var userOffset: TimeInterval {
        get { engine.userOffset }
        set { engine.userOffset = newValue }
    }

    let engine = SyncEngine()

    private var cache: [TrackSignature: LyricsDocument] = [:]
    private var failedSignatures: Set<TrackSignature> = []
    private var loadTask: Task<Void, Never>?
    private var currentSignature: TrackSignature?
    private var retryTask: Task<Void, Never>?

    func update(signature: TrackSignature?, status: PlaybackStatus?) {
        engine.update(status: status)

        guard signature != currentSignature else { return }
        currentSignature = signature
        loadTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        // The cancelled task only resets isLoading when it still owns the current
        // signature, so reset it here on every signature change (nil, cached,
        // failed, or a fresh load) or it stays wedged true forever.
        isLoading = false
        lookupStatus = nil

        guard let signature else {
            apply(nil)
            return
        }

        if let cached = cache[signature] {
            apply(cached)
            return
        }

        apply(nil)

        guard !failedSignatures.contains(signature) else {
            lookupStatus = "No lyrics found for this track"
            return
        }

        isLoading = true
        loadTask = Task { [weak self] in
            await self?.loadAndApply(signature)
        }
    }

    private func loadAndApply(_ signature: TrackSignature) async {
        Self.log.info("lookup start: \(signature.title) — \(signature.artist)")
        let outcome = await LRCLIBClient.shared.fetchOutcome(for: signature)
        guard !Task.isCancelled else { return }

        switch outcome {
        case .document(let fetched):
            Self.log.info("lookup ok: \(fetched.lines.count) lines")
            cache[signature] = fetched
            if currentSignature == signature {
                lookupStatus = nil
                apply(fetched)
                isLoading = false
            }
        case .notFound:
            Self.log.error("lookup notFound: \(signature.title) — \(signature.artist)")
            failedSignatures.insert(signature)
            if currentSignature == signature {
                lookupStatus = "No lyrics found for this track"
                isLoading = false
            }
        case .failed(let reason):
            Self.log.error("lookup failed: \(reason, privacy: .public)")
            DiagnosticsLog.append("lookup failed: \(reason)")
            // Transient (network, rate limit): don't blacklist — surface it and
            // retry after a delay so a mid-song hiccup self-heals.
            if currentSignature == signature {
                lookupStatus = "Lyrics lookup failed — retrying (\(reason))"
                isLoading = false
            }
            scheduleRetry(for: signature)
        }
    }

    private func scheduleRetry(for signature: TrackSignature) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.currentSignature == signature else { return }
            await self.loadAndApply(signature)
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
        cache[doc.track] = doc
        // loadForDemo bypasses update(signature:) but still changes the signature;
        // reset isLoading so an in-flight fetch can't leave it wedged true.
        isLoading = false
        lookupStatus = nil
        currentSignature = doc.track
        apply(doc)
    }

    private func apply(_ doc: LyricsDocument?) {
        engine.update(document: doc)
        document = doc
        currentIndex = engine.currentIndex()
    }
}
