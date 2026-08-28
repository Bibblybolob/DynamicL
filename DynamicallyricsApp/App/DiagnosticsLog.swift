import Foundation

/// Appends diagnostic lines to a file in the app's Documents folder so failures
/// on-device can be pulled off with `devicectl device copy from` for debugging.
enum DiagnosticsLog {
    private static let fileName = "lyrics-diagnostics.log"
    private static let queue = DispatchQueue(label: "diagnostics.log")

    static func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            let url = documentsDirectory.appending(path: fileName)
            let entry = "[\(stamp)] \(line)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(entry.utf8))
            } else {
                try? Data(entry.utf8).write(to: url)
            }
        }
    }

    /// Flushes pending writes and returns a file that the user can share from
    /// the app. Create an empty file when no event has been recorded yet.
    static var shareURL: URL {
        queue.sync {
            let url = documentsDirectory.appending(path: fileName)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data().write(to: url)
            }
            return url
        }
    }

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
