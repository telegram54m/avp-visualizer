//
//  AppleMusicStore.swift
//  High Videlity
//
//  Long-lived, app-scoped @Observable home for the Apple Music landing
//  page's feed + library data. Owns:
//   • the For-You recommendations + Top-Charts feed,
//   • the user's full (paginated) library — songs / albums / artists /
//     playlists,
//   • per-section loaded/loading flags so the load methods are
//     idempotent.
//
//  WHY THIS EXISTS: `AppleMusicHomeView` used to hold all of this in
//  per-view `@State`. SwiftUI destroys @State when the view leaves the
//  hierarchy, so every navigation back to the landing page re-fetched
//  and re-held the recommendations, charts, and (potentially 11k-item)
//  full library — hydrated MusicKit value types that aren't free. The
//  agent's "cause A2" footprint item. Hoisting into one instance held
//  by AppModel (mirrors the existing `let library = LibraryStore()`)
//  means load-once, reuse across navigations, single retained copy.
//
//  macOS-only — the AM home surface is macOS-only today. A thin stub
//  on other platforms keeps AppModel free of #if-guards around the
//  property.
//

#if os(macOS)
import Foundation
import MusicKit

@MainActor
@Observable
final class AppleMusicStore {

    // MARK: - Feed (For You + Top Charts)

    var recommendations: [MusicPersonalRecommendation] = []
    var charts: MusicKitController.Charts = .init()
    private(set) var feedLoaded = false
    private(set) var feedLoading = false

    // MARK: - Full library (paginated)

    var librarySongs: [Song] = []
    var libraryAlbums: [Album] = []
    var libraryArtists: [Artist] = []
    var libraryPlaylists: [Playlist] = []
    private(set) var libraryLoaded = false
    private(set) var libraryLoading = false

    /// True when neither library nor an in-flight load has produced
    /// anything yet — used by the view's empty-state branch.
    var allLibraryEmpty: Bool {
        librarySongs.isEmpty
            && libraryAlbums.isEmpty
            && libraryArtists.isEmpty
            && libraryPlaylists.isEmpty
    }

    // MARK: - Loading

    /// Fetch recommendations + charts once (idempotent unless `force`).
    /// The caller passes its `MusicKitController` so the store doesn't
    /// hold a back-reference (mirrors LibraryStore's provider-as-param
    /// convention — keeps the dependency one-directional).
    func loadFeed(mk: MusicKitController, force: Bool = false) async {
        // Only gate on authorization. Catalog-subscription state
        // resolves async; gating on it would race with the observer
        // and stall the feed until the user manually hit Refresh.
        guard mk.isAuthorized else { return }
        if !force && feedLoaded { return }
        guard !feedLoading else { return }
        feedLoading = true
        defer { feedLoading = false }
        async let recs = mk.recommendations()
        async let chartsResult = mk.charts()
        recommendations = await recs
        charts = await chartsResult
        // Only consider the feed "loaded" if something actually came
        // back. Catalog recommendations + charts routinely return empty
        // in the split second between authorization landing and the
        // subscription status resolving right after launch. If we marked
        // feedLoaded=true on that empty result, the `feedLoaded` guard
        // would block the canPlay / isAuthorized onChange recovery
        // retries — leaving the landing page permanently blank for the
        // session. (The old per-view @State self-healed by resetting on
        // re-navigation; persisting the flag on the store removed that
        // safety net, so we gate the flag on real content instead.)
        feedLoaded = !recommendations.isEmpty
            || !charts.songs.isEmpty
            || !charts.albums.isEmpty
            || !charts.playlists.isEmpty
    }

    /// Stream the full library in 100-item pages across all four
    /// buckets in parallel; rows progressively fill as pages arrive.
    /// Idempotent unless `force` (which resets the arrays first).
    func loadLibrary(mk: MusicKitController, force: Bool = false) async {
        guard mk.isAuthorized else { return }
        if !force && libraryLoaded { return }
        guard !libraryLoading else { return }
        if force {
            librarySongs = []
            libraryAlbums = []
            libraryArtists = []
            libraryPlaylists = []
        }
        libraryLoading = true
        defer { libraryLoading = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await mk.libraryAllSongs { page in self.librarySongs.append(contentsOf: page) }
            }
            group.addTask { @MainActor in
                await mk.libraryAllAlbums { page in self.libraryAlbums.append(contentsOf: page) }
            }
            group.addTask { @MainActor in
                await mk.libraryAllArtists { page in self.libraryArtists.append(contentsOf: page) }
            }
            group.addTask { @MainActor in
                await mk.libraryAllPlaylists { page in self.libraryPlaylists.append(contentsOf: page) }
            }
        }
        libraryLoaded = true
    }
}

#else  // !os(macOS)

/// Stub so cross-platform AppModel can hold `let appleMusic` without
/// #if guards. The AM home surface is macOS-only today.
@MainActor
@Observable
final class AppleMusicStore {}

#endif
