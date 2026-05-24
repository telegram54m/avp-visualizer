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
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?

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
            if appModel.isLoadingSong {
                ProgressView()
                Text("Analyzing preview…")
                    .foregroundStyle(.secondary)
            } else if appModel.hasAudioSource {
                Text(nowPlayingLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                #else
                NavigationLink("Open Visualizer") {
                    VisualizerView()
                        .environment(appModel)
                        .ignoresSafeArea()
                }
                .buttonStyle(.borderedProminent)
                #endif
            } else {
                Text("No song loaded")
                    .foregroundStyle(.secondary)
            }

            // --- Secondary: local file import ------------------------------
            // tvOS has no user-facing file system, so local file import
            // doesn't apply there.
            #if !os(tvOS)
            Button("Import a local audio file…") { showFilePicker = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
            #endif
        }
        // padding moved to the outer ScrollView wrapper in `body`.
        .task {
            // Initial demo preview so the user has something immediately if
            // they haven't picked an Apple Music song yet. Clair de Lune
            // gives Crystal mode its strongest reference look — slow tempo,
            // sparse onsets, and a chromagram that walks across the hue
            // wheel as the harmony moves.
            await appModel.loadSong("Clair de Lune Debussy")
        }
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
                HStack(spacing: 8) {
                    // tvOS doesn't support .roundedBorder text-field style.
                    #if os(tvOS)
                    TextField("Search songs…", text: $searchText)
                        .frame(maxWidth: 280)
                        .onSubmit { runSearch() }
                    #else
                    TextField("Search songs…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .onSubmit { runSearch() }
                    #endif
                    Button("Search") { runSearch() }
                        .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if mk.isSearching {
                    ProgressView().controlSize(.small)
                } else if !mk.searchResults.isEmpty {
                    // Inline VStack instead of nested ScrollView — the
                    // outer body-level ScrollView already lets the UI
                    // scroll when content overflows on small screens. A
                    // nested ScrollView here collapses to 0 height inside
                    // a flex-vstack on iPhone (the bug that was hiding
                    // results). Bound width so result rows don't stretch
                    // across the whole window on macOS / iPad.
                    VStack(spacing: 6) {
                        ForEach(mk.searchResults, id: \.id) { song in
                            searchResultRow(song)
                        }
                    }
                    .frame(maxWidth: 380)
                }

                if let np = mk.nowPlaying {
                    Text("▶ \(np.title) — \(np.artistName)")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
        }
    }

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
            return now
        }
        if let pref = appModel.preferredSystemAudioProcessName {
            return pref
        }
        return "Auto"
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
