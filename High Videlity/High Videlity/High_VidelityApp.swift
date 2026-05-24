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
    }

    var body: some SwiftUI.Scene {
        WindowGroup {
            #if os(visionOS)
            ContentView()
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
