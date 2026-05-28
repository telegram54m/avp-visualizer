//
//  MusicAppNowPlaying.swift
//
//  Queries macOS Music.app for the currently-playing track via
//  NSAppleScript. Returns a local file URL + metadata when available;
//  returns nil for Apple Music streaming (DRM, no local asset),
//  when Music.app isn't running, or when nothing is playing.
//
//  Why AppleScript: MPMusicPlayerController is iOS-only on macOS, the
//  ScriptingBridge generated headers require an extra build step, and
//  the AppleScript dictionary for Music.app exposes everything we need
//  in a stable surface that hasn't changed since iTunes 1.0. Latency
//  is ~10-50ms per query — fine for the "fired on Shazam match"
//  cadence we need (a few times per song).
//
//  Permissions: the FIRST time this runs from a given binary, macOS
//  prompts "<app> wants access to Music." Apps shipping this need
//  `NSAppleEventsUsageDescription` in Info.plist explaining why.
//  In a Swift package CLI test, the prompt appears against
//  /usr/bin/swift or the test binary directly.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Snapshot of Music.app's now-playing state at a single moment.
public struct MusicAppTrack: Sendable {
    /// Local file URL of the track's audio file. `nil` for streaming
    /// tracks (Apple Music subscription content without a downloaded
    /// copy), iCloud-only tracks that haven't been downloaded yet, or
    /// any other case where Music.app reports a non-file location.
    public let fileURL: URL?
    /// Track title, artist, album as Music.app reports them. These
    /// are NOT the Shazam canonical fields — they're whatever the
    /// user's library says. Useful as cache-key fallback when Shazam
    /// hasn't fired yet, and as display in any UI.
    public let title: String
    public let artist: String
    public let album: String
    /// Music.app's stable per-track ID. Lives in the library DB and
    /// survives renames. Excellent fallback cache key when Shazam
    /// hasn't matched yet — a track always has the same persistentID
    /// as long as it isn't deleted + re-added.
    public let persistentID: String
    /// Track duration in seconds, as Music.app reports it (used to
    /// sanity-check the stem cache: if cached duration disagrees with
    /// this by more than a couple seconds, the cache row is probably
    /// for a different version of the song).
    public let durationSeconds: Double
    /// Music.app's current playhead position. Useful if we want to
    /// kick off stem separation only after the user has committed
    /// (e.g., played for >5s) rather than on every track skip.
    public let playerPositionSeconds: Double
    /// True when Music.app reports `player state` as `playing`.
    /// False when paused, stopped, or fast-forwarding.
    public let isPlaying: Bool
}

/// Reasons NowPlaying lookup may legitimately return nil — these
/// aren't errors so much as known states.
public enum MusicAppNowPlayingState: Sendable {
    /// Music.app isn't running. NSAppleScript will fail; we don't
    /// want to launch the app just to query it.
    case musicAppNotRunning
    /// Music.app is running but no track is loaded.
    case noTrack
    /// Music.app is loaded with a track but it's streaming (no local
    /// file), so we can't pass a path to the sidecar from Music alone.
    case streamingOnly(track: MusicAppTrack)
    /// All good — local file URL is in the track.
    case ready(track: MusicAppTrack)
}

public enum MusicAppNowPlayingError: Error, CustomStringConvertible, Sendable {
    case scriptCompilationFailed(String)
    case scriptExecutionFailed(String)
    case parseFailed(String)
    case automationPermissionDenied

    public var description: String {
        switch self {
        case .scriptCompilationFailed(let s): return "AppleScript compile failed: \(s)"
        case .scriptExecutionFailed(let s): return "AppleScript execution failed: \(s)"
        case .parseFailed(let s): return "couldn't parse AppleScript reply: \(s)"
        case .automationPermissionDenied:
            return "automation permission denied — grant the app access " +
                   "to Music.app under System Settings → Privacy & Security → Automation"
        }
    }
}

public struct MusicAppNowPlaying: Sendable {
    public init() {}

