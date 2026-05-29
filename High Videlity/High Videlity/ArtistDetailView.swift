//
//  ArtistDetailView.swift
//  High Videlity
//
//  Drill-down view for an Artist from search results. Header (large
//  artwork + name), then Top Songs list (tappable to play / queue)
//  and Albums grid (tappable into AlbumDetailView). Relationships
//  fetched via `Artist.with([.topSongs, .albums])` on appear.
//

import SwiftUI
import MusicKit

#if !os(visionOS)
struct ArtistDetailView: View {

    @Environment(AppModel.self) private var appModel
    let artist: Artist

    @State private var detailed: Artist?
    @State private var isLoading = false
    @State private var loadError: String?
    /// Artist bio sourced from Wikipedia's summary REST endpoint.
    /// nil while loading, nil after a failed lookup (no Wikipedia
    /// page found or disambiguation couldn't be resolved). When
    /// non-nil, drives the About section above Top Songs.
    @State private var bioText: String?
    /// Wikipedia URL for the bio source — used by the "Read on
    /// Wikipedia" link in the About card.
    @State private var bioPageURL: URL?
    /// Tracks whether the user has expanded the bio. Wikipedia
    /// summaries can run several paragraphs; the default render
    /// shows ~6 lines with a "Read more" affordance.
    @State private var bioExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHero(
                    eyebrow: "ARTIST",
                    title: artist.name,
                    subtitle: nil,
                    metadata: genreLine,
                    artwork: artist.artwork,
                    artworkSize: 160,
                    artworkIsCircular: true,
                    tintColor: artist.artwork?.backgroundColor
                ) {
                    // Inline bio inside the hero's right column —
                    // saves the vertical real estate the standalone
                    // About card was using. Wikipedia link stays
                    // visible so the source is always credited.
                    inlineBio
                }
                VStack(alignment: .leading, spacing: 20) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else if let err = loadError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    } else {
                        topSongsSection
                        albumsSection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .task {
            await loadDetail()
        }
    }

    /// Inline bio block rendered as the hero's bottomContent. Two
    /// lines clamped by default with "Read more" — the hero already
    /// commits more height than other detail surfaces because of
    /// the 160pt circular artwork, so we keep the bio tight by
    /// default to leave room for Top Songs above the fold. The
    /// Wikipedia link is shown inline (small, secondary) so the
    /// source is credited without taking its own row.
    @ViewBuilder
    private var inlineBio: some View {
        if let bio = bioText {
            VStack(alignment: .leading, spacing: 4) {
                Text(bio)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(bioExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if bio.count > 220 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                bioExpanded.toggle()
                            }
                        } label: {
                            Text(bioExpanded ? "Show less" : "Read more")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    if let url = bioPageURL {
                        Link(destination: url) {
                            HStack(spacing: 3) {
                                Text("Wikipedia")
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2)
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var genreLine: String? {
        guard let genres = artist.genreNames, !genres.isEmpty else { return nil }
        return genres.joined(separator: " · ")
    }

    @ViewBuilder
    private var topSongsSection: some View {
        if let songs = detailed?.topSongs, !songs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Top Songs").font(.headline)
                VStack(spacing: 4) {
                    ForEach(songs, id: \.id) { song in
                        topSongRow(song)
                    }
                }
            }
        }
    }

    private func topSongRow(_ song: Song) -> some View {
        MediaRow(
            artwork: song.artwork,
            title: song.title,
            subtitle: song.albumTitle,
            artworkSize: 40,
            accessory: .play,
            hoverActions: [
                MediaRowAction(systemImage: "text.insert", help: "Play Next") {
                    Task { await appModel.musicKit.queueNext(song) }
                },
                MediaRowAction(systemImage: "text.append", help: "Add to Queue") {
                    Task { await appModel.musicKit.queueLast(song) }
                }
            ],
            contextActions: [
                MediaRowAction(systemImage: "play.fill", help: "Play Now") {
                    Task { await appModel.playAppleMusicSong(song) }
                },
                MediaRowAction(systemImage: "text.insert", help: "Play Next") {
                    Task { await appModel.musicKit.queueNext(song) }
                },
                MediaRowAction(systemImage: "text.append", help: "Add to Queue") {
                    Task { await appModel.musicKit.queueLast(song) }
                }
            ]
        ) {
            Task { await appModel.playAppleMusicSong(song) }
        }
    }

    @ViewBuilder
    private var albumsSection: some View {
        if let albums = detailed?.albums, !albums.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Albums").font(.headline)
                // 3-column grid on macOS; SwiftUI's adaptive grid
                // fills as many columns as fit the container.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(albums, id: \.id) { album in
                        albumGridCell(album)
                    }
                }
            }
        }
    }

    private func albumGridCell(_ album: Album) -> some View {
        NavigationLink {
            AlbumDetailView(album: album)
                .environment(appModel)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ArtworkView(artwork: album.artwork, size: 130, cornerRadius: 6)
                Text(album.title)
                    .font(.caption)
                    .lineLimit(2)
                if let date = album.releaseDate {
                    let fmt = DateFormatter()
                    Text({ fmt.dateFormat = "yyyy"; return fmt.string(from: date) }())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await appModel.musicKit.play(album: album) }
            } label: { Label("Play Album", systemImage: "play.fill") }
        }
    }

    private func loadDetail() async {
        guard detailed == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // Apple Music relationships + Wikipedia bio in parallel —
        // they're independent network requests against different
        // endpoints.
        //
        // Apple Music's `editorialNotes` would be the ideal source
        // for the bio, but MusicKit's auto-provisioned developer
        // token doesn't carry the editorial scope. Verified with
        // both `MusicCatalogResourceRequest<Artist>` and raw
        // `MusicDataRequest` with `?extend=editorialNotes` — the
        // attribute is stripped in both cases (Daft Punk + The
        // Beatles both reported missing editorialNotes despite
        // having bios in the consumer Apple Music app). Wikipedia's
        // no-auth summary REST endpoint is the practical fallback.
        async let relationships = artist.with([.topSongs, .albums])
        async let wiki = WikipediaArtistBio.fetch(for: artist.name)
        do {
            detailed = try await relationships
        } catch {
            loadError = "Couldn't load artist: \(error.localizedDescription)"
        }
        if let result = await wiki {
            bioText = result.summary
            bioPageURL = result.pageURL
        }
    }
}

