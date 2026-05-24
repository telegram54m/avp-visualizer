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

    /// Downloads a preview clip to a temporary file and returns its location.
    ///
    /// The caller is responsible for deleting the returned file when done.
    public static func downloadPreview(from url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.downloadFailed
        }

        // URLSession's temp file has no extension; AVAudioFile needs one to
        // recognize the format. Move it to a path ending in .m4a.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
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
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let audio = try AudioFileDecoder.decode(contentsOf: fileURL)
        return (first, audio)
    }
}
