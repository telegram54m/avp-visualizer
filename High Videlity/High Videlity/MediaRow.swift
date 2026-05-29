//
//  MediaRow.swift
//  High Videlity
//
//  Reusable card-style row for songs, albums, artists, playlists.
//  Replaces the .bordered-button-stack pattern that gave the app a
//  form-like feel. Modern aesthetic:
//
//    - No permanent button chrome. The row is a flat surface with a
//      subtle hover-state background tint, like Apple Music / Spotify.
//    - Artwork on the left (size + corner controlled per usage).
//    - Title / subtitle stacked, semibold title, secondary subtitle.
//    - Trailing accessory area — chevron for drill-down rows, play
//      icon for tap-to-play songs, or inline action buttons that
//      appear on hover for richer surfaces.
//    - Tap target is the whole row.
//    - Context menu carries the same actions as the hover bar so
//      right-click works regardless of pointer position.
//
//  Cross-platform: on iOS / iPadOS the hover state never fires (no
//  pointer), so rows always show the resting accessory. The tap
//  target and context menu still work, so functionality is intact.
//  Phase 7's iOS shell port can later add iOS-specific row treatments
//  (e.g. swipe actions) if desired.
//

import SwiftUI
import MusicKit

/// Shape of the trailing accessory on a `MediaRow`. Determines what
/// shows on the right side of the row when the cursor isn't over it,
/// and what (if anything) appears on hover.
enum MediaRowAccessory {
    /// No accessory glyph. Used for plain decorative rows.
    case none
    /// Play glyph at rest; on hover, swap for the hover actions bar.
    case play
    /// Chevron drill-down glyph at rest; hover shows the actions bar.
    case chevron
}

/// One hover-revealed inline action. Rendered as a borderless icon
/// button on the right side of the row when the cursor enters.
struct MediaRowAction: Identifiable {
    let id = UUID()
    let systemImage: String
    let help: String
    let perform: () -> Void
}

/// Reusable row. Pass artwork (any of MusicKit's `Artwork` instances),
/// a title, optional subtitle, and the trailing accessory shape +
/// optional hover actions. The `tap` closure runs on row tap (also
/// triggered by Return when the row has keyboard focus).
struct MediaRow: View {
    let artwork: Artwork?
    let title: String
    let subtitle: String?
    var artworkSize: CGFloat = 44
    var artworkCornerRadius: CGFloat = 6
    var accessory: MediaRowAccessory = .none
    /// Whether to wrap the row in its own Button. Set `false` when
    /// the row is used as a NavigationLink label — without this, the
    /// inner Button consumes the tap before NavigationLink can push.
    /// Hover state and context menu still work either way.
    var tappable: Bool = true
    var hoverActions: [MediaRowAction] = []
    var contextActions: [MediaRowAction] = []
    var tap: () -> Void = {}

    @State private var hovered = false