// MARK: - Wikipedia bio fetcher

/// Lightweight client for Wikipedia's `page/summary` REST endpoint.
/// No auth, no API key — just an HTTPS GET against
/// `en.wikipedia.org/api/rest_v1/page/summary/{title}`.
///
/// Artist names map to article titles fairly cleanly. When the
/// first attempt hits a disambiguation page (i.e. the title is
/// ambiguous — "Adele" could be a name, a band, etc.), we retry
/// with the common music-disambiguation suffixes Wikipedia uses
/// (`_(band)`, `_(musician)`, `_(singer)`). Returns nil if no
/// usable result is found.
private enum WikipediaArtistBio {

    struct Result {
        let summary: String
        let pageURL: URL?
    }

    /// Try variant titles in order. Plain title is preferred (avoids
    /// false-positive disambiguation for unambiguous artists like
    /// "Daft Punk" or "The Beatles"), but only accepted if the
    /// extract reads like a music topic. Otherwise we fall through
    /// to the music-suffix attempts ("X (band)", "X (musician)",
    /// etc.). Without the sanity check, names like "Justice", "Air",
    /// "Train" would surface their non-music Wikipedia article.
    static func fetch(for artistName: String) async -> Result? {
        // Strip "feat." / "with" segments that Apple Music sometimes
        // tucks into the artistName field — those tank lookups.
        let cleaned = sanitize(artistName)
        // Plain title first — but require music context in the
        // extract before accepting.
        if let plain = await fetchOne(title: cleaned),
           looksMusical(plain.summary) {
            return plain
        }
        // Music-disambiguated variants Wikipedia commonly uses.
        for suffix in [" (band)", " (musician)", " (singer)", " (rapper)", " (DJ)", " (group)"] {
            if let result = await fetchOne(title: cleaned + suffix) {
                return result
            }
        }
        return nil
    }

    /// Heuristic: does the extract read like it's about a musical
    /// act? Looks for any of a handful of unambiguously-music
    /// nouns in the first ~400 chars (where Wikipedia typically
    /// establishes the topic in its opening sentence). Cheap and
    /// catches the common false-positive cases (Justice → philosophy
    /// concept; Air → gas; Train → vehicle).
    private static func looksMusical(_ extract: String) -> Bool {
        let head = extract.prefix(400).lowercased()
        let keywords = [
            "band", "musician", "singer", "rapper", "songwriter",
            "guitarist", "drummer", "bassist", "pianist", "vocalist",
            "music", "album", "song", "single", "discography", "record label",
            "duo", "trio", "quartet", "ensemble", "dj"
        ]
        return keywords.contains { head.contains($0) }
    }

    private static func fetchOne(title: String) async -> Result? {
        // Wikipedia uses underscores for spaces in URLs, but accepts
        // percent-encoded spaces too. URLComponents handles the
        // encoding; we just substitute underscores for cleanliness.
        let urlTitle = title.replacingOccurrences(of: " ", with: "_")
        guard let encoded = urlTitle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
        else {
            return nil
        }
        var request = URLRequest(url: url)
        // Wikipedia's REST API politely asks for a User-Agent that
        // identifies the client.
        request.setValue("HighVidelity/1.0 (visualizer; jessegriffith)",
                         forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let parsed = try JSONDecoder().decode(SummaryEnvelope.self, from: data)
            // Skip disambiguation pages — we want a real article.
            if parsed.type == "disambiguation" { return nil }
            let extract = parsed.extract.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !extract.isEmpty else { return nil }
            let pageString: String? = parsed.content_urls?.desktop?.page
            let pageURL: URL? = pageString.flatMap { URL(string: $0) }
            return Result(summary: extract, pageURL: pageURL)
        } catch {
            return nil
        }
    }

    /// Normalize artist names that Apple Music sometimes returns
    /// with collaborators inline ("Daft Punk, Pharrell Williams &
    /// Nile Rodgers" → "Daft Punk"). Splits on common separators
    /// and takes the head — good enough for the primary-artist
    /// case which is the only one we ever drill into.
    private static func sanitize(_ name: String) -> String {
        let separators: [String] = [",", " feat.", " ft.", " with ", " & "]
        var head = name
        for sep in separators {
            if let range = head.range(of: sep) {
                head = String(head[..<range.lowerBound])
            }
        }
        return head.trimmingCharacters(in: .whitespaces)
    }

    private struct SummaryEnvelope: Decodable {
        let type: String?
        let extract: String
        let content_urls: ContentURLs?

        struct ContentURLs: Decodable {
            let desktop: PageURL?
            struct PageURL: Decodable {
                let page: String
            }
        }
    }
}
#endif
