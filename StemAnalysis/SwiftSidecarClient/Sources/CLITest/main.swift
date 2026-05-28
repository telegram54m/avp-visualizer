//
//  main.swift — CLI driver for StemFeatureProvider.
//
//  Spawns the sidecar, runs a ping, separates one audio file, prints
//  per-stem feature shapes. Mirrors smoke_test_sidecar.py but on the
//  Swift side, proving the end-to-end IPC + decoding works.
//
//  Usage:
//      swift run stem-sidecar-test /abs/path/to/song.m4a
//

import Foundation
import StemSidecarClient
import MusicAppNowPlaying

@main
struct CLITest {
    static func main() async {
        let args = CommandLine.arguments

        // Resolve audio source. Two modes:
        //   • Explicit path argument (Phase 1.1 / 1.2 mode)
        //   • No argument → query Music.app for currently-playing track
        //     (Phase 1.3 — proves the integration end-to-end)
        let resolved: String
        var cacheKey: String
        var titleForCache: String?
        var artistForCache: String?

        if args.count >= 2 {
            let raw = args[1]
            resolved = URL(fileURLWithPath: raw).standardizedFileURL.path
            cacheKey = "cli-test-\(URL(fileURLWithPath: resolved).deletingPathExtension().lastPathComponent)"
            print("audio source: explicit path")
            print("  path: \(resolved)")
        } else {
            print("audio source: Music.app now-playing")
            let nowPlaying = MusicAppNowPlaying()
            do {
                let state = try nowPlaying.query()
                switch state {
                case .ready(let track):
                    guard let url = track.fileURL else {
                        print("  ERROR: ready state but nil fileURL? \(track)")
                        exit(2)
                    }
                    resolved = url.path
                    // Music.app's persistentID is a stable per-track ID
                    // in the user's library — perfect cache key fallback
                    // when Shazam hasn't fired yet.
                    cacheKey = "musicapp-pid-\(track.persistentID)"
                    titleForCache = track.title
                    artistForCache = track.artist
                    print("  title:    \(track.title)")
                    print("  artist:   \(track.artist)")
                    print("  album:    \(track.album)")
                    print("  pid:      \(track.persistentID)")
                    print("  duration: \(track.durationSeconds)s")
                    print("  position: \(track.playerPositionSeconds)s")
                    print("  playing:  \(track.isPlaying)")
                    print("  path:     \(resolved)")
                case .streamingOnly(let track):
                    print("  ERROR: track '\(track.title)' is streaming-only (no local file). " +
                          "Pass a local file path as argument, or set up the live-capture fallback.")
                    exit(2)
                case .noTrack:
                    print("  ERROR: Music.app is running but no track is loaded.")
                    exit(2)
                case .musicAppNotRunning:
                    print("  ERROR: Music.app is not running. Start Music and play a track, " +
                          "or pass a file path as the first argument.")
                    exit(2)
                }
            } catch {
                print("  ERROR: \(error)")
                exit(2)
            }
        }

        let provider = StemFeatureProvider()
        do {
            print("starting sidecar…")
            let t0 = Date()
            try await provider.start()
            print("  ready in \(String(format: "%.2f", -t0.timeIntervalSinceNow))s")

            print("ping…")
            let t1 = Date()
            try await provider.ping()
            print("  pong in \(Int(-t1.timeIntervalSinceNow * 1000))ms")

            print("separate (force_refresh = fresh compute) …")
            print("  cache_key: \(cacheKey)")
            let t2 = Date()
            let fresh = try await provider.separate(
                filePath: resolved,
                cacheKey: cacheKey,
                forceRefresh: true,
                title: titleForCache,
                artist: artistForCache
            )
            let freshElapsed = -t2.timeIntervalSinceNow
            print("  returned in \(String(format: "%.1f", freshElapsed))s  from_cache=\(fresh.fromCache)")
            print("  model:       \(fresh.model)")
            print("  sample_rate: \(fresh.sampleRate)")
            print("  frame_rate:  \(fresh.frameRate)")
            print("  duration:    \(fresh.durationSeconds.map { "\($0)s" } ?? "?")")
            print("  timing:      sep=\(fresh.timing.separationSeconds)s feat=\(fresh.timing.featureSeconds)s")
            for stemName in ["drums", "bass", "other", "vocals"] {
                guard let stem = fresh.stems[stemName] else { continue }
                let nOnsets = stem.onset.lazy.filter { $0 }.count
                print("    \(stemName.padding(toLength: 8, withPad: " ", startingAt: 0)) " +
                      "n_frames=\(stem.nFrames)  chroma=(\(stem.chromagram.count), \(stem.chromagram.first?.count ?? 0))  " +
                      "loudness=\(stem.loudness.count)  onsets=\(nOnsets)")
            }

            print("\nseparate (cache hit) …")
            let t3 = Date()
            let cached = try await provider.separate(
                filePath: resolved, cacheKey: cacheKey)
            let cachedElapsed = -t3.timeIntervalSinceNow
            print("  returned in \(Int(cachedElapsed * 1000))ms  from_cache=\(cached.fromCache)")
            // Sanity check: same shape between fresh + cached
            let freshDrums = fresh.stems["drums"]?.nFrames ?? -1
            let cachedDrums = cached.stems["drums"]?.nFrames ?? -2
            print("  drums n_frames: fresh=\(freshDrums) cached=\(cachedDrums) \(freshDrums == cachedDrums ? "✓" : "✗ MISMATCH")")

            print("\ncache_stats …")
            let stats = try await provider.cacheStats()
            print("  entries:  \(stats.entries)")
            print("  size:     \(String(format: "%.2f", Double(stats.sizeBytes) / 1_048_576)) MB")
            print("  path:     \(stats.cachePath)")
            print("  protocol: v\(stats.protocolVersion)")

            print("\nstopping…")
            await provider.stop()
            print("done.")
        } catch {
            print("ERROR: \(error)")
            await provider.stop()
            exit(2)
        }
    }
}
