//
//  ArtworkView.swift
//  High Videlity
//
//  Small wrapper around MusicKit's Artwork type that renders a
//  rounded-corner thumbnail.
//
//  MEMORY (2026-05-31): this view previously used a bare `AsyncImage`
//  requesting 3× pixels. `AsyncImage` does not pool decoded bitmaps
//  across instances, so every re-entry of a large artwork surface
//  (the AM home feed, the AM library list) re-decoded every visible
//  thumbnail into a fresh in-memory bitmap that was never reclaimed —
//  the root cause of resident memory climbing 75–150 MB on every
//  Apple-Music ↔ Library navigation and eventually OOM-ing the app.
//
//  Fix: a process-wide, cost-bounded `NSCache` of decoded images keyed
//  by the resolved server URL (`ArtworkImageCache`), plus a 2× (not 3×)
//  pixel request — retina-2× is plenty for ≤56 pt thumbnails and
//  quarters the decoded byte cost vs 3×. Re-entering a surface now hits
//  the cache instead of re-decoding, and total artwork memory is
//  capped regardless of how many times surfaces are revisited.
//
//  Use for Song / Album / Artist / Playlist rows. Artist artwork is
//  often nil for less-canonical artists — the placeholder handles that.
//

import SwiftUI
import MusicKit

#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#endif

/// Process-wide decoded-artwork cache, bounded by total decoded byte
/// cost so navigation between large artwork grids can't grow memory
/// without limit. Keyed by the resolved server URL (Apple Music's
/// `Artwork.url(width:height:)` is deterministic for a given size, so
/// the same thumbnail across many views shares one decoded bitmap).
@MainActor
final class ArtworkImageCache {
    static let shared = ArtworkImageCache()

    private let cache = NSCache<NSURL, PlatformImage>()
    /// De-dupe concurrent fetches of the same URL (a grid scrolling
    /// fast can request the same artwork from many cells at once).
    private var inFlight: [NSURL: Task<PlatformImage?, Never>] = [:]

    private init() {
        // 48 MB ceiling on decoded artwork + a hard count cap. The
        // cost attached in `load` is the TRUE decoded ARGB byte size
        // (pixel w×h×4 read from the backing CGImage — not the point
        // size, which under-counts retina images 4× and let the cap
        // never actually evict). Count cap is a backstop because
        // NSCache's cost eviction is advisory/lazy. ~400 thumbnails
        // at 64–128px is plenty of working set; older ones evict.
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 400
    }

    /// Synchronous cache peek — lets the view render instantly on a
    /// hit without a Task round-trip (the common case once warm).
    func cached(_ url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Fetch + decode (or return the cached image). De-duplicated
    /// against any in-flight fetch for the same URL.
    func load(_ url: URL) async -> PlatformImage? {
        let key = url as NSURL
        if let hit = cache.object(forKey: key) { return hit }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task { () -> PlatformImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = PlatformImage(data: data) else {
                return nil
            }
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            cache.setObject(image, forKey: key, cost: Self.byteCost(image))
        }
        return image
    }

    /// True decoded byte cost = backing-CGImage pixel width × height × 4
    /// (RGBA). Reading the CGImage (not `image.size`, which is in
    /// points) is what makes the `totalCostLimit` accurate — otherwise
    /// a 2×-retina 128px thumbnail is counted as 64×64 instead of
    /// 128×128 and the cache holds ~4× more than its stated ceiling.
    private static func byteCost(_ image: PlatformImage) -> Int {
        #if canImport(AppKit)
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return max(1, cg.width * cg.height * 4)
        }
        #else
        if let cg = image.cgImage {
            return max(1, cg.width * cg.height * 4)
        }
        #endif
        let s = image.size
        return max(1, Int(s.width * s.height) * 4)
    }
}

struct ArtworkView: View {
    let artwork: Artwork?
    /// Logical (point) size of the rendered image. The fetched URL
    /// asks for 2× pixels for retina.
    let size: CGFloat
    /// Corner radius. Defaults to 4 — Apple Music's own UI uses
    /// roughly square-with-tiny-rounding for albums; 0 for sharp,
    /// `size / 2` for circular artist avatars.
    var cornerRadius: CGFloat = 4

    @State private var loaded: PlatformImage?

    var body: some View {
        let pixel = Int(size * 2)
        let url = artwork?.url(width: pixel, height: pixel)
        ZStack {
            if let img = loaded {
                imageView(img)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // `.task(id:)` re-fires when the URL changes (row recycling in a
        // LazyVStack reuses the view with new content), and is cancelled
        // automatically when the view disappears.
        .task(id: url) {
            guard let url else {
                loaded = nil
                return
            }
            // Instant hit when warm — avoids a frame of placeholder.
            if let hit = ArtworkImageCache.shared.cached(url) {
                loaded = hit
                return
            }
            loaded = nil
            let img = await ArtworkImageCache.shared.load(url)
            // The id-bound task is cancelled on URL change, but guard
            // anyway so a late return can't stomp a newer image.
            if !Task.isCancelled {
                loaded = img
            }
        }
    }

    @ViewBuilder
    private func imageView(_ img: PlatformImage) -> some View {
        #if canImport(AppKit)
        Image(nsImage: img).resizable().scaledToFill()
        #else
        Image(uiImage: img).resizable().scaledToFill()
        #endif
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .font(.system(size: size * 0.4))
            }
    }
}