    /// Single AppleScript that returns either "no_track" or a record
    /// with all the fields we want, pipe-delimited. We use a single
    /// query (instead of one-per-field) so Music.app's state is
    /// captured atomically — between two queries the user could skip
    /// tracks and we'd return frankenstein data.
    ///
    /// Returns a SINGLE STRING for ease of parsing (Apple Event
    /// records get hairy through NSAppleScript's bridge). Format:
    ///   "OK|<title>|<artist>|<album>|<persistentID>|<duration>|<position>|<playing>|<location>"
    /// Fields are separated by U+241F (Symbol For Unit Separator) so
    /// the song title's "|" if any won't trip parsing.
    private static let querySource: String = {
        let sep = "\u{241F}"
        return #"""
        if not application "Music" is running then
            return "MUSIC_NOT_RUNNING"
        end if
        tell application "Music"
            try
                set t to current track
            on error
                return "NO_TRACK"
            end try
            set theTitle to name of t
            set theArtist to artist of t
            set theAlbum to album of t
            set thePID to persistent ID of t
            set theDuration to duration of t
            set thePosition to player position
            set theState to player state as text
            try
                -- `location of t` returns an alias. `POSIX path of`
                -- would be the obvious next step, but it dereferences
                -- the alias's bookmark (touches the file), which can
                -- throw on TCC-restricted paths even when `as text`
                -- succeeds. Stringify here, convert to POSIX on the
                -- Swift side where we control the failure mode.
                set theLocation to (location of t) as text
            on error
                set theLocation to ""
            end try
            set sep to "\#(sep)"
            return "OK" & sep & theTitle & sep & theArtist & sep & theAlbum & sep & thePID & sep & theDuration & sep & thePosition & sep & theState & sep & theLocation
        end tell
        """#
    }()

    /// Query Music.app once. Synchronous (NSAppleScript blocks).
    /// For background dispatch, wrap in a Task.detached.
    ///
    /// On non-macOS platforms (iOS/iPadOS/visionOS/tvOS), this returns
    /// `.musicAppNotRunning` unconditionally — there's no Music.app
    /// equivalent we can drive via AppleScript on those platforms.
    /// Callers (AppModel.kickoffStemSeparation) already handle that
    /// case by early-returning, so the stem-separation pipeline
    /// gracefully no-ops on iOS without further gating.
    public func query() throws -> MusicAppNowPlayingState {
        #if os(macOS)
        guard let script = NSAppleScript(source: Self.querySource) else {
            throw MusicAppNowPlayingError.scriptCompilationFailed("NSAppleScript init returned nil")
        }
        var errInfo: NSDictionary?
        let result = script.executeAndReturnError(&errInfo)
        if let errInfo {
            // -1743 is the "not authorized to send apple events" code.
            let code = (errInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 {
                throw MusicAppNowPlayingError.automationPermissionDenied
            }
            let msg = (errInfo[NSAppleScript.errorMessage] as? String) ?? "(no message)"
            throw MusicAppNowPlayingError.scriptExecutionFailed("\(code): \(msg)")
        }
        guard let raw = result.stringValue else {
            throw MusicAppNowPlayingError.parseFailed("script returned non-string descriptor")
        }
        return try Self.parse(raw)
        #else
        return .musicAppNotRunning
        #endif
    }

    /// Convenience: just the file URL when one is available, else nil.
    public func currentFileURL() throws -> URL? {
        switch try query() {
        case .ready(let track): return track.fileURL
        case .streamingOnly, .noTrack, .musicAppNotRunning: return nil
        }
    }

    // MARK: - HFS → POSIX path conversion
    //
    // Music.app's `(location of t) as text` returns paths in classic
    // HFS form:
    //   "Macintosh HD:Users:jessegriffith:Music:Music:Media.localized:..."
    // We need:
    //   "/Users/jessegriffith/Music/Music/Media.localized/..."  (boot volume)
    //   "/Volumes/<NAME>/..."                                   (other volumes)
    //
    // The conversion is: drop the volume name + first colon, replace
    // remaining colons with slashes, prepend with the right mount
    // point. For the boot volume the right prepend is just "/"; for
    // other volumes it's "/Volumes/<name>/".
    //
    // We detect "boot volume" by checking whether `/<rest>` exists;
    // if it does, use that. Otherwise fall back to /Volumes/<name>/.

    static func hfsToPOSIXPath(_ hfs: String) -> String? {
        guard !hfs.isEmpty else { return nil }
        let parts = hfs.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }

        let volume = parts[0]
        // Trailing colon on HFS dir paths produces an empty final part;
        // skip that.
        let pathParts = parts.dropFirst().filter { !$0.isEmpty }
        let restJoined = pathParts.joined(separator: "/")

        // Boot-volume guess: is `/<restJoined>` on disk?
        let bootCandidate = "/" + restJoined
        if FileManager.default.fileExists(atPath: bootCandidate) {
            return bootCandidate
        }

        // Non-boot volume mount points live under /Volumes/<name>/.
        let volumeCandidate = "/Volumes/\(volume)/\(restJoined)"
        if FileManager.default.fileExists(atPath: volumeCandidate) {
            return volumeCandidate
        }

        // Neither exists — return the boot-volume guess so the caller
        // gets a meaningful error from soundfile/Python rather than
        // a silent nil. The error message will include the path.
        return bootCandidate
    }

    // MARK: - Parsing

    /// Parse the pipe-delimited string the AppleScript emits.
    /// "OK|title|artist|album|pid|duration|position|state|location"
    static func parse(_ raw: String) throws -> MusicAppNowPlayingState {
        if raw == "MUSIC_NOT_RUNNING" { return .musicAppNotRunning }
        if raw == "NO_TRACK" { return .noTrack }
        let sep: Character = "\u{241F}"
        let parts = raw.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 9, parts[0] == "OK" else {
            throw MusicAppNowPlayingError.parseFailed("unexpected format: \(raw.prefix(200))")
        }
        let title = parts[1]
        let artist = parts[2]
        let album = parts[3]
        let pid = parts[4]
        let duration = Double(parts[5]) ?? 0
        let position = Double(parts[6]) ?? 0
        let state = parts[7]  // "playing", "paused", "stopped", "fast forwarding"
        let location = parts[8]  // POSIX path or empty for streaming

        let fileURL: URL? = {
            guard !location.isEmpty else { return nil }
            // Music.app returns HFS paths like
            //   "Macintosh HD:Users:jessegriffith:Music:..."
            // through `(location of t) as text`. Convert to POSIX.
            // If `(location of t)` was already coerced to POSIX
            // somewhere upstream (a future-proof case), we pass
            // through unchanged.
            let posix = location.hasPrefix("/") ? location : hfsToPOSIXPath(location)
            guard let posix, posix.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: posix)
        }()

        let track = MusicAppTrack(
            fileURL: fileURL,
            title: title,
            artist: artist,
            album: album,
            persistentID: pid,
            durationSeconds: duration,
            playerPositionSeconds: position,
            isPlaying: state.lowercased() == "playing"
        )
        if fileURL == nil {
            return .streamingOnly(track: track)
        }
        return .ready(track: track)
    }
}
