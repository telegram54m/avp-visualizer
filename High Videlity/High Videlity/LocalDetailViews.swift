//
//  LocalDetailViews.swift
//  High Videlity
//
//  Drill-down detail views for the Local Library — pushed onto the
//  Local source's NavigationStack when the user single-clicks an
//  album or artist card. Same visual vocabulary as the Apple Music
//  detail views (hero block + track list) but built against
//  `LibraryEntry` instead of MusicKit models, since local files
//  carry no streamable IDs.
//
//  Tap a row to load + play it through the visualizer. The hero
//  also has a Play button that loads the first track.
//

#if os(macOS)
import SwiftUI

// MARK: - Local Album Detail

struct LocalAlbumDetailView: View {
    let title: String
    let subtitle: String
    let tracks: [LibraryEntry]
    let appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                Divider()
                trackList
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 880, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(title)
        .navigationSubtitle("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 20) {
            LocalArtTile(hashSeed: title + subtitle, size: 180, cornerRadius: 10)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    Button {
                        Task { await appModel.playLocalEntries(tracks, startAt: 0) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(tracks.isEmpty)
                    Button {
                        Task { await appModel.queueLastLocalEntries(tracks) }
                    } label: {
                        Label("Add to Queue", systemImage: "text.append")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(tracks.isEmpty)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Tracks rendered in album order — disc 1 first, then disc 2,
    /// ordered by track number within each disc. Tracks without a
    /// track-number tag fall to the bottom of their disc, sorted by
    /// title. This is the order the user expects on an album detail
    /// view; the parent library's "All Songs" alphabetical default
    /// is wrong here.
    private var orderedTracks: [LibraryEntry] {
        tracks.sorted { lhs, rhs in
            let lDisc = lhs.discNumber ?? 1
            let rDisc = rhs.discNumber ?? 1
            if lDisc != rDisc { return lDisc < rDisc }
            // Untagged track numbers sink to the bottom of the disc.
            switch (lhs.trackNumber, rhs.trackNumber) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.title < rhs.title
            }
        }
    }

    private var trackList: some View {
        let ordered = orderedTracks
        return VStack(spacing: 2) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { idx, entry in
                LocalDetailTrackRow(
                    index: entry.trackNumber ?? (idx + 1),
                    entry: entry,
                    contextEntries: ordered,
                    showArtist: false,
                    appModel: appModel
                )
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}

// MARK: - Local Artist Detail

struct LocalArtistDetailView: View {
    let name: String
    let tracks: [LibraryEntry]
    let appModel: AppModel

    /// Albums grouped from the artist's tracks. Preserves first-
    /// appearance order so the list matches what the user sees in
    /// the library page's album row.
    private var albums: [(album: String, tracks: [LibraryEntry])] {
        var order: [String] = []
        var byAlbum: [String: [LibraryEntry]] = [:]
        for t in tracks {
            let key = t.album ?? "Unknown Album"
            if byAlbum[key] == nil {
                order.append(key)
                byAlbum[key] = []
            }
            byAlbum[key]?.append(t)
        }
        return order.map { ($0, byAlbum[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                Divider()
                albumSections
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 880, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(name)
        .navigationSubtitle("\(tracks.count) song\(tracks.count == 1 ? "" : "s") · \(albums.count) album\(albums.count == 1 ? "" : "s")")
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 20) {
            LocalArtTile(hashSeed: name, size: 180, cornerRadius: 90)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    Button {
                        Task { await appModel.playLocalEntries(tracks, startAt: 0) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(tracks.isEmpty)
                    Button {
                        Task { await appModel.queueLastLocalEntries(tracks) }
                    } label: {
                        Label("Add to Queue", systemImage: "text.append")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(tracks.isEmpty)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var albumSections: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(albums, id: \.album) { group in
                let ordered = Self.albumOrdered(group.tracks)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        LocalArtTile(hashSeed: group.album + name, size: 36, cornerRadius: 4)
                        Text(group.album)
                            .font(.title3.weight(.semibold))
                        Text("· \(group.tracks.count)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    VStack(spacing: 2) {
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { idx, entry in
                            LocalDetailTrackRow(
                                index: entry.trackNumber ?? (idx + 1),
                                entry: entry,
                                contextEntries: ordered,
                                showArtist: false,
                                appModel: appModel
                            )
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }

    /// Album-order sort: disc number ascending, then track number
    /// ascending within each disc, with untagged-track-number rows
    /// sinking to the bottom of their disc sorted by title. Shared
    /// with [[LocalAlbumDetailView]] which uses the same ordering.
    fileprivate static func albumOrdered(_ tracks: [LibraryEntry]) -> [LibraryEntry] {
        tracks.sorted { lhs, rhs in
            let lDisc = lhs.discNumber ?? 1
            let rDisc = rhs.discNumber ?? 1
            if lDisc != rDisc { return lDisc < rDisc }
            switch (lhs.trackNumber, rhs.trackNumber) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.title < rhs.title
            }
        }
    }
}

// MARK: - Shared track row

/// Track row inside the local detail views. Numbered, click-to-play.
/// Lives here so the detail views share one row spec instead of each
/// inventing its own.
///
/// Tap plays this entry as part of the supplied `contextEntries`
/// list — when invoked from an album detail view, `contextEntries`
/// is the full album track list, so clicking track 3 plays track 3
/// and queues 4..N after it so the album auto-advances naturally.
private struct LocalDetailTrackRow: View {
    let index: Int
    let entry: LibraryEntry
    /// Full set of sibling tracks (e.g. the album or artist track
    /// list). The row uses this to queue the rest after the tapped
    /// entry so auto-advance follows the natural ordering.
    let contextEntries: [LibraryEntry]
    let showArtist: Bool
    let appModel: AppModel
    @State private var hovered = false

    var body: some View {
        Button {
            playInContext()
        } label: {
            HStack(spacing: 12) {
                Text("\(index)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if showArtist && !entry.artist.isEmpty {
                        Text(entry.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                ConflictBadge(entry: entry)
                if appModel.library.cachedURLs.contains(entry.fileURL) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Feature cache built")
                }
                Text(formatDuration(entry.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button {
                playInContext()
            } label: { Label("Play Now", systemImage: "play.fill") }
            Button {
                Task { await appModel.queueNextLocal(entry) }
            } label: { Label("Play Next", systemImage: "text.insert") }
            Button {
                Task { await appModel.queueLastLocal(entry) }
            } label: { Label("Add to Queue", systemImage: "text.append") }
        }
    }

    private func playInContext() {
        // Replace the queue with the album/artist track list starting
        // at this row, so subsequent tracks auto-advance naturally.
        // Fallback to single-entry queue if for some reason the
        // contextEntries doesn't contain this entry (shouldn't
        // happen, but defensive).
        if let idx = contextEntries.firstIndex(where: { $0.fileURL == entry.fileURL }) {
            Task { await appModel.playLocalEntries(contextEntries, startAt: idx) }
        } else {
            Task { await appModel.playLocalEntry(entry) }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
#endif
