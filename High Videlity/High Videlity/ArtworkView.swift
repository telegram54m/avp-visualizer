//
//  ArtworkView.swift
//  High Videlity
//
//  Small wrapper around AsyncImage for MusicKit's Artwork type.
//  Apple Music returns server-sized images via Artwork.url(width:height:);
//  this view requests one at the requested point size × 3 for retina
//  rasters and renders a rounded-corner placeholder while loading.
//
//  Use for Song / Album / Artist / Playlist rows. Artist artwork is
//  often nil for less-canonical artists — the placeholder handles that.
//

import SwiftUI
import MusicKit

struct ArtworkView: View {
    let artwork: Artwork?
    /// Logical (point) size of the rendered image. The fetched URL
    /// asks for 3× pixels for retina.
    let size: CGFloat
    /// Corner radius. Defaults to 4 — Apple Music's own UI uses
    /// roughly square-with-tiny-rounding for albums; 0 for sharp,
    /// `size / 2` for circular artist avatars.
    var cornerRadius: CGFloat = 4

    var body: some View {
        let pixel = Int(size * 3)
        ZStack {
            if let url = artwork?.url(width: pixel, height: pixel) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                    case .success(let img):
                        img
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
