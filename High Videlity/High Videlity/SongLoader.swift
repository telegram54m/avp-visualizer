//
//  SongLoader.swift
//  High Videlity
//
//  Fetches a song preview, runs the AudioAnalysis pipeline on it, and keeps
//  the audio clip so it can be played back alongside the visualization.
//

import AudioAnalysis
import Foundation

enum SongLoader {

    /// A fetched-and-analyzed song: the feature timeline that drives the
    /// visuals, plus the on-disk audio clip kept for playback.
    struct LoadedSong {
        let frames: [FeatureFrame]
        let audioURL: URL
    }

    /// Fetches a song preview, analyzes it, and keeps the audio file.
    /// Network + decode + analysis run off the main actor.
    static func load(_ term: String) async throws -> LoadedSong {
        let results = try await PreviewFetcher.search(term, limit: 5)
        guard let song = results.first else { throw PreviewFetcher.FetchError.noResults }

        let audioURL = try await PreviewFetcher.downloadPreview(from: song.previewURL)
        let audio = try AudioFileDecoder.decode(contentsOf: audioURL)
        let frames = AnalysisTimeline.analyze(audio)
        return LoadedSong(frames: frames, audioURL: audioURL)
    }

    /// Loads a local audio file, copies it into the app's cache so it
    /// survives security-scoped resource access ending, analyzes it, and
    /// returns the full-song timeline.
    ///
    /// - Parameter sourceURL: a security-scoped URL from a SwiftUI
    ///   `.fileImporter` selection.
    static func load(fileURL sourceURL: URL) async throws -> LoadedSong {
        // Security-scoped URLs from `.fileImporter` require explicit access.
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        // Copy into the cache directory so the working URL stays valid for
        // playback even after the import scope closes. Unique filename so
        // re-imports don't clash.
        let cacheDir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!
        let ext = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension
        let cachedURL = cacheDir.appendingPathComponent(
            "imported-\(UUID().uuidString).\(ext)"
        )
        try FileManager.default.copyItem(at: sourceURL, to: cachedURL)

        let audio = try AudioFileDecoder.decode(contentsOf: cachedURL)
        let frames = AnalysisTimeline.analyze(audio)
        return LoadedSong(frames: frames, audioURL: cachedURL)
    }
}
