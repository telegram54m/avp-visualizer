//
//  SessionControlsView.swift
//  High Videlity
//
//  Phase 6 of the Apple Music interface plan: Sleep Timer. Hosted
//  as a popover from the moon button in NowPlayingView's transport
//  row.
//
//  Acts only on the in-app Apple Music player (ApplicationMusicPlayer).
//  When the user is driving the visualizer from the mic capture or
//  macOS system-audio tap, the sleep timer doesn't affect playback —
//  a footer line in the view says so.
//
//  MusicKit limitation: ApplicationMusicPlayer exposes no per-stream
//  volume API, so the timer does a hard pause at expiry (no fade).
//  Crossfade was prototyped here and removed — without two-stream
//  overlap, "early advance" was just an abrupt early end, strictly
//  worse than the default behavior.
//

import SwiftUI

#if !os(visionOS)
struct SessionControlsView: View {

    @Environment(AppModel.self) private var appModel

    /// Presets shown as a row of chip-style buttons. "End of track" is
    /// deliberately omitted from v1 — it'd require interception of the
    /// queue-advance event with a different code path than the simple
    /// time-based countdown. Easy to add later if requested.
    private static let presets: [Int] = [5, 10, 15, 30, 45, 60]

    var body: some View {
        let mk = appModel.musicKit
        VStack(alignment: .leading, spacing: 18) {
            sleepSection(mk: mk)
            Divider()
            footerNote
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Sleep Timer

    @ViewBuilder
    private func sleepSection(mk: MusicKitController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: mk.sleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                Text("Sleep Timer")
                    .font(.headline)
            }
            if mk.sleepTimerActive, let fire = mk.sleepTimerFireDate {
                VStack(alignment: .leading, spacing: 6) {
                    Text(countdownString(remaining: mk.sleepTimerRemainingSeconds))
                        .font(.system(.title2, design: .rounded).monospacedDigit())
                    Text("Pauses at \(fire.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        mk.cancelSleepTimer()
                    } label: {
                        Label("Cancel Timer", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Text("Pause playback after…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Wrapped chip row. LazyVGrid keeps the buttons
                // even-width across two rows so the 60-min preset
                // doesn't stretch the panel.
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                    spacing: 6
                ) {
                    ForEach(Self.presets, id: \.self) { minutes in
                        Button {
                            mk.startSleepTimer(minutes: minutes)
                        } label: {
                            Text(minuteLabel(minutes))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The sleep timer pauses Apple Music playback only.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Mic and system-audio capture aren't paused.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private func minuteLabel(_ m: Int) -> String {
        m >= 60 ? "1 hr" : "\(m) min"
    }

    /// Render the remaining seconds as `M:SS`, or `H:MM:SS` once we
    /// cross the hour mark (the 60-min preset puts us 1 second under
    /// that, but the formatter shouldn't go negative if rounding
    /// pushes us briefly over).
    private func countdownString(remaining: Int) -> String {
        let total = max(0, remaining)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
#endif
