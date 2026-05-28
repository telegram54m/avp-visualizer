//
//  LyricsView.swift
//  High Videlity
//
//  Fetches and renders time-synced lyrics for the currently-playing
//  Apple Music track. Apple's MusicKit returns lyrics as TTML markup
//  via `Song.with([.lyrics])`; we parse the <p begin="…" end="…">
//  elements into per-line records and highlight the line whose time
//  range covers `musicKit.playbackTime`. Auto-scrolls the active
//  line toward the center of the visible area on every line change.
//
//  Falls back to a "Lyrics unavailable for this track" empty state
//  when the song has no lyrics relationship populated (instrumentals,
//  catalog gaps, region-locked content, or non-time-synced lyrics
//  that contain no <p begin> attributes).
//
//  Re-fetches on track change via `.task(id: songID)`.
//

import SwiftUI
import MusicKit
import OSLog

private let lyricsLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "lyrics")

#if !os(visionOS)
struct LyricsView: View {

    @Environment(AppModel.self) private var appModel

    @State private var lines: [LyricLine] = []
    @State private var rawLyrics: String?    // fallback if no timing parsed
    @State private var isLoading = false
    @State private var loadError: String?

    /// Currently-active line ID — derived per render from playbackTime.
    /// Drives both the highlight + the auto-scroll trigger.
    private var activeLineID: UUID? {
        let t = appModel.musicKit.playbackTime
        // Walk forward until we find the first line whose end is past
        // playbackTime. Linear scan is fine for typical 50-200-line
        // lyrics; binary search not worth the complexity.
        var candidate: LyricLine?
        for line in lines {
            if line.begin <= t {
                candidate = line
            } else {
                break
            }
        }
        // Only treat a line as active while playbackTime is within
        // its [begin, end] window. Past `end`, leave the highlight
        // until the next line begins — many TTML songs have small
        // gaps between lines (breaths, instrumental beats) where no
        // line is technically active; visually it's cleaner to keep
        // the previous line lit through the gap.
        return candidate?.id
    }

