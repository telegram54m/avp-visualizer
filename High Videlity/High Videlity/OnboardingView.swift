//
//  OnboardingView.swift
//  High Videlity
//
//  Phase 8 — first-run guided setup. Walks the user through the
//  permissions and sources we want them to enable BEFORE they hit
//  the visualizer and find half of it doesn't work because they
//  haven't granted mic / authorized Apple Music / picked an audio
//  source. macOS-only for now; iOS gets its own onboarding when
//  Phase 7's shell ports over.
//
//  Storage: `@AppStorage("hasCompletedOnboarding")` — the flag
//  flips true when the user finishes (or skips) the flow. Cleared
//  by deleting the app's preferences. Manual re-show isn't wired
//  yet; if we add a "Reset onboarding" debug button, it just sets
//  the AppStorage value back to false.
//

#if os(macOS)
import SwiftUI
import MusicKit

struct OnboardingView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    enum Step: Int, CaseIterable {
        case welcome
        case appleMusic
        case audioSource
        case done
    }
    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .padding(28)
                .frame(width: 520, height: 380)
            Divider()
            footerBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:        welcomeStep
        case .appleMusic:     appleMusicStep
        case .audioSource:    audioSourceStep
        case .done:           doneStep
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Welcome to High Videlity")
                .font(.title2.weight(.semibold))
            Text("A music visualizer that listens to whatever you're playing — Apple Music, Spotify, browser audio — and reacts in real time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("This quick setup takes about 30 seconds. You can change anything later in Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var appleMusicStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "applelogo")
                .font(.system(size: 40))
                .foregroundStyle(.primary)
            Text("Connect Apple Music")
                .font(.title3.weight(.semibold))
            Text("Connecting Apple Music lets you search the catalog, play through the app, and have the visualizer follow exact playback position.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            let mk = appModel.musicKit
            switch mk.authStatus {
            case .authorized:
                Label("Connected", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            case .denied, .restricted:
                Label("Denied — enable in System Settings → Privacy & Security", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            case .notDetermined:
                Button("Connect Apple Music") {
                    Task { await mk.requestAuthorization() }
                }
                .buttonStyle(.borderedProminent)
            @unknown default:
                EmptyView()
            }
            Spacer()
        }
    }

    private var audioSourceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick how the visualizer hears music")
                        .font(.title3.weight(.semibold))
                    Text("Optional — you can enable these later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Listen to system audio (Music, Spotify, browser…)", isOn: Binding(
                    get: { appModel.useSystemAudio },
                    set: { appModel.useSystemAudio = $0 }
                ))
                Text("Captures whatever your Mac is playing. Best fidelity — frame-accurate reactivity.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Listen with mic (external speakers / vinyl)", isOn: Binding(
                    get: { appModel.useMic },
                    set: { appModel.useMic = $0 }
                ))
                Text("Useful when the sound is coming from somewhere other than this Mac.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var doneStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("All set")
                .font(.title2.weight(.semibold))
            Text("Search a song, hit Open Visualizer, and you're off. Press space to play/pause, ←/→ to skip, ⌘F to jump back to search.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            // Progress dots — quick visual cue of where we are.
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            // Skip on early steps, no skip on the done step.
            if step != .done {
                Button("Skip Setup") {
                    finish()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Button(primaryButtonTitle) {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryButtonTitle: String {
        switch step {
        case .welcome, .appleMusic, .audioSource: return "Continue"
        case .done: return "Get Started"
        }
    }

    private func advance() {
        switch step {
        case .welcome:     step = .appleMusic
        case .appleMusic:  step = .audioSource
        case .audioSource: step = .done
        case .done:        finish()
        }
    }

    private func finish() {
        hasCompletedOnboarding = true
        dismiss()
    }
}
#endif
