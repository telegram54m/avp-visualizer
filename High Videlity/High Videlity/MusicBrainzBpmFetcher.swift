//
//  MusicBrainzBpmFetcher.swift
//  High Videlity
//
//  Secondary BPM/key lookup path used when GetSongBPM returns no
//  match. GetSongBPM's database is hand-curated and skews toward
//  modern pop/electronic; classic-rock and older catalog titles
//  (e.g. Bee Gees' "How Deep Is Your Love") are often absent. The
//  MusicBrainz + AcousticBrainz chain has different coverage —
//  fingerprinted from real audio analysis, frozen in 2018 so newer
//  songs aren't there, but classic catalog is well-represented.
//
//  Pipeline:
//    1. MusicBrainz `/recording/?query=...` → list of recording IDs
//       matching the title+artist query.
//    2. For each MBID (in score order), hit AcousticBrainz
//       `/api/v1/<MBID>/low-level` for rhythm.bpm + tonal.key_key/key_scale.
//       Many recordings are NOT in AB (404) — keep trying until one
//       hits. Same MBID's `/high-level` adds binary danceability.
//    3. Return a unified `TunebatBpmFetcher.Result`.
//
//  Rate limiting: MusicBrainz allows ~1 req/sec per their AUP.
//  AcousticBrainz is more permissive. We don't aggressively bombard —
//  worst case is a few sequential requests per song that GetSongBPM
//  missed, and results are cached.
//
//  User-Agent: MusicBrainz REQUIRES a meaningful one. Format is
//  "applicationName/version (contact-info)" per their guidelines.
//

import Foundation
import OSLog
import AudioAnalysis

private let mbLog = Logger(subsystem: "com.example.HighVidelity", category: "MusicBrainz")

enum MusicBrainzBpmFetcher {

    /// Same Result type as `TunebatBpmFetcher` so callers can chain
    /// the two interchangeably.
    typealias Result = TunebatBpmFetcher.Result

    /// User-Agent header value sent to MusicBrainz. Per their AUP
    /// this must identify the application and provide a contact URL
    /// (the GitHub Pages site doubles as that).
    private static let userAgent =
        "HighVidelity/0.1 (https://telegram54m.github.io/avp-visualizer)"

    /// Look up a song's BPM + key via the MusicBrainz → AcousticBrainz
    /// chain. Returns nil if no recording was found OR no recording
    /// had analysis data OR the network failed.
    ///
    /// Caching is the caller's responsibility — `TunebatBpmFetcher`
    /// wraps both fetchers in the same UserDefaults cache, so this
    /// function doesn't need its own.
    static func lookup(title: String, artist: String) async -> Result? {
        guard let mbids = await searchRecordings(title: title, artist: artist),
              !mbids.isEmpty else {
            mbLog.info("HV-MB no MBIDs for \(title, privacy: .public) — \(artist, privacy: .public)")
            return nil
        }

        // Try MBIDs in score order. Many won't have AB data; bail on
        // the first that does.
        for mbid in mbids {
            if let analysis = await fetchAcousticBrainzLowLevel(mbid: mbid) {
                // High-level classifiers (danceability, mood_aggressive,
                // mood_acoustic) come from a separate endpoint — fetch
                // ONCE and extract everything from the same JSON to
                // avoid two HTTP round-trips per song.
                let classifiers = await fetchAcousticBrainzHighLevel(mbid: mbid)
                mbLog.info("HV-MB hit \(mbid, privacy: .public) → \(analysis.bpm) BPM, key \(analysis.key?.name ?? "?", privacy: .public)")
                return Result(
                    bpm: analysis.bpm,
                    danceability: classifiers?.danceability,
                    acousticness: classifiers?.acousticness,
                    aggressiveness: classifiers?.aggressiveness,
                    happiness: classifiers?.happiness,
                    voiceVocal: classifiers?.voiceVocal,
                    timbreBrightness: classifiers?.timbreBrightness,
                    timeSig: nil,  // AB doesn't expose time signature
                    party: classifiers?.party,
                    relaxed: classifiers?.relaxed,
                    key: analysis.key,
                    canonicalTitle: title,
                    canonicalArtist: artist
                )
            }
        }
        mbLog.info("HV-MB no AB data across \(mbids.count) MBIDs for \(title, privacy: .public)")
        return nil
    }

    // MARK: - MusicBrainz: title+artist → list of MBIDs

