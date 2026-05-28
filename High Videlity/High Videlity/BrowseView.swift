//
//  BrowseView.swift
//  High Videlity
//
//  Discovery surface. Four tabs:
//    • For You — Apple Music's personal recommendations
//      (mixed playlists / albums / stations)
//    • Top Songs — storefront-wide Top 30 (most-played)
//    • Top Albums — same
//    • Top Playlists — same
//
//  Sheet on macOS for now (Phase 7 will sidebar-ify). Per-row actions
//  reuse Phase 1's Play / Play Next / Add to Queue. Album/Playlist
//  taps drill through to their existing detail views.
//
//  For You cards render horizontally inside each recommendation
//  section so the user can scan across multiple sections without
//  scrolling vertically through hundreds of items.
//

import SwiftUI
import MusicKit

struct BrowseView: View {
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case forYou = "For You"
        case songs = "Top Songs"
        case albums = "Top Albums"
        case playlists = "Top Playlists"
        var id: String { rawValue }
    }

    @State private var selected: Tab = .forYou

    @State private var recommendations: [MusicPersonalRecommendation] = []
    @State private var charts: MusicKitController.Charts = .init()
    @State private var loading: Set<Tab> = []
    @State private var loadedOnce: Set<Tab> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $selected) {
                    ForEach(Tab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Divider()

                Group {
                    switch selected {
                    case .forYou:    forYouList
                    case .songs:     topSongsList
                    case .albums:    topAlbumsList
                    case .playlists: topPlaylistsList
                    }
                }
            }
            .navigationTitle("Browse")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        loadedOnce.remove(selected)
                        Task { await loadIfNeeded(selected, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload")
                }
            }
        }
        .frame(minWidth: 560, minHeight: 540)
        .task { await loadIfNeeded(selected) }
        .onChange(of: selected) { _, new in
            Task { await loadIfNeeded(new) }
        }
    }

    // MARK: - For You

    @ViewBuilder
    private var forYouList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if loading.contains(.forYou) && recommendations.isEmpty {
                    ProgressView().padding()
                } else if recommendations.isEmpty {
                    Text("No recommendations available right now.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(recommendations, id: \.id) { rec in
                        recommendationSection(rec)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func recommendationSection(_ rec: MusicPersonalRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rec.title ?? "Recommended for You")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(rec.items.enumerated()), id: \.offset) { _, item in
                        recommendationCard(item)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// Renders a single recommendation card. The recommendation item
    /// type is an enum-like over the Apple Music catalog kinds; we
    /// handle Album / Playlist / Station explicitly and skip rarer
    /// kinds (MusicVideo, etc.) to avoid unhandled empty cards.
    @ViewBuilder
    private func recommendationCard(_ item: MusicPersonalRecommendation.Item) -> some View {
        switch item {
        case .album(let album):
            NavigationLink {
                AlbumDetailView(album: album)
            } label: {
                cardLabel(title: album.title, subtitle: album.artistName, art: album.artwork)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { Task { await appModel.musicKit.play(album: album) } } label: {
                    Label("Play Album", systemImage: "play.fill")
                }
            }
        case .playlist(let playlist):
            NavigationLink {
                PlaylistDetailView(playlist: playlist)
            } label: {
                cardLabel(title: playlist.name, subtitle: playlist.curatorName ?? "", art: playlist.artwork)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { Task { await appModel.musicKit.play(playlist: playlist) } } label: {
                    Label("Play Playlist", systemImage: "play.fill")
                }
            }
        case .station(let station):
            // Stations don't have a detail view in this app yet —
            // tapping plays the station directly.
            Button {
                Task { await appModel.musicKit.play(station: station) }
            } label: {
                cardLabel(title: station.name, subtitle: "Station", art: station.artwork)
            }
            .buttonStyle(.plain)
        @unknown default:
            EmptyView()
        }
    }

    private func cardLabel(title: String, subtitle: String, art: Artwork?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            artwork(art, size: 120)
            Text(title)
                .font(.subheadline)
                .lineLimit(2)
                .frame(width: 120, alignment: .leading)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
            }
        }
        .frame(width: 120)
    }

    // MARK: - Top charts

    @ViewBuilder
    private var topSongsList: some View {
        chartsList(tab: .songs, items: charts.songs) { song in
            songRow(song)
        }
    }

    @ViewBuilder
    private var topAlbumsList: some View {
        chartsList(tab: .albums, items: charts.albums) { album in
            albumRow(album)
        }
    }

    @ViewBuilder
    private var topPlaylistsList: some View {
        chartsList(tab: .playlists, items: charts.playlists) { pl in
            playlistRow(pl)
        }
    }

    /// Generic chart list: loading state + empty state + ForEach rows.
    /// Type-parameterized so each tab passes its own typed row builder.
    @ViewBuilder
    private func chartsList<Item: Identifiable, Row: View>(
        tab: Tab,
        items: [Item],
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if loading.contains(tab) && items.isEmpty {
                    ProgressView().padding()
                } else if items.isEmpty {
                    Text("No chart data available right now.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    // MARK: - Row builders (same actions as Phase 1 / Phase 4)

    private func songRow(_ song: Song) -> some View {
        Button {
            Task { await appModel.playAppleMusicSong(song) }
        } label: {
            HStack(spacing: 10) {
                artwork(song.artwork, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).lineLimit(1)
                    Text(song.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { Task { await appModel.playAppleMusicSong(song) } } label: {
                Label("Play Now", systemImage: "play.fill")
            }
            Button { Task { await appModel.musicKit.queueNext(song) } } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { Task { await appModel.musicKit.queueLast(song) } } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }
    }

    private func albumRow(_ album: Album) -> some View {
        NavigationLink {
            AlbumDetailView(album: album)
        } label: {
            HStack(spacing: 10) {
                artwork(album.artwork, size: 56)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title).lineLimit(1)
                    Text(album.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { Task { await appModel.musicKit.play(album: album) } } label: {
                Label("Play Album", systemImage: "play.fill")
            }
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist)
        } label: {
            HStack(spacing: 10) {
                artwork(playlist.artwork, size: 56)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).lineLimit(1)
                    if let curator = playlist.curatorName, !curator.isEmpty {
                        Text(curator)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { Task { await appModel.musicKit.play(playlist: playlist) } } label: {
                Label("Play Playlist", systemImage: "play.fill")
            }
        }
    }

    @ViewBuilder
    private func artwork(_ art: Artwork?, size: CGFloat) -> some View {
        if let art, let url = art.url(width: Int(size * 2), height: Int(size * 2)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                )
        }
    }

    // MARK: - Loading

    private func loadIfNeeded(_ tab: Tab, force: Bool = false) async {
        if !force, loadedOnce.contains(tab) { return }
        guard !loading.contains(tab) else { return }
        loading.insert(tab)
        defer { loading.remove(tab) }

        switch tab {
        case .forYou:
            recommendations = await appModel.musicKit.recommendations()
        case .songs, .albums, .playlists:
            // Top-charts fetch returns all three lists together — only
            // hit it once and mark all three tabs as loaded.
            charts = await appModel.musicKit.charts()
            loadedOnce.insert(.songs)
            loadedOnce.insert(.albums)
            loadedOnce.insert(.playlists)
        }
        loadedOnce.insert(tab)
    }
}
