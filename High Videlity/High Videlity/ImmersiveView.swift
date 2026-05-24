//
//  ImmersiveView.swift
//  High Videlity
//
//  Created by Jesse Griffith on 5/18/26.
//

#if os(visionOS)

import SwiftUI
import RealityKit

struct ImmersiveView: View {

    @Environment(AppModel.self) private var appModel

    var body: some View {
        RealityView { content in
            // Song is analyzed by the time the immersive space opens; build
            // the visualizer synchronously per the selected mode.
            switch appModel.mode {
            case .crystal:
                let crystal = appModel.useCrystalV2
                    ? await CrystalVisualizerV2.makeCrystal(from: appModel.frames)
                    : await CrystalVisualizer.makeCrystal(from: appModel.frames)
                content.add(crystal)
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    CrystalVisualizer.animate(
                        crystal,
                        clock: appModel.playbackTime,
                        energy: appModel.currentEnergy(),
                        deltaTime: event.deltaTime,
                        camPos: &appModel.camPos,
                        camLook: &appModel.camLook
                    )
                }

            case .clouds:
                let clouds = CloudVisualizer.makeClouds(from: appModel.frames)
                content.add(clouds)
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    CloudVisualizer.animate(
                        clouds,
                        clock: appModel.playbackTime,
                        frames: appModel.frames,
                        deltaTime: event.deltaTime,
                        liveLoudness: appModel.useMic ? appModel.currentEnergy() : -1,
                        micOnsetCount: appModel.useMic ? appModel.micOnsetCount : 0,
                        useMic: appModel.useMic,
                        // Wire the reset counter even though visionOS has no
                        // system-audio path today — when future mic-streaming
                        // live mode lands on visionOS, this plug is already
                        // in place. Counter starts at 0 and only bumps when
                        // a live source detects a track change, so no-op for
                        // current visionOS preview-only flow.
                        appResetCounter: appModel.liveModeResetCounter
                    )
                }

            case .rings:
                let rings = await RingsVisualizer.makeRings(from: appModel.frames)
                content.add(rings)
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    RingsVisualizer.animate(
                        rings,
                        clock: appModel.playbackTime,
                        frames: appModel.frames,
                        deltaTime: event.deltaTime,
                        appResetCounter: appModel.liveModeResetCounter
                    )
                }

            case .architecture:
                let arch = await ArchitectureVisualizer.makeArchitecture(from: appModel.frames)
                content.add(arch)
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    ArchitectureVisualizer.animate(
                        arch,
                        clock: appModel.playbackTime,
                        energy: appModel.currentEnergy(),
                        deltaTime: event.deltaTime
                    )
                }

            case .slipstream:
                let slipstream = SlipstreamVisualizer.makeSlipstream(from: appModel.frames)
                content.add(slipstream)
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    SlipstreamVisualizer.animate(
                        slipstream,
                        clock: appModel.playbackTime,
                        frames: appModel.frames,
                        deltaTime: event.deltaTime,
                        appResetCounter: appModel.liveModeResetCounter
                    )
                }

            case .ambient:
                let ambient = await AmbientVisualizer.makeAmbient(from: appModel.frames)
                content.add(ambient)
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    AmbientVisualizer.animate(
                        ambient,
                        clock: appModel.playbackTime,
                        frames: appModel.frames,
                        deltaTime: event.deltaTime,
                        appResetCounter: appModel.liveModeResetCounter
                    )
                }

            case .dodecahedron:
                let dodec = await DodecahedronVisualizer.makeDodecahedron(from: appModel.frames)
                content.add(dodec)
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    DodecahedronVisualizer.animate(
                        dodec,
                        clock: appModel.playbackTime,
                        frames: appModel.frames,
                        deltaTime: event.deltaTime,
                        appResetCounter: appModel.liveModeResetCounter,
                        bpmOverride: appModel.shazamBpmOverride,
                        danceabilityOverride: appModel.shazamDanceabilityOverride
                    )
                }
            }
        }
        .onAppear { appModel.startPlayback() }
        .onDisappear { appModel.stopPlayback() }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}

#endif
