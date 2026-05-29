//
//  SourceDetailViews.swift
//  High Videlity
//
//  Phase 7 — per-Source detail panels driven by the sidebar in
//  `RootShellView`. macOS-only for now; iOS/visionOS still use the
//  legacy ContentView until a later phase ports them.
//
//  Each view is a thin reorganization of pieces that lived in
//  ContentView pre-Phase-7. The intent is NOT to redesign the
//  surfaces — that's risky and the user just wants the IA to make
//  sense. The Apple Music / Local detail views still trigger the
//  same sheets (LibraryBrowserView, AppleMusicLibraryView, etc.)
//  they did before. Settings carries the controls that used to be
//  inline with the rest of ContentView's mode picker block.
//

#if os(macOS)
import SwiftUI
import MusicKit
import UniformTypeIdentifiers

// MARK: - Apple Music

/// Apple Music source root. Hosts the content-forward landing feed
/// (`AppleMusicHomeView`) — For You recommendations, top charts,
/// library entry — instead of the prior search-bar + buttons +
/// sheets layout. Library and Browse are no longer modals; library
/// pushes via NavigationLink, browse content now lives inline on
/// this page.
struct AppleMusicSourceView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showSubscriptionOffer = false

    var body: some View {
        AppleMusicHomeView()
            // Apple's standard subscribe-or-trial sheet. Hoisted to
            // the source root so it can be presented from anywhere
            // in the stack (the home view's subscription CTA, a
            // hypothetical future "upgrade" link, etc.).
            .musicSubscriptionOffer(isPresented: $showSubscriptionOffer)
            // Play error banner — surfaced as a SwiftUI overlay on
            // the home so it can sit above whatever content is
            // showing (feed or search results) without rewriting the
            // home's layout.
            .overlay(alignment: .top) {
                if let err = appModel.musicKit.lastPlayError {
                    playErrorBanner(err, mk: appModel.musicKit)
                        .padding(.top, 12)
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2),
                       value: appModel.musicKit.lastPlayError)
    }

    /// Banner shown above the feed when the most recent play attempt
    /// failed. Retry uses the captured `lastPlayAttemptSong` so the
    /// user doesn't have to re-pick from search results.
    private func playErrorBanner(_ message: String, mk: MusicKitController) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout)
                HStack(spacing: 10) {
                    if let song = mk.lastPlayAttemptSong {
                        Button("Retry") {
                            Task { await appModel.playAppleMusicSong(song) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button("Dismiss") {
                        mk.lastPlayError = nil
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 520)
    }
}

// MARK: - Local Library

struct LocalSourceView: View {

    @Environment(AppModel.self) private var appModel
    @State private var showFilePicker = false
    @State private var showLibraryBrowser = false

    /// True when we have anything to surface in the "currently
    /// loaded" card. Source-of-truth check kept centralized so the
    /// header copy and the card both agree on whether to render.
    private var hasLoadedTrack: Bool {
        !appModel.currentTrackTitle.isEmpty || !appModel.currentTrackArtist.isEmpty
    }

    var body: some View {
        let entries = appModel.library.entries
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if entries.isEmpty {
                    // Welcome / empty state — keep the original
                    // hero + action cards as the welcoming UI when
                    // no folder has been scanned yet.
                    heroBlock
                    actionGrid
                    if hasLoadedTrack { loadedCard }
                } else {
                    // Content-forward layout — the user's music IS
                    // the page. Toolbar at the top, currently-loaded
                    // card next, then the actual library content.
                    libraryToolbar
                    if hasLoadedTrack { loadedCard }
                    librarySections(entries: entries)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: entries.isEmpty ? 760 : .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Local Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Import a file…", systemImage: "doc.badge.plus")
                    }
                    Button {
                        appModel.library.pickFolder()
                    } label: {
                        Label(appModel.library.rootURL == nil ? "Pick a folder…" : "Change folder…",
                              systemImage: "folder.badge.gearshape")
                    }
                    if appModel.library.rootURL != nil {
                        Button {
                            Task { await appModel.library.rescan() }
                        } label: {
                            Label("Rescan folder", systemImage: "arrow.clockwise")
                        }
                    }
                    Divider()
                    Button {
                        showLibraryBrowser = true
                    } label: {
                        Label("Open library browser…", systemImage: "list.bullet.rectangle")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .help("Add music or manage library")
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await appModel.loadSong(from: url) }
        }
        .sheet(isPresented: $showLibraryBrowser) {
            LibraryBrowserView()
                .environment(appModel)
        }
    }

    // MARK: - Hero (empty-state)

    /// Welcoming header. Glyph + headline + supporting paragraph —
    /// roughly matches the empty-state vocabulary used elsewhere in
    /// the app so the local-library entry doesn't feel like a stray
    /// form among modern surfaces.
    private var heroBlock: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Your local music")
                    .font(.title2.weight(.semibold))
                Text("Play files on this Mac and build a reusable feature cache so the visualizer reacts instantly on repeat plays.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Two action cards shown only in the empty state. Once the
    /// library has entries, the toolbar Menu carries the same
    /// actions in a compact form.
    private var actionGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240), spacing: 12)],
            spacing: 12
        ) {
            ActionCard(
                systemImage: "doc.badge.plus",
                title: "Import a file",
                subtitle: "Pick a single audio file from your Mac and play it through the visualizer.",
                perform: { showFilePicker = true }
            )
            ActionCard(
                systemImage: "folder.fill.badge.gearshape",
                title: "Browse audio library",
                subtitle: "Point at a folder of music and batch-cache features for every track inside.",
                perform: { showLibraryBrowser = true }
            )
        }
    }

    // MARK: - Content-forward layout

    /// Compact toolbar at the top of the populated library view.
    /// Folder name + entry count on the left so the user always knows
    /// what they're looking at.
    private var libraryToolbar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(appModel.library.rootURL?.lastPathComponent ?? "Your library")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("\(appModel.library.entries.count) songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// All the populated sections — recently cached carousel, album
    /// rows, then a "All Songs" list. Lifts pieces from
    /// LibraryBrowserView in a content-feed shape.
    private func librarySections(entries: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            albumRow(entries: entries)
            artistRow(entries: entries)
            allSongsSection(entries: entries)
        }
    }

    /// Horizontal scroll of unique albums from the scanned library.
    /// Built lazily by deduping entries on (album, artist) — local
    /// files don't expose artwork through LibraryEntry, so cards use
    /// a gradient placeholder keyed off the album name. Returns nil
    /// when the library is small enough that this row would just
    /// duplicate the songs list.
    @ViewBuilder
    private func albumRow(entries: [LibraryEntry]) -> some View {
        let groups = uniqueAlbums(from: entries)
        if groups.count >= 4 {
            VStack(alignment: .leading, spacing: 10) {
                Text("Albums")
                    .font(.title3.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(groups, id: \.key) { group in
                            LocalAlbumCard(
                                title: group.album ?? "Unknown Album",
                                subtitle: group.artist.isEmpty ? "Unknown Artist" : group.artist,
                                tracks: group.entries,
                                appModel: appModel
                            )
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    /// Horizontal scroll of unique artists from the scanned library.
    @ViewBuilder
    private func artistRow(entries: [LibraryEntry]) -> some View {
        let artists = uniqueArtists(from: entries)
        if artists.count >= 4 {
            VStack(alignment: .leading, spacing: 10) {
                Text("Artists")
                    .font(.title3.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(artists, id: \.name) { artist in
                            LocalArtistCard(
                                name: artist.name,
                                trackCount: artist.entries.count,
                                tracks: artist.entries,
                                appModel: appModel
                            )
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    /// Vertical list of every entry in the library. Sorted by artist
    /// then album then title — matches the library store's default.
    private func allSongsSection(entries: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("All Songs")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            VStack(spacing: 2) {
                ForEach(entries) { entry in
                    LocalSongRow(entry: entry, appModel: appModel)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    // MARK: - Currently loaded card

    /// Material card showing the active local-playback track. Same
    /// visual language as SettingsCard so the surface reads as
    /// "status", not "form".
    private var loadedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Currently loaded")
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(appModel.currentTrackTitle.isEmpty ? "Untitled track" : appModel.currentTrackTitle)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            if !appModel.currentTrackArtist.isEmpty {
                Text(appModel.currentTrackArtist)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(18)
        .frame(maxWidth: 720, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    // MARK: - Grouping helpers

    /// Group library entries by (album, artist) preserving the order
    /// of first appearance. "Unknown Album" merges entries with nil
    /// album so the page doesn't fragment into singletons.
    private func uniqueAlbums(from entries: [LibraryEntry]) -> [AlbumGroup] {
        var order: [String] = []
        var byKey: [String: AlbumGroup] = [:]
        for entry in entries {
            let key = "\(entry.album ?? "Unknown Album")::\(entry.artist)"
            if byKey[key] == nil {
                byKey[key] = AlbumGroup(
                    key: key,
                    album: entry.album,
                    artist: entry.artist,
                    entries: []
                )
                order.append(key)
            }
            byKey[key]?.entries.append(entry)
        }
        return order.compactMap { byKey[$0] }
    }

    private func uniqueArtists(from entries: [LibraryEntry]) -> [ArtistGroup] {
        var order: [String] = []
        var byName: [String: ArtistGroup] = [:]
        for entry in entries {
            let name = entry.artist.isEmpty ? "Unknown Artist" : entry.artist
            if byName[name] == nil {
                byName[name] = ArtistGroup(name: name, entries: [])
                order.append(name)
            }
            byName[name]?.entries.append(entry)
        }
        return order.compactMap { byName[$0] }
    }

    struct AlbumGroup {
        let key: String
        let album: String?
        let artist: String
        var entries: [LibraryEntry]
    }

    struct ArtistGroup {
        let name: String
        var entries: [LibraryEntry]
    }
}

// MARK: - Local row + card components

/// Row for a single LibraryEntry inside the All-Songs list. Local
/// files don't have MusicKit artwork; a gradient-tinted placeholder
/// derived from the title hash gives each row a subtle visual
/// distinction without requiring any per-file art lookup.
private struct LocalSongRow: View {
    let entry: LibraryEntry
    let appModel: AppModel
    @State private var hovered = false

    var body: some View {
        Button {
            Task {
                await appModel.loadSong(
                    from: entry.fileURL,
                    title: entry.title,
                    artist: entry.artist,
                    libraryEntry: entry.fileURL
                )
            }
        } label: {
            HStack(spacing: 12) {
                LocalArtTile(hashSeed: entry.title + entry.artist, size: 40, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(entry.artist.isEmpty ? (entry.album ?? "—") : entry.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if appModel.library.cachedURLs.contains(entry.fileURL) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Cached")
                }
                Text(formatDuration(entry.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)
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
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct LocalAlbumCard: View {
    let title: String
    let subtitle: String
    let tracks: [LibraryEntry]
    let appModel: AppModel

    var body: some View {
        Button {
            // Tap = load the first track of the album.
            // Future enhancement: queue all tracks.
            if let first = tracks.first {
                Task {
                    await appModel.loadSong(
                        from: first.fileURL,
                        title: first.title,
                        artist: first.artist,
                        libraryEntry: first.fileURL
                    )
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                LocalArtTile(hashSeed: title + subtitle, size: 140, cornerRadius: 6)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .frame(width: 140, alignment: .leading)
                Text("\(subtitle) · \(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
    }
}

private struct LocalArtistCard: View {
    let name: String
    let trackCount: Int
    let tracks: [LibraryEntry]
    let appModel: AppModel

    var body: some View {
        Button {
            if let first = tracks.first {
                Task {
                    await appModel.loadSong(
                        from: first.fileURL,
                        title: first.title,
                        artist: first.artist,
                        libraryEntry: first.fileURL
                    )
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                LocalArtTile(hashSeed: name, size: 140, cornerRadius: 70)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .frame(width: 140, alignment: .leading)
                Text("\(trackCount) song\(trackCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
    }
}

/// Procedural artwork tile for local files. Derives two complementary
/// hues from the seed string's hash so each (album / artist) gets a
/// distinct but visually unified gradient. Music-note glyph overlays
/// the gradient for instant recognizability.
private struct LocalArtTile: View {
    let hashSeed: String
    let size: CGFloat
    var cornerRadius: CGFloat = 6

    var body: some View {
        let hue1 = stableHue(hashSeed, offset: 0)
        let hue2 = stableHue(hashSeed, offset: 0.18)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue1, saturation: 0.55, brightness: 0.62),
                        Color(hue: hue2, saturation: 0.65, brightness: 0.32)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
            }
    }

    /// Hash-stable hue in 0..1. Uses DJBX33A so the same seed maps to
    /// the same hue between launches.
    private func stableHue(_ seed: String, offset: Double) -> Double {
        var hash: UInt32 = 5381
        for byte in seed.utf8 {
            hash = hash &* 33 &+ UInt32(byte)
        }
        let frac = Double(hash % 1000) / 1000.0
        return (frac + offset).truncatingRemainder(dividingBy: 1.0)
    }
}

// MARK: - Settings

struct SettingsSourceView: View {

    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "Visualizer", systemImage: "sparkles") {
                    visualizerContent
                }
                SettingsCard(title: "Audio Input", systemImage: "waveform") {
                    audioInputContent
                }
            }
            .padding(20)
            .frame(maxWidth: 600, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Settings")
    }

    // MARK: Visualizer card content

    private var visualizerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(label: "Mode", help: "Which animation drives the visualizer") {
                Picker("", selection: Binding(
                    get: { appModel.mode },
                    set: { appModel.mode = $0 }
                )) {
                    ForEach(VisualizerMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if appModel.mode == .crystal {
                Divider()
                settingRow(
                    label: "Additive beams",
                    help: "Crystal v2 layered halo + core treatment"
                ) {
                    Toggle("", isOn: Binding(
                        get: { appModel.useCrystalV2 },
                        set: { appModel.useCrystalV2 = $0 }
                    ))
                    .labelsHidden()
                }
                settingRow(
                    label: "Shard density",
                    help: "Debug — keep at 1× for normal use"
                ) {
                    Picker("", selection: Binding(
                        get: { CrystalVisualizerV2.synthShardMultiplier },
                        set: { CrystalVisualizerV2.synthShardMultiplier = $0 }
                    )) {
                        Text("1×").tag(1)
                        Text("2×").tag(2)
                        Text("3×").tag(3)
                        Text("5×").tag(5)
                        Text("10×").tag(10)
                        Text("20×").tag(20)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: Audio input card content

    private var audioInputContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                settingRow(
                    label: "Listen to system audio",
                    help: "Capture from Music, Spotify, browser, etc."
                ) {
                    Toggle("", isOn: Binding(
                        get: { appModel.useSystemAudio },
                        set: { appModel.useSystemAudio = $0 }
                    ))
                    .labelsHidden()
                }
                if appModel.useSystemAudio {
                    SystemAudioSourcePicker()
                        .padding(.leading, 2)
                }
                if appModel.useSystemAudio,
                   let msg = appModel.systemAudio.errorMessage,
                   appModel.systemAudio.isAuthorized == false {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                settingRow(
                    label: "Listen with mic",
                    help: "Use external speakers / vinyl / live audio"
                ) {
                    Toggle("", isOn: Binding(
                        get: { appModel.useMic },
                        set: { appModel.useMic = $0 }
                    ))
                    .labelsHidden()
                }
                if appModel.useMic, appModel.micListener.isAuthorized == false {
                    Text("Microphone permission denied — enable in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Row helper

    /// Single row inside a settings card. Label + help text on the
    /// left, control trailing-aligned. Helps each card read like a
    /// clean form list rather than a stacked collection of widgets.
    @ViewBuilder
    private func settingRow<Control: View>(
        label: String,
        help: String?,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.callout)
                if let help, !help.isEmpty {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            control()
                .frame(maxWidth: 280, alignment: .trailing)
        }
    }
}

/// Material-card section used in Settings to group related controls.
/// Title + glyph on top, content stack below. Same visual language
/// as macOS's System Settings cards.
struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            content
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }
}

// MARK: - System Audio source picker
//
// Lifted out of ContentView so SettingsSourceView (and any future
// surface) can drop it in without duplicating the menu plumbing.

struct SystemAudioSourcePicker: View {

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let listener = appModel.systemAudio
        let currentChoice = appModel.preferredSystemAudioProcessName

        HStack(spacing: 6) {
            Text("Source:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                Button("Auto (pick first playing music app)") {
                    appModel.switchSystemAudioSource(toName: nil)
                }
                Divider()
                ForEach(listener.availableProcesses) { proc in
                    Button {
                        appModel.switchSystemAudioSource(toName: proc.name)
                    } label: {
                        HStack {
                            Text(Self.friendlyName(proc.name))
                            if proc.isPlaying {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.green)
                            }
                            if currentChoice == proc.name {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if listener.availableProcesses.isEmpty {
                    Text("No audio processes found")
                }
                Divider()
                Button("Refresh list") { listener.refreshAvailableProcesses() }
            } label: {
                HStack(spacing: 4) {
                    Text(currentLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onAppear { listener.refreshAvailableProcesses() }
        }
        .font(.caption)
    }

    private var currentLabel: String {
        if let now = appModel.systemAudio.tappedProcessName,
           appModel.systemAudio.isActive {
            return Self.friendlyName(now)
        }
        if let pref = appModel.preferredSystemAudioProcessName {
            return Self.friendlyName(pref)
        }
        return "Auto"
    }

    static func friendlyName(_ raw: String) -> String {
        switch raw {
        case "RemotePlayerService": return "Apple Music"
        default: return raw
        }
    }
}

// MARK: - Coming soon (Spotify / YouTube Music)

struct ComingSoonView: View {
    let source: SidebarSource

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: source.systemImage)
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(source.displayName)
                .font(.title2.weight(.semibold))
            Text("Coming after first release.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(rationale)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(source.displayName)
    }

    private var rationale: String {
        switch source {
        case .spotify:
            return "Spotify's MusicKit-equivalent SDK was deprecated in late 2024. We're tracking the API shape that replaces it before designing this surface."
        case .youTubeMusic:
            return "YouTube Music doesn't expose a first-party playback SDK on Apple platforms. We'll revisit when one arrives."
        default:
            return ""
        }
    }
}

#endif
