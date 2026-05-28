import CryptoKit
import Foundation

/// A song found via the iTunes Search API, with a link to its preview clip.
public struct SongResult: Sendable, Equatable {
    public let trackName: String
    public let artistName: String
    public let previewURL: URL
}

/// Fetches 30-second song preview clips using Apple's public iTunes Search API.
///
/// This endpoint needs no developer token or authentication, and the preview
/// audio files it points to are plain, unencrypted m4a downloads. That makes
/// it ideal for testing the analysis pipeline against real music.
public enum PreviewFetcher {

    public enum FetchError: Error, Equatable {
        case badResponse
        case noResults
        case downloadFailed
    }

    /// The shape of the iTunes Search API JSON response. Only the fields we
    /// need are decoded; the API returns many more.
    private struct SearchResponse: Decodable {
        struct RawResult: Decodable {
            let trackName: String?
            let artistName: String?
            let previewUrl: URL?
        }
        let results: [RawResult]
    }

    /// Searches the iTunes catalog for songs matching a term.
    ///
    /// - Parameters:
    ///   - term: free-text query, e.g. "Bohemian Rhapsody Queen".
    ///   - limit: maximum number of results to return.
    /// - Returns: songs that have a usable preview URL.
    public static func search(_ term: String, limit: Int = 5) async throws -> [SongResult] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { throw FetchError.badResponse }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.badResponse
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.results.compactMap { raw in
            guard let track = raw.trackName,
                  let artist = raw.artistName,
                  let preview = raw.previewUrl else { return nil }
            return SongResult(trackName: track, artistName: artist, previewURL: preview)
        }
    }

    /// Returns the deterministic local cache path for a given preview
    /// URL. Hash of the URL string keeps filename uniqueness without
    /// embedding the iTunes path structure (which can be long + ugly).
    private static func cachedPath(for url: URL) -> URL {
        let cacheDir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("HighVidelity/previews", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hexName = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(hexName).appendingPathExtension("m4a")
    }

    /// Downloads a preview clip and returns its on-disk location.
    /// Local cache check first — if a previous download for the same
    /// URL is still present in the user's cache directory, skip the
    /// network round-trip. Cache lives under
    /// `~/Library/Caches/HighVidelity/previews/<sha256>.m4a` so it's
    /// macOS-purgeable but stable across app launches.
    ///
    /// Returned URLs from cache hits SHOULD NOT be deleted by the
    /// caller — they're shared. (Originally callers were responsible
    /// for cleanup; that contract still works since the OS will
    /// reclaim ~/Library/Caches under pressure.)
    public static func downloadPreview(from url: URL) async throws -> URL {
        let cached = cachedPath(for: url)
        if FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.downloadFailed
        }
        // Move the freshly-downloaded file into the deterministic
        // cache slot. If another concurrent download for the same URL
        // raced us to the destination, prefer the existing file —
        // FileManager.moveItem throws on collision so we explicitly
        // remove first.
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: tempURL, to: cached)
        return cached
    }

    /// Searches for a song, downloads its first matching preview, and decodes it.
    ///
    /// - Returns: the matched song's metadata and its decoded audio.
    public static func fetchAndDecode(
        matching term: String
    ) async throws -> (song: SongResult, audio: DecodedAudio) {
        let results = try await search(term, limit: 5)
        guard let first = results.first else { throw FetchError.noResults }

        let fileURL = try await downloadPreview(from: first.previewURL)
        // No defer-delete here — downloadPreview now caches; the file
        // stays in ~/Library/Caches/HighVidelity/previews/ and gets
        // reused on the next call for this URL. macOS purges the
        // caches directory under disk pressure.
        let audio = try AudioFileDecoder.decode(contentsOf: fileURL)
        return (first, audio)
    }
}
