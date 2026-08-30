import Foundation

/// Appends diagnostic lines to a file in the app's Documents folder so failures
/// on-device can be pulled off with `devicectl device copy from` for debugging.
enum DiagnosticsLog {
    private static let fileName = "lyrics-diagnostics.log"
    private static let rotatedFileName = "lyrics-diagnostics.log.1"
    private static let maxFileBytes = 1_000_000
    private static let queue = DispatchQueue(label: "diagnostics.log")

    static func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let safeLine = redact(line)
        queue.async {
            let url = documentsDirectory.appending(path: fileName)
            let entry = "[\(stamp)] \(safeLine)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                if let size = try? handle.seekToEnd(), size + UInt64(entry.utf8.count) > UInt64(maxFileBytes) {
                    try? handle.close()
                    let rotated = documentsDirectory.appending(path: rotatedFileName)
                    try? FileManager.default.removeItem(at: rotated)
                    try? FileManager.default.moveItem(at: url, to: rotated)
                    try? Data(entry.utf8).write(to: url, options: .atomic)
                    return
                }
                try? handle.write(contentsOf: Data(entry.utf8))
                try? handle.close()
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

    /// Diagnostics can be shared from a user device. Remove credentials and
    /// stable private identifiers before the line enters the file queue.
    private static func redact(_ line: String) -> String {
        var result = line
        let keyPattern = #"(?i)\b(accessToken|refreshToken|serverAccessToken|syncServerAuthToken|pushToStartToken|updateToken|authorization|trackID|trackKey|deviceID|userID|commandID|access_token|refresh_token)(\s*[:=]\s*|\s+)[^,;\s}\]]+"#
        if let regex = try? NSRegularExpression(pattern: keyPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1$2[REDACTED]"
            )
        }
        let bearerPattern = #"(?i)\bBearer\s+[^,;\s}\]]+"#
        if let regex = try? NSRegularExpression(pattern: bearerPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "Bearer [REDACTED]"
            )
        }
        let queryPattern = #"(?i)([?&](?:access_token|refresh_token|token|authorization)=)[^&\s]+"#
        if let regex = try? NSRegularExpression(pattern: queryPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1[REDACTED]"
            )
        }
        return result
    }
}
