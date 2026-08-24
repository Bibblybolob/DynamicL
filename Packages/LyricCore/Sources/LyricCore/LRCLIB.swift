import Foundation
import os.log

public struct LRCLibResult: Codable, Sendable, Equatable {
    public var id: Int
    public var trackName: String
    public var artistName: String
    public var albumName: String?
    public var duration: Double?
    public var instrumental: Bool
    public var plainLyrics: String?
    public var syncedLyrics: String?

    public init(
        id: Int,
        trackName: String,
        artistName: String,
        albumName: String?,
        duration: Double?,
        instrumental: Bool,
        plainLyrics: String?,
        syncedLyrics: String?
    ) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
    }

    /// LRCLIB switched its JSON from snake_case (`track_name`) to camelCase
    /// (`trackName`); accept both so cached/mirrored responses still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(Int.self, forKey: .id)
        trackName = try c.decodeIfPresent(String.self, forKey: .trackName)
            ?? c.decode(String.self, forKey: .track_name)
        artistName = try c.decodeIfPresent(String.self, forKey: .artistName)
            ?? c.decode(String.self, forKey: .artist_name)
        albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
            ?? c.decodeIfPresent(String.self, forKey: .album_name)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        instrumental = try c.decodeIfPresent(Bool.self, forKey: .instrumental) ?? false
        plainLyrics = try c.decodeIfPresent(String.self, forKey: .plainLyrics)
            ?? c.decodeIfPresent(String.self, forKey: .plain_lyrics)
        syncedLyrics = try c.decodeIfPresent(String.self, forKey: .syncedLyrics)
            ?? c.decodeIfPresent(String.self, forKey: .synced_lyrics)
    }

    private enum AnyKey: String, CodingKey {
        case id
        case trackName, track_name
        case artistName, artist_name
        case albumName, album_name
        case duration, instrumental
        case plainLyrics, plain_lyrics
        case syncedLyrics, synced_lyrics
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

    public var message: String {
        switch kind {
        case .notFound: "not found"
        case .network(let detail): "network: \(detail)"
        case .parseFailed: "parse failed"
        }
    }
}

/// Result of a lyrics lookup for one track.
public enum LyricsFetchOutcome: Sendable, Equatable {
    case document(LyricsDocument)
    /// LRCLIB genuinely has no lyrics for this track.
    case notFound
    /// Transient failure (network, rate limit) — worth retrying.
    case failed(String)
}

/// Client for the free LRCLIB lyrics API (https://lrclib.net).
public struct LRCLIBClient: Sendable {
    public static let shared = LRCLIBClient()

    private static let log = Logger(subsystem: "com.jonathantran.dynamicallyrics", category: "LRCLIB")

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
        do {
            return try decoder.decode(LRCLibResult.self, from: data)
        } catch {
            Self.log.error("get decode failed (HTTP \(httpResponse.statusCode)): \(String(data: data.prefix(300), encoding: .utf8) ?? "<binary>", privacy: .public)")
            throw LyricsLookupError(kind: .network("HTTP \(httpResponse.statusCode) — unparseable body: \(String(data: data.prefix(120), encoding: .utf8) ?? "<binary>")"))
        }
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
        do {
            return try decoder.decode([LRCLibResult].self, from: data)
        } catch {
            Self.log.error("search decode failed (HTTP \(httpResponse.statusCode)): \(String(data: data.prefix(300), encoding: .utf8) ?? "<binary>", privacy: .public)")
            throw LyricsLookupError(kind: .network("HTTP \(httpResponse.statusCode) — unparseable body: \(String(data: data.prefix(120), encoding: .utf8) ?? "<binary>")"))
        }
    }

    /// Best-effort document for a track: exact get, then search fallback.
    /// Prefers synced lyrics; falls back to unsynced lines at 3s intervals.
    public func fetchDocument(for signature: TrackSignature) async -> LyricsDocument? {
        if case .document(let doc) = await fetchOutcome(for: signature) {
            return doc
        }
        return nil
    }

    /// Outcome of a lyrics lookup, distinguishing "genuinely no lyrics" from
    /// transient failures (network, rate limits) so callers can retry the latter.
    public func fetchOutcome(for signature: TrackSignature) async -> LyricsFetchOutcome {
        do {
            if let result = try await get(signature: signature),
               let document = document(from: result, track: signature) {
                return .document(document)
            }
            let results = try await search(signature: signature)
            let best = bestMatch(in: results, for: signature)
            if let document = best.flatMap({ document(from: $0, track: signature) }) {
                return .document(document)
            }
            return .notFound
        } catch let error as LyricsLookupError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
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
        request.timeoutInterval = 15
        request.setValue("Dynamicallyrics/0.1 (personal)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            return (data, response)
        } catch let error as URLError {
            Self.log.error("GET \(url.absoluteString, privacy: .public) → URLError \(error.errorCode) \(error.localizedDescription, privacy: .public)")
            throw LyricsLookupError(kind: .network("code \(error.errorCode): \(error.localizedDescription)"))
        } catch {
            Self.log.error("GET \(url.absoluteString, privacy: .public) → \(error.localizedDescription, privacy: .public)")
            throw LyricsLookupError(kind: .network(error.localizedDescription))
        }
    }

    private var decoder: JSONDecoder { JSONDecoder() }
}
