//
//  ContentView.swift
//  High Videlity
//
//  Created by Jesse Griffith on 5/18/26.
//

import MusicKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @Environment(AppModel.self) private var appModel
    @State private var showFilePicker = false
    #if os(macOS)
    @State private var showLibraryBrowser = false
    #endif
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    /// iOS-only: drives the fullScreenCover presentation of the
    /// visualizer. NavigationLink-based push fights iPhone's Dynamic
    /// Island safe-area insets in landscape (the visualizer ends up
    /// confined to the right portion of the screen because the safe
    /// area inset is preserved by NavigationStack even with
    /// .ignoresSafeArea + .toolbar(.hidden)). fullScreenCover escapes
    /// the NavigationStack entirely, giving us a genuinely full-bleed
    /// canvas.
    #if os(iOS)
    @State private var showVisualizer = false
    #endif
    /// macOS now-playing inspector visibility. Toggled via the toolbar
    /// button + the small icon next to the now-playing label. Default
    /// is closed so the user can finish setup steps without the panel
    /// stealing screen width on first launch.
    #if os(macOS)
    @State private var showNowPlayingInspector = false
    @State private var showAppleMusicLibrary = false
    @State private var showBrowse = false
    #endif

    var body: some View {
        // iPhone has a hard vertical constraint. With the search field +
        // results + status + mode picker + toggles + buttons all stacked,
        // SwiftUI collapses the search-results ScrollView to ~0 height
        // when results are present, silently hiding them. Wrap everything
        // in a ScrollView so the full UI can scroll on small screens.
        // macOS / iPadOS in a windowed context still fit naturally — the
        // outer ScrollView just doesn't engage unless the content overflows.
        ScrollView {
            content
                .padding(30)
                .frame(maxWidth: .infinity)
        }
        #if os(macOS)
        // Inspector panel — slides in from the right of the NavigationStack
        // hosting this view, doesn't dim the main content. Width is
        // user-resizable in the standard SwiftUI way.
        .inspector(isPresented: $showNowPlayingInspector) {
            NowPlayingView()
                .environment(appModel)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNowPlayingInspector.toggle()
                } label: {
                    Label("Now Playing", systemImage: showNowPlayingInspector ? "sidebar.right" : "music.note")
                }
                .help(showNowPlayingInspector ? "Hide Now Playing panel" : "Show Now Playing panel")
            }
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 14) {
            Text("High Videlity")
                .font(.largeTitle.weight(.semibold))

            // --- Apple Music source ----------------------------------------
            appleMusicSection

            Divider().frame(maxWidth: 360)

            // --- Now-playing + mode + immersive -----------------------------
            //
            // Originally this whole block was gated on `hasAudioSource`, which
            // worked when the app auto-loaded a demo song on launch (Clair de
            // Lune). Without the auto-load there's no source at startup, and
            // hiding the input toggles + mode picker created a chicken-and-egg:
            // the controls that START a source were themselves hidden until a
            // source existed. Now we show controls unconditionally; the
            // "Analyzing…" indicator and now-playing label remain conditional.
            if appModel.isLoadingSong {
                ProgressView()
                Text("Analyzing preview…")
                    .foregroundStyle(.secondary)
            } else if appModel.hasAudioSource {
                Text(nowPlayingLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Group {
                Picker("Mode", selection: Binding(
                    get: { appModel.mode },
                    set: { appModel.mode = $0 }
                )) {
                    ForEach(VisualizerMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                if appModel.mode == .crystal {
                    Toggle("Crystal v2 — additive beams", isOn: Binding(
                        get: { appModel.useCrystalV2 },
                        set: { appModel.useCrystalV2 = $0 }
                    ))
                    .frame(maxWidth: 320)

                    // DEBUG: shard density saturation test. Re-open the
                    // visualizer after changing to see the new count.
                    // Default 1 = real onset count (~30-50 for a 30s preview).
                    // Reset to 1 before shipping.
                    Picker("Density ×", selection: Binding(
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
                    .frame(maxWidth: 320)
                }

                #if os(iOS)
                // iOS-recommended path: observe Music.app's now-playing
                // metadata + playhead. No mic capture (which fights iOS's
                // audio routing — see ios-audio-session.md). Visualizer
                // tracks song position via MPMusicPlayerController.
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Follow Music app (recommended)", isOn: Binding(
                        get: { appModel.useSystemMusic },
                        set: { appModel.useSystemMusic = $0 }
                    ))
                    if appModel.useSystemMusic, !appModel.systemMusic.title.isEmpty {
                        Text("▶ \(appModel.systemMusic.title) — \(appModel.systemMusic.artist)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if appModel.useSystemMusic {
                        Text("No track playing in Music app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 320)
                #endif

                Toggle("Listen with mic (external speakers)", isOn: Binding(
                    get: { appModel.useMic },
                    set: { appModel.useMic = $0 }
                ))
                .frame(maxWidth: 320)

                if appModel.useMic, appModel.micListener.isAuthorized == false {
                    Text("Microphone permission denied — enable in Settings.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if appModel.useMic {
                    shazamStatusLine
                }

                #if os(macOS)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Listen to system audio (Music, Spotify, browser…)", isOn: Binding(
                        get: { appModel.useSystemAudio },
                        set: { appModel.useSystemAudio = $0 }
                    ))

                    if appModel.useSystemAudio {
                        systemAudioSourcePicker
                    }

                    if appModel.useSystemAudio,
                       let msg = appModel.systemAudio.errorMessage,
                       appModel.systemAudio.isAuthorized == false {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: 320)
                #endif

                #if os(visionOS)
                ToggleImmersiveSpaceButton()
                #elseif os(iOS)
                // fullScreenCover avoids NavigationStack's Dynamic
                // Island safe-area constraints on iPhone landscape.
                // See the showVisualizer @State comment.
                Button("Open Visualizer") {
                    showVisualizer = true
                }
                .buttonStyle(.borderedProminent)
                #else
                NavigationLink("Open Visualizer") {
                    VisualizerView()
                        .environment(appModel)
                        .ignoresSafeArea()
                }
                .buttonStyle(.borderedProminent)
                #endif
            }

            // --- Secondary: local file import ------------------------------
            // tvOS has no user-facing file system, so local file import
            // doesn't apply there.
            #if !os(tvOS)
            Button("Import a local audio file…") { showFilePicker = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
            #endif

            // --- macOS-only: scan a music library folder + batch cache -----
            #if os(macOS)
            Button("Browse Audio Library…") { showLibraryBrowser = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
            #endif
        }
        // padding moved to the outer ScrollView wrapper in `body`.
        // No auto-load on launch — the user picks a song via Library /
        // Import / Music.app / Apple Music / system audio. VisualizerView
        // shows a "pick a song" empty state when frames is empty.
        #if !os(tvOS)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await appModel.loadSong(from: url) }
        }
        #endif
        #if os(macOS)
        .sheet(isPresented: $showLibraryBrowser) {
            LibraryBrowserView()
                .environment(appModel)
        }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $showVisualizer) {
            VisualizerView()
                .environment(appModel)
                .ignoresSafeArea(.all)
                // fullScreenCover on iOS 16+ defaults to the system
                // background color around content that doesn't fill —
                // belt-and-suspenders by setting our own black
                // background and ignoring safe area on it too.
                .background(Color.black.ignoresSafeArea(.all))
        }
        #endif
    }

    // MARK: - Apple Music

    @ViewBuilder
    private var appleMusicSection: some View {
        let mk = appModel.musicKit
        VStack(spacing: 10) {
            Text("Apple Music")
                .font(.headline)

            if mk.authStatus == .notDetermined {
                Button("Connect Apple Music") {
                    Task { await mk.requestAuthorization() }
                }
            } else if !mk.isAuthorized {
                Text("Apple Music access denied — enable in Settings.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                #if !os(visionOS)
                // SearchResultsView owns the search field, scope
                // picker, and result row rendering for Songs / Albums /
                // Artists / Playlists. Drill-down NavigationLinks push
                // AlbumDetailView / ArtistDetailView / PlaylistDetailView.
                SearchResultsView()
                #else
                // visionOS has no NavigationStack in this scene — keep
                // the legacy songs-only search until Phase 7 reshapes
                // the visionOS shell.
                legacySearchSection
                #endif

                #if os(macOS)
                // Entry points into the user's Apple Music library
                // and Apple's curated browse (For You / Charts).
                // Phase 7 will rehome both into the sidebar; for now
                // they're sheets so they don't compete with the
                // search results for screen real estate.
                HStack(spacing: 8) {
                    Button {
                        showAppleMusicLibrary = true
                    } label: {
                        Label("My Library", systemImage: "music.note.house")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        showBrowse = true
                    } label: {
                        Label("Browse", systemImage: "rectangle.grid.2x2")
                    }
                    .buttonStyle(.bordered)
                }
                #endif

                if let np = mk.nowPlaying {
                    Text("▶ \(np.title) — \(np.artistName)")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                // Up Next — auto-hides itself when the queue has
                // nothing past the current track. Lives under the
                // now-playing label so it reads top-to-bottom as
                // "currently playing → coming next."
                UpNextView(appModel: appModel)
            }
        }
        #if os(macOS)
        .sheet(isPresented: $showAppleMusicLibrary) {
            AppleMusicLibraryView(appModel: appModel)
        }
        .sheet(isPresented: $showBrowse) {
            BrowseView(appModel: appModel)
        }
        #endif
    }

    #if os(visionOS)
    /// Legacy songs-only search used on visionOS until Phase 7
    /// reshapes the shell to host NavigationStack-driven drill-downs
    /// in the immersive context.
    @ViewBuilder
    private var legacySearchSection: some View {
        let mk = appModel.musicKit
        HStack(spacing: 8) {
            TextField("Search songs…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit { runSearch() }
            Button("Search") { runSearch() }
                .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if mk.isSearching {
            ProgressView().controlSize(.small)
        } else if !mk.searchResults.isEmpty {
            VStack(spacing: 6) {
                ForEach(mk.searchResults, id: \.id) { song in
                    searchResultRow(song)
                }
            }
            .frame(maxWidth: 380)
        }
    }
    #endif

    private func searchResultRow(_ song: Song) -> some View {
        Button {
            Task { await appModel.playAppleMusicSong(song) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).lineLimit(1)
                    Text(song.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill").imageScale(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        // Right-click (macOS) / long-press (iOS) for queue actions.
        // Keeps the row's primary tap target as "play now" — the most
        // common case — while making queue management discoverable.
        .contextMenu {
            Button {
                Task { await appModel.playAppleMusicSong(song) }
            } label: { Label("Play Now", systemImage: "play.fill") }
            Button {
                Task { await appModel.musicKit.queueNext(song) }
            } label: { Label("Play Next", systemImage: "text.insert") }
            Button {
                Task { await appModel.musicKit.queueLast(song) }
            } label: { Label("Add to Queue", systemImage: "text.append") }
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        let query = searchText
        searchTask = Task { await appModel.musicKit.search(query) }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var shazamStatusLine: some View {
        switch appModel.shazam.status {
        case .idle:
            EmptyView()
        case .listening:
            Label("Listening with Shazam…", systemImage: "waveform")
                .font(.caption).foregroundStyle(.secondary)
        case .matched(let title, let artist):
            Label("Heard: \(title) — \(artist)", systemImage: "music.note")
                .font(.caption).foregroundStyle(.primary)
                .lineLimit(1)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.red)
        }
    }

    private var nowPlayingLabel: String {
        // IMPORTANT: read `framesCount` (the 1 Hz throttled snapshot)
        // rather than `frames.count` here. ContentView lives in the
        // NavigationStack behind VisualizerView while the visualizer is
        // open, and tap-mode `appendLiveFrames` mutates `frames` at
        // 30 Hz — reading `frames.count` registers a SwiftUI Observation
        // dependency on the array and invalidates this body 30×/sec,
        // which was the root cause of the tap-mode-only FPS drift.
        // The throttled snapshot is force-published on every wholesale
        // load/wipe (publishFramesCountNow), so the displayed count is
        // exact off the streaming path and within ~1 s on the streaming
        // path — invisible at the cadence a user reads a status line.
        #if os(macOS)
        if appModel.useSystemAudio {
            if appModel.musicKit.isPlaying, let np = appModel.musicKit.nowPlaying {
                return "Live: \(np.title) — \(np.artistName) (\(appModel.framesCount) frames captured)"
            }
            return "Live system audio — \(appModel.framesCount) frames captured"
        }
        #endif
        #if os(iOS)
        if appModel.useSystemMusic {
            if !appModel.systemMusic.title.isEmpty {
                let pos = Int(appModel.systemMusic.currentPlaybackTime.rounded())
                return "Following Music app: \(appModel.systemMusic.title) @ \(pos)s"
            }
            return "Following Music app — waiting for playback"
        }
        #endif
        if let np = appModel.musicKit.nowPlaying {
            return "Ready — analyzing preview of \(np.title)"
        }
        return "Ready — \(appModel.framesCount) frames analyzed"
    }

    #if os(macOS)
    // MARK: - System Audio source picker (macOS)
    //
    // Lists processes from `SystemAudioListener.availableProcesses`. The
    // listener exposes ALL processes from CoreAudio's process list (not
    // just currently-playing ones) so the user can pre-select an app that
    // hasn't started playing yet. Sorted with currently-playing apps at
    // the top.
    //
    // Selecting a name calls `appModel.switchSystemAudioSource(toName:)`
    // which restarts the tap on the new process AND persists the choice
    // in UserDefaults for next launch. "Auto" clears the preference and
    // falls back to the built-in pick-music-app-by-default policy.
    @ViewBuilder
    private var systemAudioSourcePicker: some View {
        let listener = appModel.systemAudio
        let currentChoice = appModel.preferredSystemAudioProcessName

        HStack(spacing: 6) {
            Text("Source:").font(.caption).foregroundStyle(.secondary)
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
                            Text(proc.name)
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
                    Text(systemAudioSourceLabel)
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

    private var systemAudioSourceLabel: String {
        if let now = appModel.systemAudio.tappedProcessName,
           appModel.systemAudio.isActive {
            return Self.friendlyAudioSourceName(now)
        }
        if let pref = appModel.preferredSystemAudioProcessName {
            return Self.friendlyAudioSourceName(pref)
        }
        return "Auto"
    }

    /// Map opaque macOS process names to user-friendly labels.
    /// `RemotePlayerService` is the helper process Apple Music uses
    /// to render audio for ApplicationMusicPlayer — display it as
    /// "Apple Music" so the UI matches the user's mental model.
    private static func friendlyAudioSourceName(_ raw: String) -> String {
        switch raw {
        case "RemotePlayerService": return "Apple Music"
        default: return raw
        }
    }
    #endif
}

#if os(visionOS)
#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
#else
#Preview {
    ContentView()
        .environment(AppModel())
}
#endif
