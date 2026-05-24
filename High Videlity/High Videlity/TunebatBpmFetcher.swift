//
//  TunebatBpmFetcher.swift  →  GetSongBPM lookup
//  High Videlity
//
//  Look up a song's canonical BPM by title + artist via the
//  getsongbpm.com REST API. Originally targeted Tunebat scraping but
//  Tunebat is behind Cloudflare anti-bot protection (HTTP 403 with a
//  JS challenge) — unreachable from URLSession. GetSongBPM exposes a
//  documented JSON endpoint and is the practical replacement.
//
//  The fetcher is named `TunebatBpmFetcher` for backwards compat with
//  the rest of the app's wiring; type/file rename is a follow-up
//  cleanup once we're sure this is stable.
//
//  Why we need this at all: the internal IOI-based `BeatTracker` in
//  `AudioAnalysis` regularly locks onto half/double-time
//  interpretations of perceived tempo (see [[feedback_beat-tracker-octave]]).
//  For songs Shazam has positively identified, we can sidestep that
//  ambiguity by looking up the canonical BPM from a database. This
//  fetcher handles the lookup; AppModel + DodecahedronVisualizer
//  consume the result.
//
//  API key: GetSongBPM is free with attribution; sign up at
//  getsongbpm.com/api to obtain a key. Stored in this file as
//  `apiKey`; for production move to Info.plist or Keychain.
//
//  Results are cached per-song in UserDefaults so a re-listen doesn't
//  refetch.
//

import Foundation
import OSLog

private let bpmLog = Logger(subsystem: "com.example.HighVidelity", category: "GetSongBPM")

enum TunebatBpmFetcher {

    /// GetSongBPM API key. **Paste your key here** — get one (free,
    /// requires attribution backlink to getsongbpm.com somewhere in
    /// the app) from getsongbpm.com/api. If left empty, all lookups
    /// short-circuit to nil and the visualizer falls back to the
    /// BeatTracker.
    private static let apiKey: String = "REPLACE_ME"

    /// Result of a successful lookup. Carries the BPM and the
    /// canonical title/artist that GetSongBPM matched (useful for
    /// logging when our Shazam title doesn't exactly match the
    /// database title — e.g. "Foo (Remastered 2019)" vs "Foo").
    struct Result {
        let bpm: Float
        let canonicalTitle: String
        let canonicalArtist: String
    }

    /// Look up a song's BPM. Returns nil if no match was found OR the
    /// network failed OR the API key is unset. Caller decides what to
    /// do on nil (typically fall back to the BeatTracker's estimate).
    ///
    /// Cached: result (or "no result" sentinel) is stored in
    /// UserDefaults under a normalized key. Second call for the same
    /// (title, artist) returns instantly without network.
    static func lookup(title: String, artist: String) async -> Result? {
        guard apiKey != "REPLACE_ME", !apiKey.isEmpty else {
            bpmLog.notice("HV-BPM api key unset — skipping lookup")
            return nil
        }

        let cacheKey = makeCacheKey(title: title, artist: artist)
        if let cached = readCache(cacheKey) {
            bpmLog.info("HV-BPM cache hit \(title, privacy: .public) → \(cached.bpm) BPM")
            return cached
        }

        if let result = await fetchFromAPI(title: title, artist: artist) {
            writeCache(cacheKey, result: result)
            bpmLog.info("HV-BPM api \(title, privacy: .public) → \(result.bpm) BPM (\(result.canonicalTitle, privacy: .public) / \(result.canonicalArtist, privacy: .public))")
            return result
        }

        // Negative cache so we don't keep retrying the same no-match
        // song. TTL is implicit — entry stays until UserDefaults is
        // cleared. Revisit if GetSongBPM coverage expands and a
        // previously-missed song would now be found.
        writeNegativeCache(cacheKey)
        bpmLog.info("HV-BPM no match \(title, privacy: .public) — \(artist, privacy: .public)")
        return nil
    }

    // MARK: - API call

