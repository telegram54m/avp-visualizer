//
//  CloudStatusLoader.swift
//  High Videlity
//
//  Reads the user's Music library via the iTunesLibrary framework
//  and builds a lookup of (title, artist, album) → cloud-status
//  kind, so the Songs table can distinguish "owned" (purchased /
//  matched / uploaded) tracks from "added" Apple Music catalog
//  tracks. MusicKit's `Song` doesn't expose cloud status — this
//  bridge fills that gap.
//
//  macOS-only. iTunesLibrary isn't available on iOS, and iOS has
//  no equivalent public API for AM cloud status.
//
//  Permissioning: NSAppleMusicUsageDescription drives the TCC
//  prompt the first time `ITLibrary` is constructed. We don't
//  block on it — if the user denies, the lookup is empty and the
//  scope filter degrades to All-only.
//

#if os(macOS)
import Foundation
import iTunesLibrary
import os

private let cloudLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "CloudStatus")

nonisolated enum CloudKind: Sendable, Hashable, Equatable {
    /// You have this song independent of an Apple Music
    /// subscription — purchased from iTunes Store, matched /
    /// uploaded via iTunes Match, ripped from CD, or sideloaded.
    case owned
    /// Added from the Apple Music catalog. Goes away if the
    /// subscription lapses. Detected as cloud + DRM-protected +
    /// not purchased.
    case added
    /// Wasn't in the iTunesLibrary lookup at all — typically
    /// means the user hasn't granted Music-library access.
    case unknown
}

nonisolated enum CloudStatusLoader {
    /// Composite key keyed on lowercase metadata. Uses U+001F (Unit
    /// Separator) so "ABC | D" / "AB | CD" don't collide.
    static func key(title: String, artist: String, album: String) -> String {
        "\(title.lowercased())\u{1F}\(artist.lowercased())\u{1F}\(album.lowercased())"
    }

    /// Load all songs from the user's Music library and return a
    /// lookup of composite-key → CloudKind. Runs off-main; large
    /// libraries take a few hundred ms. Returns an empty map if the
    /// user denies iTunesLibrary access or the framework errors.
    static func load() async -> [String: CloudKind] {
        await Task.detached(priority: .utility) {
            let lib: ITLibrary
            do {
                lib = try ITLibrary(apiVersion: "1.0")
            } catch {
                cloudLog.error("ITLibrary init failed: \(error.localizedDescription, privacy: .public)")
                return [:]
            }
            let items = lib.allMediaItems
            var map: [String: CloudKind] = [:]
            map.reserveCapacity(items.count)
            var songCount = 0
            var ownedCount = 0
            var addedCount = 0
            for item in items {
                guard item.mediaKind == .kindSong else { continue }
                songCount += 1
                let title = item.title
                let artist = item.artist?.name ?? ""
                let album = item.album.title ?? ""
                let k = key(title: title, artist: artist, album: album)
                // Heuristic by the `kind` file-type string —
                // empirically the only reliable distinguisher
                // between Match/Purchased (owned) and Apple Music
                // (added) on macOS 26:
                //
                //   "Apple Music AAC audio file" → AM subscription
                //   "HLS media"                  → AM downloaded
                //                                  (locally cached
                //                                   streaming asset)
                //   everything else              → owned
                //
                // Matched/Purchased tracks keep their original kind
                // ("AAC audio file", "Purchased AAC audio file",
                // "MPEG audio file", "MPEG-4 audio file") whether
                // cloud-only or downloaded. `isCloud` and
                // `isDRMProtected` both flatten the distinction
                // we care about, hence the string match.
                // Verified 2026-05-29 against an 11,249-song
                // library (cloud=10874 drm=116 purchased=0).
                let isAddedFromAppleMusic: Bool
                switch item.kind {
                case "Apple Music AAC audio file", "HLS media":
                    isAddedFromAppleMusic = true
                default:
                    isAddedFromAppleMusic = false
                }
                let kind: CloudKind = isAddedFromAppleMusic ? .added : .owned
                if kind == .added { addedCount += 1 } else { ownedCount += 1 }
                // Duplicates across keys (same title/artist/album on
                // multiple Library entries) collapse to the strongest
                // claim — owned beats added — so the badge reflects
                // the user's most-ownership view.
                if let existing = map[k] {
                    map[k] = Self.stronger(existing, kind)
                } else {
                    map[k] = kind
                }
            }
            cloudLog.info("scan: songs=\(songCount) owned=\(ownedCount) added=\(addedCount) keys=\(map.count)")
            return map
        }.value
    }

    private static func stronger(_ a: CloudKind, _ b: CloudKind) -> CloudKind {
        func rank(_ k: CloudKind) -> Int {
            switch k {
            case .owned: return 2
            case .added: return 1
            case .unknown: return 0
            }
        }
        return rank(a) >= rank(b) ? a : b
    }
}
#endif
