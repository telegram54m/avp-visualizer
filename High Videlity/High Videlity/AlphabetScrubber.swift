//
//  AlphabetScrubber.swift
//  High Videlity
//
//  Generic horizontal scroll row with a glass-lens A-Z scrubber
//  overlay. Used wherever the user might page through many items
//  in a horizontal carousel (album / artist / playlist rows on
//  Apple Music + Local Library home pages).
//
//  Scrubbing is press-and-drag, not hover — hovering the bar
//  reveals it but doesn't move the row. Pressing inside the bar
//  pops a liquid-glass circle lens centered on the active letter
//  (iOS-style alphabet scrubber); dragging across letters scrolls
//  the row to the first item in each bucket. Release dismisses
//  the lens.
//

#if os(macOS)
import SwiftUI

/// Horizontal scrolling row with a hover-revealed A-Z scrubber.
/// Used for the library Albums / Artists / Playlists rows where
/// users may have hundreds of items and need fast navigation.
///
/// Letters absent from the row are still rendered (in muted
/// foreground) so the bar always has the same A-Z width; this
/// keeps the layout stable when filter results change the
/// represented letters.
struct AlphabetIndexedRow<Item: Identifiable, Content: View>: View
where Item.ID: Hashable {
    let title: String
    let items: [Item]
    let firstLetter: (Item) -> Character
    @ViewBuilder let content: (Item) -> Content

    @State private var barHovered = false
    @State private var rowHovered = false

    /// Map of bucket letter → ID of the first item in that bucket.
    /// Recomputed each body eval — cheap (linear in items count) and
    /// stays accurate as the filter changes the items array.
    private var anchorByLetter: [Character: Item.ID] {
        var seen: [Character: Item.ID] = [:]
        for item in items {
            let letter = firstLetter(item)
            if seen[letter] == nil {
                seen[letter] = item.id
            }
        }
        return seen
    }

    private static var alphabet: [Character] {
        ["#"] + Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    }

    var body: some View {
        let anchors = anchorByLetter
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                // Title row with the A-Z scrubber as a center overlay.
                // ZStack lets the title sit leading-aligned while the
                // bar floats horizontally centered in the same row
                // regardless of title length. The bar is hidden by
                // default and fades in on row OR bar hover.
                ZStack {
                    HStack {
                        Text(title)
                            .font(.title3.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    if rowHovered || barHovered {
                        AlphabetBar(
                            alphabet: Self.alphabet,
                            presentLetters: Set(anchors.keys),
                            onScrubLetter: { letter in
                                guard let id = anchors[letter] else { return }
                                withAnimation(.easeOut(duration: 0.18)) {
                                    proxy.scrollTo(id, anchor: .leading)
                                }
                            },
                            onBarHover: { barHovered = $0 }
                        )
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 24)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            content(item).id(item.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                rowHovered = hovering
            }
        }
    }
}

/// Compact letter strip used by `AlphabetIndexedRow`. Letters absent
/// from the row's items are still rendered, just muted, so the bar
/// width stays stable as filter results change.
///
/// Scrubbing is **click-and-drag**, not hover — hovering over the
/// bar reveals it but doesn't move the row. Once the user presses
/// inside the bar, a liquid-glass lens floats above the active
/// letter (iOS-style alphabet scrubber) and the row scrolls to the
/// first item in that letter's bucket as the cursor crosses each
/// letter. Release dismisses the lens.
struct AlphabetBar: View {
    let alphabet: [Character]
    let presentLetters: Set<Character>
    let onScrubLetter: (Character) -> Void
    let onBarHover: (Bool) -> Void

    @State private var activeIndex: Int?

    private let letterWidth: CGFloat = 12
    private let letterSpacing: CGFloat = 1
    private let hPadding: CGFloat = 6
    private let vPadding: CGFloat = 3

    /// Horizontal step (per letter) used to map a drag x-offset
    /// back to an alphabet index. Includes the inter-letter
    /// spacing so the boundaries match the rendered glyphs.
    private var step: CGFloat { letterWidth + letterSpacing }

    var body: some View {
        HStack(spacing: letterSpacing) {
            ForEach(Array(alphabet.enumerated()), id: \.element) { idx, letter in
                Text(String(letter))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(letterColor(letter, idx: idx))
                    .frame(width: letterWidth, height: 16)
            }
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(.quaternary, lineWidth: 0.5)
        }
        .contentShape(Capsule())
        .gesture(scrubGesture)
        .overlay(alignment: .topLeading) { lensOverlay }
        .onHover { onBarHover($0) }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let x = value.location.x - hPadding
                let raw = Int((x / step).rounded(.down))
                let idx = max(0, min(alphabet.count - 1, raw))
                if idx != activeIndex {
                    activeIndex = idx
                    let letter = alphabet[idx]
                    // Only scroll for present letters — sliding
                    // across absent buckets shouldn't yank the row
                    // back, the lens still shows the absent glyph
                    // so the user sees where they are.
                    if presentLetters.contains(letter) {
                        onScrubLetter(letter)
                    }
                }
            }
            .onEnded { _ in
                activeIndex = nil
            }
    }

    @ViewBuilder
    private var lensOverlay: some View {
        if let idx = activeIndex {
            let letter = alphabet[idx]
            let centerX = hPadding + CGFloat(idx) * step + letterWidth / 2
            // Bar height = vPadding + glyph (16) + vPadding. Centering
            // the lens on that midline keeps it sitting on top of the
            // strip (magnifier feel) rather than floating above. The
            // lens is just slightly bigger than the bar, so the bottom
            // hangs ~5pt below and the top ~5pt above — reads as a
            // glass disc resting on the rail.
            let barMidY = vPadding + 8
            let lensSize: CGFloat = 30
            Text(String(letter))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: lensSize, height: lensSize)
                .glassEffect(in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.45), lineWidth: 0.75) }
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .position(x: centerX, y: barMidY)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }

    private func letterColor(_ letter: Character, idx: Int) -> Color {
        if activeIndex == idx { return .primary }
        return presentLetters.contains(letter) ? .secondary : Color.secondary.opacity(0.35)
    }
}

/// First-letter bucket helper. Non-alphabetic leads fall into the
/// "#" bucket so numeric or symbolic titles aren't silently dropped
/// from the scrubber. Articles ("The ", "A ", "An ") are skipped
/// the way Music.app does.
func alphabetBucket(_ s: String) -> Character {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    let stripped: String
    if trimmed.lowercased().hasPrefix("the ") {
        stripped = String(trimmed.dropFirst(4))
    } else if trimmed.lowercased().hasPrefix("an ") {
        stripped = String(trimmed.dropFirst(3))
    } else if trimmed.lowercased().hasPrefix("a ") {
        stripped = String(trimmed.dropFirst(2))
    } else {
        stripped = trimmed
    }
    guard let first = stripped.first else { return "#" }
    let upper = Character(first.uppercased())
    if ("A"..."Z").contains(upper) { return upper }
    return "#"
}
#endif