    /// Build a GetSongBPM search URL using their `lookup=song:X artist:Y`
    /// param syntax. Returns nil on encoding failure (very unlikely).
    private static func buildSearchURL(title: String, artist: String) -> URL? {
        // GetSongBPM uses + as space separator within the lookup value,
        // colons as field separators. Easiest to build the value string
        // first then URL-encode it as a single query parameter.
        let cleanedTitle = scrubForLookup(title)
        let cleanedArtist = scrubForLookup(artist)
        var lookup = "song:\(cleanedTitle)"
        if !cleanedArtist.isEmpty {
            lookup += " artist:\(cleanedArtist)"
        }
        var components = URLComponents(string: "https://api.getsongbpm.com/search/")
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "type", value: "both"),
            URLQueryItem(name: "lookup", value: lookup)
        ]
        return components?.url
    }

    /// Strip characters that confuse GetSongBPM's lookup parser
    /// (colons, ampersands, brackets) — those collide with the
    /// `song:X artist:Y` syntax. Also drop common Shazam-suffix junk
    /// like "(Remastered)" / "(2019 Remaster)" that don't match the
    /// database's canonical title.
    private static func scrubForLookup(_ s: String) -> String {
        var out = s
        // Drop parenthesized suffixes — they're usually noise for
        // database lookup ("(feat. X)", "(Remastered)", etc.). The
        // db has the base title.
        if let parenIdx = out.firstIndex(of: "(") {
            out = String(out[..<parenIdx]).trimmingCharacters(in: .whitespaces)
        }
        if let bracketIdx = out.firstIndex(of: "[") {
            out = String(out[..<bracketIdx]).trimmingCharacters(in: .whitespaces)
        }
        out = out.replacingOccurrences(of: ":", with: " ")
        out = out.replacingOccurrences(of: "&", with: "and")
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func fetchFromAPI(title: String, artist: String) async -> Result? {
        guard let url = buildSearchURL(title: title, artist: artist) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                bpmLog.notice("HV-BPM api non-200 \(http.statusCode)")
                return nil
            }
            return parseResponse(data: data, queryTitle: title, queryArtist: artist)
        } catch {
            bpmLog.notice("HV-BPM api error \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// GetSongBPM returns JSON with a `search` array. Each result has
    /// `tempo` as a string ("120"), `song_title`, and `artist` as a
    /// nested object with `name`. We pick the best-scoring match by
    /// title+artist similarity and return its tempo.
    private static func parseResponse(
        data: Data, queryTitle: String, queryArtist: String
    ) -> Result? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any] else { return nil }

        // Response shapes observed:
        //   { "search": [ {item}, ... ] }
        //   { "search": {item} }              // single-result endpoint
        //   { "search": "Nothing found" }     // "no result" string
        let items: [[String: Any]] = {
            if let arr = root["search"] as? [[String: Any]] {
                return arr
            }
            if let single = root["search"] as? [String: Any] {
                return [single]
            }
            return []
        }()
        guard !items.isEmpty else {
            bpmLog.notice("HV-BPM api search empty / unexpected shape")
            return nil
        }

        let normQueryTitle = normalize(queryTitle)
        let normQueryArtist = normalize(queryArtist)
        var best: (item: [String: Any], score: Double)?
        for item in items {
            let itemTitle = (item["song_title"] as? String)
                ?? (item["title"] as? String) ?? ""
            let itemArtist: String = {
                if let nested = item["artist"] as? [String: Any] {
                    return (nested["name"] as? String) ?? ""
                }
                if let s = item["artist"] as? String { return s }
                return ""
            }()
            let titleScore = similarity(normalize(itemTitle), normQueryTitle)
            let artistScore = similarity(normalize(itemArtist), normQueryArtist)
            let score = titleScore * 0.7 + artistScore * 0.3
            if best == nil || score > best!.score {
                best = (item, score)
            }
        }
        guard let (item, score) = best, score >= 0.4 else {
            bpmLog.notice("HV-BPM best match score too low (\(best?.score ?? 0, format: .fixed(precision: 2)))")
            return nil
        }

        // Tempo is usually a string in the JSON — robust extraction:
        let bpm: Float? = {
            if let n = item["tempo"] as? NSNumber { return n.floatValue }
            if let s = item["tempo"] as? String, let f = Float(s) { return f }
            return nil
        }()
        guard let bpm = bpm, bpm > 30, bpm < 300 else {
            bpmLog.notice("HV-BPM tempo missing or out of range")
            return nil
        }

        let canonicalTitle = (item["song_title"] as? String)
            ?? (item["title"] as? String) ?? queryTitle
        let canonicalArtist: String = {
            if let nested = item["artist"] as? [String: Any],
               let name = nested["name"] as? String { return name }
            if let s = item["artist"] as? String { return s }
            return queryArtist
        }()

        return Result(
            bpm: bpm,
            canonicalTitle: canonicalTitle,
            canonicalArtist: canonicalArtist
        )
    }

    // MARK: - Caching

    private static let cachePrefix = "HighVidelity.GetSongBPM."

    private static func makeCacheKey(title: String, artist: String) -> String {
        cachePrefix + normalize("\(title)|\(artist)")
    }

    private static func readCache(_ key: String) -> Result? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) else {
            return nil
        }
        if let zero = dict["bpm"] as? Double, zero <= 0 { return nil }
        guard let bpm = dict["bpm"] as? Double, bpm > 30 else { return nil }
        return Result(
            bpm: Float(bpm),
            canonicalTitle: (dict["title"] as? String) ?? "",
            canonicalArtist: (dict["artist"] as? String) ?? ""
        )
    }

    private static func writeCache(_ key: String, result: Result) {
        let dict: [String: Any] = [
            "bpm": Double(result.bpm),
            "title": result.canonicalTitle,
            "artist": result.canonicalArtist
        ]
        UserDefaults.standard.set(dict, forKey: key)
    }

    private static func writeNegativeCache(_ key: String) {
        UserDefaults.standard.set(["bpm": 0.0], forKey: key)
    }

    // MARK: - String helpers

    private static func normalize(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        out.reserveCapacity(lower.count)
        var lastWasSpace = false
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if ch.isWhitespace || ch == "-" || ch == "_" {
                if !lastWasSpace && !out.isEmpty {
                    out.append(" ")
                    lastWasSpace = true
                }
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.split(separator: " ").map(String.init))
        let wordsB = Set(b.split(separator: " ").map(String.init))
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }
        let inter = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(inter) / Double(union)
    }
}
