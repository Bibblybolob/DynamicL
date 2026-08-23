import Foundation
import LyricCore

/// Fetches and caches lyrics documents, feeding the sync engine on track changes.
@MainActor
@Observable
final class LyricsService {
    private(set) var document: LyricsDocument?
    private(set) var isLoading = false
    private(set) var currentIndex: Int?
    private(set) var displayPosition: TimeInterval = 0

    var userOffset: TimeInterval {
        get { engine.userOffset }
        set { engine.userOffset = newValue }
    }

    let engine = SyncEngine()

    private var cache: [TrackSignature: LyricsDocument] = [:]
    private var failedSignatures: Set<TrackSignature> = []
    private var loadTask: Task<Void, Never>?
    private var currentSignature: TrackSignature?

    func update(signature: TrackSignature?, status: PlaybackStatus?) {
        engine.update(status: status)

        guard signature != currentSignature else { return }
        currentSignature = signature
        loadTask?.cancel()
        // The cancelled task only resets isLoading when it still owns the current
        // signature, so reset it here on every signature change (nil, cached,
        // failed, or a fresh load) or it stays wedged true forever.
        isLoading = false

        guard let signature else {
            apply(nil)
            return
        }

        if let cached = cache[signature] {
            apply(cached)
            return
        }

        apply(nil)

        guard !failedSignatures.contains(signature) else { return }

        isLoading = true
        loadTask = Task { [weak self] in
            let fetched = await LRCLIBClient.shared.fetchDocument(for: signature)
            guard !Task.isCancelled, let self else { return }
            self.cache[signature] = fetched
            if fetched == nil {
                self.failedSignatures.insert(signature)
            }
            if self.currentSignature == signature {
                self.apply(fetched)
                self.isLoading = false
            }
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
        currentSignature = doc.track
        apply(doc)
    }

    private func apply(_ doc: LyricsDocument?) {
        engine.update(document: doc)
        document = doc
        currentIndex = engine.currentIndex()
    }
}
