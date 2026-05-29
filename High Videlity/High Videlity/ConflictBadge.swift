//
//  ConflictBadge.swift
//  High Videlity
//
//  Small inline glyph rendered on local-library rows when the
//  file's tagged title / artist disagrees with its Shazam-resolved
//  fingerprint identity. Hover tooltip shows the side-by-side.
//  Click-through resolution UI is a follow-up — for now the badge
//  is purely a diagnostic indicator.
//
//  Reads from [[LocalShazamMatcher]]'s on-disk cache via the
//  pure-function `conflict(for:)` helper, so the badge updates
//  reactively the next time SwiftUI re-evaluates the row body
//  (which happens whenever the row gains/loses hover, or the
//  parent list re-renders). For "live" updates the moment the
//  Shazam match lands, the caller should bump a `@State Int`
//  that the badge keys off.
//

#if os(macOS)
import SwiftUI

struct ConflictBadge: View {
    let entry: LibraryEntry

    var body: some View {
        // Touch the match-signal version so SwiftUI re-renders this
        // row whenever a fresh Shazam match writes to the on-disk
        // cache. The value itself is unused — the read is the
        // observation dependency.
        let _ = ShazamMatchSignal.shared.version
        switch LocalShazamMatcher.conflict(for: entry) {
        case .unverified, .confirmed:
            // Silent — `unverified` means we haven't tried yet,
            // `confirmed` is the happy path. Neither needs a glyph.
            EmptyView()
        case .unmatched:
            // Soft signal: Shazam ran but couldn't catalog-match
            // this file's actual audio AT ANY OFFSET. Often a sign
            // of mis-tagged content (live versions / demos / mis-
            // matched Match files), but not a definitive conflict
            // because some legitimately obscure tracks also don't
            // catalog-match. Muted style — noticeable but not loud.
            Image(systemName: "questionmark.diamond")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .help("Shazam couldn't verify this file against its catalog at any offset. The audio may not match the tagged title / artist, or may not be in the public catalog at all.")
        case .lowConfidence(let identity):
            // Medium signal: Shazam matched at just ONE offset, the
            // others all returned no-match. Single-offset hits are
            // often spurious — the slice happened to fingerprint-
            // resemble an unrelated catalog item — so we surface
            // the result but in yellow rather than orange so the
            // user knows not to trust it.
            Image(systemName: "questionmark.diamond.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.yellow)
                .help(tooltipText(tagged: entry, shazam: identity))
        case .conflict(let identity):
            // Loud signal: ≥2 offsets agreed on a single identity
            // that disagrees with the tags. High-confidence "your
            // tags are wrong."
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .help(tooltipText(tagged: entry, shazam: identity))
        }
    }

    private func tooltipText(tagged: LibraryEntry, shazam: ShazamIdentity) -> String {
        let shTitle = shazam.title ?? "(unknown)"
        let shArtist = shazam.artist ?? "(unknown)"
        let tagArtist = tagged.artist.isEmpty ? "(unknown)" : tagged.artist
        let confirmed = shazam.confirmedOffsets ?? 1
        let total = shazam.totalOffsets ?? 1
        let isLowConfidence = confirmed < 2
        let header: String
        let confidence: String
        if isLowConfidence {
            header = "Possible mis-tag (low confidence)"
            confidence = " — only \(confirmed)/\(total) offsets matched; likely a fingerprint coincidence, may not be the real song"
        } else if let conflicting = shazam.conflictingMatches, conflicting {
            header = "Metadata conflict (ambiguous)"
            confidence = " — \(confirmed)/\(total) offsets agree, others matched different songs"
        } else if confirmed == total {
            header = "Metadata conflict"
            confidence = " — high confidence (\(confirmed)/\(total) offsets agree)"
        } else {
            header = "Metadata conflict"
            confidence = " — \(confirmed)/\(total) offsets matched, rest returned no match"
        }
        return """
            \(header)\(confidence)
            Tagged: \(tagged.title) — \(tagArtist)
            Shazam: \(shTitle) — \(shArtist)
            """
    }
}
#endif
