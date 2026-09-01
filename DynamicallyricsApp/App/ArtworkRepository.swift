import Foundation
import LyricCore

/// File-backed artwork shared by the app, widgets, Live Activity, and Watch.
///
/// UserDefaults is not suitable for multi-megabyte images. This repository
/// keeps only small keys in snapshots, writes image files atomically, and
/// bounds the cache to four images and two megabytes.
actor ArtworkRepository {
    static let shared = ArtworkRepository()

    private init() {}

    func save(_ data: Data, for urlString: String) {
        _ = ArtworkFileCache.store(data, for: urlString)
    }

    func data(for urlString: String) -> Data? {
        ArtworkFileCache.data(for: urlString)
    }

    func removeAll() {
        ArtworkFileCache.removeAll()
    }
}
