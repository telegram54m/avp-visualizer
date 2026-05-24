//
//  MusicAppRemote.swift
//  High Videlity
//
//  AppleScript-based remote for Music.app (macOS). MusicKit's
//  SystemMusicPlayer is iOS-only on macOS — to drive the external Music.app
//  from this process we use its scripting dictionary via NSAppleScript.
//
//  First execution triggers a one-time TCC Automation permission prompt
//  ("'High Videlity' wants to control 'Music'"). Subsequent calls are
//  immediate (sub-millisecond). Requires `NSAppleEventsUsageDescription`
//  in Info.plist / build settings — the user-facing reason string.
//
//  Used by `AppModel.systemMusic*` methods, which dispatch from the user-
//  facing `playerSkipToNext/Previous/TogglePlayPause/Restart` whenever
//  `isControllingSystemMusic` is true.
//

#if os(macOS)

import AppKit
import OSLog

enum MusicAppRemote {
    private static let log = Logger(
        subsystem: "com.jessegriffith.HighVidelity",
        category: "musicapp"
    )

    /// Run an AppleScript command against Music.app. Logs (but does not
    /// raise) errors — the calling user-facing buttons should remain
    /// responsive even if a single command fails (e.g., user denied
    /// Automation access; the next attempt will reprompt). Commands are
    /// run synchronously on the calling thread; each completes in
    /// ~20-50 ms after the first (the first triggers the TCC prompt and
    /// may block until the user answers).
    static func run(_ command: String) {
        let source = "tell application \"Music\" to \(command)"
        guard let script = NSAppleScript(source: source) else {
            log.error("Failed to compile AppleScript: \(source, privacy: .public)")
            return
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            log.error("AppleScript error for '\(command, privacy: .public)': \(errorInfo.description, privacy: .public)")
        }
    }
}

#endif
