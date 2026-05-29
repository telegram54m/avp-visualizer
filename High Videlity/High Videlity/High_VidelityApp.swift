//
//  High_VidelityApp.swift
//  High Videlity
//
//  Created by Jesse Griffith on 5/18/26.
//

import SwiftUI
import RealityKit

@main
struct High_VidelityApp: App {

    @State private var appModel = AppModel()

    init() {
        ShardComponent.registerComponent()
        // Pull any new cache records (alignment offsets + song
        // metadata) the user accumulated on other Apple devices into
        // local UserDefaults. Fire and forget; all read paths remain
        // local-first so this can take its time without blocking
        // anything. See [[CloudCacheSync]].
        Task.detached(priority: .utility) {
            await CloudCacheSync.shared.bootstrapSync()
        }
        // Both `runSelfTest()` (private DB) and `runPublicSelfTest()`
        // (public DB) are still wired in DEBUG (see CloudCacheSync.swift)
        // — call them manually from a debug hook if the wiring ever
        // needs re-verifying. Both have been seen to PASS on real
        // launches; auto-firing on every launch is wasteful.
    }

    var body: some SwiftUI.Scene {
        WindowGroup {
            #if os(visionOS)
            ContentView()
                .environment(appModel)
            #elseif os(macOS)
            // Phase 7 — sidebar shell with persistent now-playing
            // footer. RootShellView swaps the entire window for
            // the full-bleed VisualizerView when
            // appModel.showVisualizer is true, so the visualizer
            // doesn't need its own NavigationStack push anymore.
            RootShellView()
                .environment(appModel)
            #else
            NavigationStack {
                ContentView()
                    .environment(appModel)
            }
            #endif
        }

        #if os(visionOS)
        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        #endif
     }
}
