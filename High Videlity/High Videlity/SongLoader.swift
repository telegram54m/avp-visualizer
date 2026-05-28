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
    ///   `.fileImporter` selection (or a security-scoped library
    ///   browser entry).
    ///
    /// Body runs on a detached background task because
    /// `AnalysisTimeline.analyze` on a full song is several seconds of
    /// synchronous DSP work. Without detaching, the call (made from
    /// MainActor-isolated AppModel.loadSong) beach-balls the UI for
    /// the duration of the analysis. Detached restores responsiveness.
    static func load(fileURL sourceURL: URL) async throws -> LoadedSong {
        try await Task.detached(priority: .userInitiated) {
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

            // Hash the SOURCE file (not the copied one — both contents
            // are identical at this point, but the source URL is what
            // the library browser knows about; future replays will
            // hash the same source path). Used to key the frame cache.
            //
            // Frame-cache check: if we've analyzed this file before
            // and the result still decodes (schema-compatible), we
            // skip the 30-second AnalysisTimeline.analyze pass and
            // return the cached timeline instead.
            if let hash = FrameFeatureCache.hashForFile(sourceURL),
               let cachedFrames = FrameFeatureCache.cachedFrames(forHash: hash) {
                return LoadedSong(frames: cachedFrames, audioURL: cachedURL)
            }

            // Cache miss → fresh analysis. Store the result so the
            // next replay (or this session if the user picks the same
            // song again) hits the cache.
            let audio = try AudioFileDecoder.decode(contentsOf: cachedURL)
            let frames = AnalysisTimeline.analyze(audio)
            if let hash = FrameFeatureCache.hashForFile(sourceURL) {
                FrameFeatureCache.storeFrames(frames, forHash: hash)
            }
            return LoadedSong(frames: frames, audioURL: cachedURL)
        }.value
    }
}