    var body: some View {
        let song = appModel.musicKit.nowPlaying
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Lyrics").font(.headline)
                if let song {
                    Spacer()
                    Text(song.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: song?.id) {
            await loadLyrics()
        }
    }

    @ViewBuilder
    private var content: some View {
        if appModel.musicKit.nowPlaying == nil {
            placeholder("No song playing.")
        } else if isLoading {
            HStack { ProgressView().controlSize(.small); Text("Loading lyrics…").font(.caption).foregroundStyle(.secondary) }
        } else if let err = loadError {
            placeholder(err)
        } else if !lines.isEmpty {
            syncedLyricsView
        } else if let raw = rawLyrics, !raw.isEmpty {
            staticLyricsView(raw)
        } else {
            placeholder("Lyrics unavailable for this track.")
        }
    }

    private func placeholder(_ msg: String) -> some View {
        Text(msg).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var syncedLyricsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(size: 15, weight: line.id == activeLineID ? .semibold : .regular))
                            .foregroundStyle(line.id == activeLineID ? Color.primary : Color.secondary)
                            .opacity(line.id == activeLineID ? 1.0 : 0.55)
                            .id(line.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onTapGesture {
                                appModel.musicKit.seek(to: line.begin)
                            }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: activeLineID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func staticLyricsView(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .textSelection(.enabled)
        }
    }

    // MARK: - Loading

    private func loadLyrics() async {
        lines = []
        rawLyrics = nil
        loadError = nil
        guard let song = appModel.musicKit.nowPlaying else { return }
        isLoading = true
        defer { isLoading = false }

        // Apple Music's official lyrics endpoint requires a
        // `music_lyrics` scope on the user token that MusicKit
        // doesn't grant to third-party apps — verified empirically
        // with HTTP 400 "Insufficient Permissions" responses on
        // both /songs/{id}/lyrics and /songs/{id}?include=lyrics.
        // Pivot to lrclib.net (community-maintained, free, no API
        // key) which serves LRC-format time-synced lyrics for most
        // mainstream catalog.

        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "artist_name", value: song.artistName),
            URLQueryItem(name: "track_name", value: song.title)
        ]
        if let album = song.albumTitle, !album.isEmpty {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }
        // Duration helps lrclib disambiguate covers / live versions
        // / remixes that share title + artist. Sub-second mismatches
        // are tolerated by their fuzzy matcher.
        if let dur = song.duration, dur > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(dur.rounded()))))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            lyricsLog.info("HV-LYRICS url construction failed")
            return
        }
        lyricsLog.info("HV-LYRICS song=\"\(song.title, privacy: .public)\" by \"\(song.artistName, privacy: .public)\"")
        lyricsLog.info("HV-LYRICS GET \(url.absoluteString, privacy: .public)")

        var request = URLRequest(url: url)
        // lrclib's etiquette guide asks for a meaningful UA so they
        // can contact heavy users about misbehavior. Identify the
        // app + the contact page (GitHub Pages doubles as that).
        request.setValue(
            "HighVidelity/0.1 (https://telegram54m.github.io/avp-visualizer)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            lyricsLog.info("HV-LYRICS status=\(http?.statusCode ?? 0) bytes=\(data.count)")
            guard http?.statusCode == 200 else {
                // 404 is "no lyrics for this combination" — silent
                // empty state. Other non-200s also fall through to
                // empty rather than scaring the user.
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lyricsLog.info("HV-LYRICS body not a JSON dict")
                return
            }
            let synced = json["syncedLyrics"] as? String
            let plain = json["plainLyrics"] as? String
            let isInstrumental = (json["instrumental"] as? Bool) ?? false
            if isInstrumental {
                lyricsLog.info("HV-LYRICS marked instrumental — no lyrics")
                rawLyrics = "(Instrumental)"
                return
            }
            if let synced, !synced.isEmpty {
                let parsed = Self.parseLRC(synced)
                lyricsLog.info("HV-LYRICS parsed \(parsed.count) LRC lines")
                if !parsed.isEmpty {
                    lines = parsed
                    return
                }
            }
            if let plain, !plain.isEmpty {
                lyricsLog.info("HV-LYRICS using plain (\(plain.count) chars) — no synced timing")
                rawLyrics = plain
            } else {
                lyricsLog.info("HV-LYRICS no synced or plain text in response")
            }
        } catch {
            lyricsLog.info("HV-LYRICS fetch err: \(String(describing: error), privacy: .public)")
        }
    }

    /// Parse LRC-format lyrics into timed lines. LRC is line-based:
    ///   `[mm:ss.xx]Line text`
    /// One physical line may bear multiple timestamp prefixes when
    /// the lyric repeats; we expand those into separate entries.
    /// End-of-line time is derived from the NEXT line's begin (or
    /// begin + 5s for the final line). Metadata tags like `[ar:…]`
    /// `[ti:…]` `[length:…]` are recognized and skipped.
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        // Regex matches a leading timestamp `[mm:ss.cc]` or `[mm:ss.ccc]`.
        // Multiple timestamps can chain before text.
        let tsPattern = #"\[(\d+):(\d+)(?:\.(\d+))?\]"#
        guard let tsRegex = try? NSRegularExpression(pattern: tsPattern) else { return [] }

        struct RawTimed { let time: TimeInterval; let text: String }
        var raw: [RawTimed] = []

        let physicalLines = lrc.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for rawLine in physicalLines {
            let line = String(rawLine)
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            let tsMatches = tsRegex.matches(in: line, options: [], range: range)
            guard !tsMatches.isEmpty else { continue }
            // Pull text after the last timestamp.
            let lastMatchEnd = tsMatches.last!.range.location + tsMatches.last!.range.length
            let textStart = lastMatchEnd
            let textRange = NSRange(location: textStart, length: ns.length - textStart)
            let text = ns.substring(with: textRange).trimmingCharacters(in: .whitespaces)
            // Skip metadata-only tags (text empty after a single
            // tag) — but only when the timestamp doesn't look like
            // an actual song timestamp. lrclib only sends valid
            // timestamps, so we just keep empty-text lines if
            // they're part of intentional gaps... actually skip
            // them; they'd render as blank rows.
            guard !text.isEmpty else { continue }
            // Skip obvious metadata: `[ar:…]` `[ti:…]` etc. are matched
            // by tsRegex with mm=0, ss=… of an arbitrary number — not
            // distinguishable structurally. Safest: skip leading
            // `[<letter>:` tagged lines via a second check.
            if line.hasPrefix("["), let firstColon = line.firstIndex(of: ":"),
               firstColon > line.index(after: line.startIndex),
               line.distance(from: line.index(after: line.startIndex), to: firstColon) <= 3,
               !"0123456789".contains(line[line.index(after: line.startIndex)]) {
                continue
            }
            for m in tsMatches {
                guard m.numberOfRanges >= 3 else { continue }
                let mmStr = ns.substring(with: m.range(at: 1))
                let ssStr = ns.substring(with: m.range(at: 2))
                let fracStr = m.range(at: 3).location == NSNotFound
                    ? "0"
                    : ns.substring(with: m.range(at: 3))
                guard let mm = Double(mmStr), let ss = Double(ssStr) else { continue }
                // Frac may be 2 digits (hundredths) or 3 (millis);
                // normalize to seconds.
                let fracDigits = fracStr.count
                let fracVal = Double(fracStr) ?? 0
                let fracSeconds = fracVal / pow(10.0, Double(fracDigits))
                let t = mm * 60 + ss + fracSeconds
                raw.append(RawTimed(time: t, text: text))
            }
        }
        // Sort by time + assign end = next begin (5s tail on final).
        raw.sort { $0.time < $1.time }
        var out: [LyricLine] = []
        out.reserveCapacity(raw.count)
        for (idx, r) in raw.enumerated() {
            let end = (idx + 1 < raw.count) ? raw[idx + 1].time : r.time + 5
            out.append(LyricLine(begin: r.time, end: end, text: r.text))
        }
        return out
    }

    struct LyricLine: Identifiable, Equatable {
        let id = UUID()
        let begin: TimeInterval
        let end: TimeInterval
        let text: String
    }
}
#endif
