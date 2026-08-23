import Foundation

public struct LRCLibResult: Codable, Sendable, Equatable {
    public var id: Int
    public var trackName: String
    public var artistName: String
    public var albumName: String?
    public var duration: Double?
    public var instrumental: Bool
    public var plainLyrics: String?
    public var syncedLyrics: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackName = "track_name"
        case artistName = "artist_name"
        case albumName = "album_name"
        case duration
        case instrumental
        case plainLyrics = "plain_lyrics"
        case syncedLyrics = "synced_lyrics"
    }
}

public struct LyricsLookupError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case notFound
        case network(String)
        case parseFailed
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

/// Client for the free LRCLIB lyrics API (https://lrclib.net).
public struct LRCLIBClient: Sendable {
    public static let shared = LRCLIBClient()

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "https://lrclib.net")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Exact match by track signature. Returns nil when no record matches.
    public func get(signature: TrackSignature) async throws -> LRCLibResult? {
        var components = URLComponents(url: baseURL.appending(path: "api/get"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: signature.title),
            URLQueryItem(name: "artist_name", value: signature.artist),
            URLQueryItem(name: "album_name", value: signature.album ?? ""),
            URLQueryItem(name: "duration", value: signature.duration.map { String(Int($0.rounded())) }),
        ].filter { $0.value?.isEmpty == false }

        let (data, response) = try await send(components.url!)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LyricsLookupError(kind: .network("invalid response"))
        }
        if httpResponse.statusCode == 404 {
            return nil
        }
        if httpResponse.statusCode != 200 {
            throw LyricsLookupError(kind: .network("HTTP \(httpResponse.statusCode)"))
        }
        return try decoder.decode(LRCLibResult.self, from: data)
    }

    /// Fuzzy search when the exact lookup misses.
    public func search(signature: TrackSignature) async throws -> [LRCLibResult] {
        var components = URLComponents(url: baseURL.appending(path: "api/search"), resolvingAgainstBaseURL: false)!
        if !signature.title.isEmpty || !signature.artist.isEmpty {
            let query = [signature.title, signature.artist]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }

        let (data, response) = try await send(components.url!)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LyricsLookupError(kind: .network("invalid response"))
        }
        guard httpResponse.statusCode == 200 else {
            throw LyricsLookupError(kind: .network("HTTP \(httpResponse.statusCode)"))
        }
        return try decoder.decode([LRCLibResult].self, from: data)
    }

    /// Best-effort document for a track: exact get, then search fallback.
    /// Prefers synced lyrics; falls back to unsynced lines at 3s intervals.
    public func fetchDocument(for signature: TrackSignature) async -> LyricsDocument? {
        do {
            if let result = try await get(signature: signature),
               let document = document(from: result, track: signature) {
                return document
            }
            let results = try await search(signature: signature)
            let best = bestMatch(in: results, for: signature)
            return best.flatMap { document(from: $0, track: signature) }
        } catch {
            return nil
        }
    }

    private func bestMatch(in results: [LRCLibResult], for signature: TrackSignature) -> LRCLibResult? {
        let synced = results.filter { ($0.syncedLyrics?.isEmpty == false) && !$0.instrumental }
        guard !synced.isEmpty else { return nil }
        guard let targetDuration = signature.duration else { return synced.first }
        return synced.min {
            abs(($0.duration ?? .infinity) - targetDuration) < abs(($1.duration ?? .infinity) - targetDuration)
        }
    }

    private func document(from result: LRCLibResult, track: TrackSignature) -> LyricsDocument? {
        if let lrc = result.syncedLyrics, !lrc.isEmpty,
           let doc = try? LRCParser.makeDocument(lrc: lrc, track: track), !doc.lines.isEmpty {
            return doc
        }
        if let plain = result.plainLyrics, !plain.isEmpty {
            let lines = plain.split(separator: "\n", omittingEmptySubsequences: true)
                .enumerated()
                .map { index, text in LyricLine(time: TimeInterval(index) * 3.0, text: String(text)) }
            return lines.isEmpty ? nil : LyricsDocument(track: track, lines: lines)
        }
        return nil
    }

    private func send(_ url: URL) async throws -> (Data, URLResponse?) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Dynamicallyrics/0.1 (personal)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            return (data, response)
        } catch {
            throw LyricsLookupError(kind: .network(error.localizedDescription))
        }
    }

    private var decoder: JSONDecoder { JSONDecoder() }
}