    /// Returns recording MBIDs in score order (best match first),
    /// or nil on network failure. Empty array is also a valid "no
    /// match" outcome.
    private static func searchRecordings(title: String, artist: String) async -> [String]? {
        // MusicBrainz Lucene-style query. Quoting the field values
        // keeps spaces and special chars from being parsed as
        // separate query terms.
        let query = "recording:\"\(escapeForLucene(title))\" AND artist:\"\(escapeForLucene(artist))\""
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                mbLog.notice("HV-MB recording search non-200 \(code)")
                return []
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recordings = json["recordings"] as? [[String: Any]]
            else { return [] }
            return recordings.compactMap { $0["id"] as? String }
        } catch {
            mbLog.notice("HV-MB recording search err \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Quote special Lucene query characters so titles/artists with
    /// e.g. `:` or `&` don't break the query.
    private static func escapeForLucene(_ s: String) -> String {
        // Backslash-escape Lucene's reserved chars except space.
        let reserved: Set<Character> = [
            "+", "-", "&", "|", "!", "(", ")", "{", "}", "[", "]",
            "^", "\"", "~", "*", "?", ":", "\\", "/"
        ]
        var out = ""
        for ch in s {
            if reserved.contains(ch) {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }

    // MARK: - AcousticBrainz: low-level (BPM + key)

    private struct LowLevelAnalysis {
        let bpm: Float
        let key: Key?
    }

    private static func fetchAcousticBrainzLowLevel(mbid: String) async -> LowLevelAnalysis? {
        guard let url = URL(string: "https://acousticbrainz.org/api/v1/\(mbid)/low-level")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            // 404 just means "no analysis for this MBID" — common; try next MBID.
            guard http.statusCode == 200 else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let rhythm = json["rhythm"] as? [String: Any]
            let tonal = json["tonal"] as? [String: Any]

            guard let bpmNum = rhythm?["bpm"] as? NSNumber else { return nil }
            let bpm = bpmNum.floatValue
            guard bpm > 30, bpm < 300 else { return nil }

            // Key parsing: AB returns key_key as a note name ("F", "F#")
            // and key_scale as "major" / "minor". Normalize to AudioAnalysis.Key.
            let key: Key? = {
                guard let keyName = tonal?["key_key"] as? String,
                      let scale = tonal?["key_scale"] as? String
                else { return nil }
                let modeSuffix = scale.lowercased() == "minor" ? "m" : ""
                // Re-use TunebatBpmFetcher's parser so we get the same
                // sharp/flat normalization behavior.
                return TunebatBpmFetcher.parseKey("\(keyName)\(modeSuffix)")
            }()
            return LowLevelAnalysis(bpm: bpm, key: key)
        } catch {
            mbLog.notice("HV-MB AB low-level err \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - AcousticBrainz: high-level (mood + character classifiers)

    /// All the high-level classifiers we currently consume, each
    /// mapped from AcousticBrainz's binary "value" + "probability"
    /// shape into a 0-100 scale (same range as GetSongBPM's numeric
    /// fields). Nil entries mean the classifier wasn't present in
    /// the JSON for this MBID.
    private struct HighLevelClassifiers {
        let danceability: Float?
        let acousticness: Float?
        let aggressiveness: Float?
        let happiness: Float?
        /// 0-100. 100 = vocal, 0 = instrumental.
        let voiceVocal: Float?
        /// 0-100. 100 = bright, 0 = dark.
        let timbreBrightness: Float?
        /// 0-100. 100 = party (energetic celebration vibe).
        let party: Float?
        /// 0-100. 100 = relaxed (calm vibe). Inverted by visualizers
        /// since high relaxed should DAMP intensity, not add to it.
        let relaxed: Float?
    }

    /// Returns 0-100 scores mapped from AcousticBrainz's binary
    /// classifiers + probability. Mapping used for ALL of them:
    ///   - `positiveValue ? p*100 : (1-p)*100`
    /// where `positiveValue` is the classifier-specific "yes" value:
    ///   - danceability:  "danceable"
    ///   - mood_acoustic: "acoustic"
    ///   - mood_aggressive: "aggressive"
    ///
    /// Why a single fetch returns all three: each AcousticBrainz call
    /// is a round-trip to their server; fetching once and extracting
    /// multiple fields is half the latency of separate calls. JSON
    /// payload includes ~15 classifiers; we only parse the ones we
    /// currently use, but adding more (mood_happy, mood_relaxed,
    /// voice_instrumental, etc.) is one line each.
    private static func fetchAcousticBrainzHighLevel(mbid: String) async -> HighLevelClassifiers? {
        guard let url = URL(string: "https://acousticbrainz.org/api/v1/\(mbid)/high-level")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let highlevel = json["highlevel"] as? [String: Any]
            else { return nil }
            return HighLevelClassifiers(
                danceability: Self.binaryClassifierScore(
                    in: highlevel, key: "danceability", positiveValue: "danceable"),
                acousticness: Self.binaryClassifierScore(
                    in: highlevel, key: "mood_acoustic", positiveValue: "acoustic"),
                aggressiveness: Self.binaryClassifierScore(
                    in: highlevel, key: "mood_aggressive", positiveValue: "aggressive"),
                happiness: Self.binaryClassifierScore(
                    in: highlevel, key: "mood_happy", positiveValue: "happy"),
                voiceVocal: Self.binaryClassifierScore(
                    in: highlevel, key: "voice_instrumental", positiveValue: "voice"),
                timbreBrightness: Self.binaryClassifierScore(
                    in: highlevel, key: "timbre", positiveValue: "bright"),
                party: Self.binaryClassifierScore(
                    in: highlevel, key: "mood_party", positiveValue: "party"),
                relaxed: Self.binaryClassifierScore(
                    in: highlevel, key: "mood_relaxed", positiveValue: "relaxed")
            )
        } catch {
            return nil
        }
    }

    /// Extract a single AcousticBrainz binary classifier and map to
    /// 0-100. See `fetchAcousticBrainzHighLevel` doc for the mapping
    /// formula. Returns nil if the classifier is missing or its
    /// fields don't parse.
    private static func binaryClassifierScore(
        in highlevel: [String: Any],
        key: String,
        positiveValue: String
    ) -> Float? {
        guard let dict = highlevel[key] as? [String: Any],
              let value = dict["value"] as? String,
              let probability = dict["probability"] as? NSNumber
        else { return nil }
        let p = probability.floatValue
        return value == positiveValue ? p * 100 : (1 - p) * 100
    }
}
