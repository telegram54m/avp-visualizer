import Foundation
import Testing
@testable import AudioAnalysis

// These tests hit the live iTunes Search API and require network access.

@Test("iTunes search returns songs with preview URLs")
func searchReturnsSongs() async throws {
    let results = try await PreviewFetcher.search("Daft Punk", limit: 5)
    #expect(!results.isEmpty)
    for song in results {
        #expect(song.previewURL.scheme == "https")
        #expect(!song.trackName.isEmpty)
    }
}

@Test("A real preview clip downloads and decodes to roughly 30 seconds")
func previewDecodesToThirtySeconds() async throws {
    let (_, audio) = try await PreviewFetcher.fetchAndDecode(matching: "Get Lucky Daft Punk")
    #expect(audio.sampleRate > 0)
    // iTunes previews are ~30 seconds long.
    #expect(audio.duration > 20)
    #expect(audio.duration < 45)
}

@Test("Real songs: compare key-detection approaches")
func detectKeyOfRealSongs() async throws {
    // term → the song's commonly-cited actual key, for eyeballing accuracy.
    let songs = [
        ("Bohemian Rhapsody Queen", "Bb major (intro)"),
        ("Billie Jean Michael Jackson", "F# minor"),
        ("Get Lucky Daft Punk", "B minor"),
        ("Smells Like Teen Spirit Nirvana", "F minor"),
        ("Clair de Lune Debussy", "Db major"),
    ]

    print("\n──────── REAL-SONG KEY DETECTION ────────")
    for (term, actualKey) in songs {
        do {
            let (song, audio) = try await PreviewFetcher.fetchAndDecode(matching: term)

            let chroma = Chromagram.aggregate(over: audio)
            let ranked = KeyDetector.rankedCandidates(from: chroma, profile: .temperley)
            let bass = BassNoteDetector.detect(in: audio)
            let final = KeyDetector.detect(
                from: chroma,
                profile: .temperley,
                bassHint: bass?.pitchClass
            )

            let top3 = ranked.prefix(3)
                .map { "\($0.key.name) \(String(format: "%.2f", $0.correlation))" }
                .joined(separator: " | ")
            let bassText = bass.map {
                "\($0.pitchClass.name) (prominence \(String(format: "%.2f", $0.prominence)))"
            } ?? "none"
            let flipped = final.key != ranked.first?.key

            let tonality = Tonality(of: chroma)

            print("🎵 \(song.trackName) — \(song.artistName)")
            print("   actual:      \(actualKey)")
            print("   candidates:  \(top3)")
            print("   bass:        \(bassText)")
            print("   → final:     \(final.key.name)"
                  + (flipped ? "   [bass tie-break applied]" : ""))
            print("   tonality:    center \(tonality.center.name), "
                  + "majorness \(String(format: "%+.2f", tonality.majorness))")
            let color = TonalColor(chromagram: chroma, majorness: tonality.majorness)
            print("   color:       hue \(String(format: "%.2f", color.hue)), "
                  + "sat \(String(format: "%.2f", color.saturation)), "
                  + "bright \(String(format: "%.2f", color.brightness))")
            let timbre = Timbre.average(over: audio)
            print("   timbre:      centroid \(Int(timbre.centroidHz))Hz, "
                  + "brightness \(String(format: "%.2f", timbre.brightness))")
            let onsets = OnsetDetector.detect(in: audio)
            print("   onsets:      \(onsets.onsetTimes.count) detected, "
                  + "\(String(format: "%.1f", onsets.onsetRate))/sec")
            if let tempo = TempoDetector.detect(in: audio) {
                print("   tempo:       \(Int(tempo.bpm.rounded())) BPM "
                      + "(confidence \(String(format: "%.2f", tempo.confidence)))")
            }
            let harmonic = HarmonicComplexity.average(over: audio)
            print("   harmonic:    \(harmonic.peakCount) peaks/frame, "
                  + "complexity \(String(format: "%.2f", harmonic.value))")
        } catch {
            print("⚠️  \(term): \(error)")
        }
    }
    print("─────────────────────────────────────────\n")
}
