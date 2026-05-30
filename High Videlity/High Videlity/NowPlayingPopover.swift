//
//  NowPlayingPopover.swift
//  High Videlity
//
//  Replacement for the right-side Now-Playing inspector drawer.
//  Hosts the Up Next list + Lyrics, tabbed. Anchored from the
//  GlobalNowPlayingFooter's source block — click the title /
//  artwork to open.
//
//  No track header inside the popover (the source block already
//  shows artwork + title + artist below the arrow), no transport
//  controls (the footer's MiniTransport sits a few pixels away),
//  no scrubber (NowPlayingView's 8 Hz playbackTime read was the
//  main FPS-cost the inspector imposed; the popover deliberately
//  omits it). Just the two pieces of content the inspector was
//  actually useful for.
//

#if !os(visionOS)
import SwiftUI

struct NowPlayingPopover: View {

    @Environment(AppModel.self) private var appModel

    private enum Tab: String, CaseIterable, Identifiable {
        case upNext = "Up Next"
        case lyrics = "Lyrics"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .upNext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .upNext:
            ScrollView {
                UpNextView(appModel: appModel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .lyrics:
            LyricsView()
        }
    }
}
#endif