    var body: some View {
        Group {
            if tappable {
                Button(action: tap) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .onHover { hovered = $0 }
        .contextMenu {
            if !contextActions.isEmpty {
                ForEach(contextActions) { action in
                    Button(action: action.perform) {
                        Label(action.help, systemImage: action.systemImage)
                    }
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: artwork, size: artworkSize,
                        cornerRadius: artworkCornerRadius)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
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

    @ViewBuilder
    private var trailing: some View {
        if hovered && !hoverActions.isEmpty {
            HStack(spacing: 4) {
                ForEach(hoverActions) { action in
                    Button(action: action.perform) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(action.help)
                }
            }
        } else {
            switch accessory {
            case .none:
                EmptyView()
            case .play:
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, height: 26)
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, height: 26)
            }
        }
    }
}

/// Compact row for album / playlist track listings. No per-track
/// artwork (the parent detail view shows the album/playlist art
/// once at the top). Position number on the left, title in the
/// middle, optional trailing duration. Same hover background +
/// hover-revealed actions + context menu pattern as MediaRow so
/// the two read as siblings.
struct TrackRow: View {
    let position: Int
    let title: String
    let subtitle: String?
    let durationSeconds: TimeInterval?
    var hoverActions: [MediaRowAction] = []
    var contextActions: [MediaRowAction] = []
    var isDisabled: Bool = false
    var tap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                // Track number replaces artwork. On hover, swap for
                // a play glyph — same affordance Apple Music uses on
                // their track listings.
                ZStack {
                    if hovered && !isDisabled {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                    } else {
                        Text("\(position)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(isDisabled ? .secondary : .primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if hovered && !hoverActions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(hoverActions) { action in
                            Button(action: action.perform) {
                                Image(systemName: action.systemImage)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26, height: 26)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(action.help)
                        }
                    }
                } else if let dur = durationSeconds {
                    Text(formatDuration(dur))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered && !isDisabled ? Color.primary.opacity(0.06) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovered = $0 }
        .contextMenu {
            if !contextActions.isEmpty {
                ForEach(contextActions) { action in
                    Button(action: action.perform) {
                        Label(action.help, systemImage: action.systemImage)
                    }
                }
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Detail hero

/// Large header treatment shared by album / playlist / artist detail
/// views. Big artwork on the left, eyebrow + title + subtitle stack on
/// the right with optional metadata line and two action buttons below.
/// Backdrop tint pulled from the artwork's pre-computed
/// `backgroundColor` (free via MusicKit's Artwork — no async fetch).
///
/// Layouts that don't fit this shape (e.g., an Artist view that wants
/// circular artwork and no subtitle) can still build a custom header;
/// this is just the common case.
struct DetailHero<BottomContent: View>: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?
    let metadata: String?
    let artwork: Artwork?
    var artworkSize: CGFloat = 180
    var artworkCornerRadius: CGFloat = 8
    var artworkIsCircular: Bool = false
    /// CGColor extracted from artwork for the backdrop tint. Usually
    /// `artwork?.backgroundColor`; passed explicitly so callers can
    /// substitute a different tint when artwork is missing.
    var tintColor: CGColor?
    var primaryAction: (label: String, systemImage: String, perform: () -> Void)?
    var secondaryAction: (label: String, systemImage: String, perform: () -> Void)?
    /// Optional content rendered below the metadata line (above the
    /// action row). Used by ArtistDetailView for the inline bio so
    /// the About card doesn't claim its own vertical real estate.
    @ViewBuilder var bottomContent: () -> BottomContent

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Backdrop: soft horizontal gradient from the artwork's
            // dominant color into the system background. Rendered
            // behind the content so artwork shadow + buttons sit on
            // top crisply.
            backdrop
            HStack(alignment: .top, spacing: 24) {
                artworkBlock
                VStack(alignment: .leading, spacing: 6) {
                    if let eyebrow {
                        Text(eyebrow)
                            .font(.caption2.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.title.weight(.bold))
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let metadata, !metadata.isEmpty {
                        Text(metadata)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    bottomContent()
                    actionRow
                        .padding(.top, 10)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        if let tintColor {
            LinearGradient(
                colors: [
                    Color(cgColor: tintColor).opacity(0.45),
                    Color(cgColor: tintColor).opacity(0.10),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private var artworkBlock: some View {
        let shape: AnyShape = artworkIsCircular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
        ArtworkView(
            artwork: artwork,
            size: artworkSize,
            cornerRadius: artworkIsCircular ? artworkSize / 2 : artworkCornerRadius
        )
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 6)
        .clipShape(shape)
    }

    @ViewBuilder
    private var actionRow: some View {
        if primaryAction != nil || secondaryAction != nil {
            HStack(spacing: 10) {
                if let p = primaryAction {
                    Button(action: p.perform) {
                        Label(p.label, systemImage: p.systemImage)
                    }
                    .buttonStyle(GradientPillButtonStyle())
                }
                if let s = secondaryAction {
                    Button(action: s.perform) {
                        Label(s.label, systemImage: s.systemImage)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

/// Convenience init for callers that don't need a bottomContent
/// slot — AlbumDetailView, PlaylistDetailView. Lets them keep their
/// trailing-comma signature without `bottomContent: { EmptyView() }`.
extension DetailHero where BottomContent == EmptyView {
    init(
        eyebrow: String?,
        title: String,
        subtitle: String?,
        metadata: String?,
        artwork: Artwork?,
        artworkSize: CGFloat = 180,
        artworkCornerRadius: CGFloat = 8,
        artworkIsCircular: Bool = false,
        tintColor: CGColor? = nil,
        primaryAction: (label: String, systemImage: String, perform: () -> Void)? = nil,
        secondaryAction: (label: String, systemImage: String, perform: () -> Void)? = nil
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.metadata = metadata
        self.artwork = artwork
        self.artworkSize = artworkSize
        self.artworkCornerRadius = artworkCornerRadius
        self.artworkIsCircular = artworkIsCircular
        self.tintColor = tintColor
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.bottomContent = { EmptyView() }
    }
}

/// Accent-color gradient pill button — used for primary actions in
/// detail heroes, the Open Visualizer button in the footer, etc.
/// Hover and pressed states are baked in.
struct GradientPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background {
                Capsule().fill(Color.accentColor.gradient)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .shadow(color: .accentColor.opacity(0.3), radius: 5, x: 0, y: 2)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Empty placeholder

/// Large tappable action card. Used in LocalSourceView (and any
/// future welcome surface) to present two-or-three distinct paths a
/// user can take, each with an icon, title, and short description.
/// More inviting than a row of `.bordered` buttons; uniform sizing
/// across a grid keeps the surface tidy on resize.
struct ActionCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var tint: Color = .accentColor
    var perform: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(hovered ? 0.8 : 0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(hovered ? AnyShapeStyle(tint.opacity(0.4)) : AnyShapeStyle(.quaternary),
                            lineWidth: hovered ? 1.5 : 0.5)
            }
            .scaleEffect(hovered ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

/// Reusable "nothing here" state. Centered glyph + headline +
/// supporting copy. Used across detail views, library tabs, and
/// browse sections when the underlying data is empty.
struct EmptyPlaceholder: View {
    let systemImage: String
    let title: String
    let message: String?

    init(systemImage: String, title: String, message: String? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
