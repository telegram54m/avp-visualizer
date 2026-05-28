//
//  AirPlayButton.swift
//  High Videlity
//
//  Thin SwiftUI wrapper around AVRoutePickerView so users can pick an
//  AirPlay output for the audio session from inside the app. macOS
//  and iOS both expose AVRoutePickerView via AVKit; we provide a
//  representable per platform that maps to NS / UI view respectively.
//
//  Note on macOS routing: ApplicationMusicPlayer doesn't use AVAudio
//  session APIs directly — it routes through macOS's RemotePlayerService.
//  AVRoutePickerView on macOS still controls the system audio output
//  (the same surface as Control Center's Sound flyout), and that's
//  where AM plays through. So even though the routing chain is
//  indirect, the picker DOES affect AM output.
//

import SwiftUI
import AVKit

#if os(macOS)
import AppKit

struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .label
        view.activeTintColor = .systemBlue
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
