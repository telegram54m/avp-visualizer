//
//  VisualizerView.swift
//  High Videlity
//
//  Non-immersive visualizer host for iOS / iPadOS / macOS / tvOS. Builds the
//  same RealityKit scene as ImmersiveView but inside a regular SwiftUI window
//  / view, with a black background and an orbital camera framing the cluster.
//  visionOS uses ImmersiveView instead for the head-locked immersive space.
//

#if !os(visionOS)

import SwiftUI
import RealityKit
import MusicKit
import AudioAnalysis

struct VisualizerView: View {

    @Environment(AppModel.self) private var appModel
    /// iOS-only: dismiss the fullScreenCover. Wired to the in-viz
    /// close button. Other platforms use NavigationLink push and
    /// dismiss via the standard back navigation, so the environment
    /// dismiss action isn't needed there.
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    /// Drag-start snapshot of (yaw, pitch) for Ambient's free-look camera.
    /// Set on the first `.onChanged` of a drag, cleared on `.onEnded`,
    /// so subsequent .onChanged ticks compute delta from a stable origin
    /// rather than re-snapshotting on every move tick. Ambient-only; the
    /// gesture is a no-op when the user is in any other mode.
    @State private var ambientDragStart: (yaw: Float, pitch: Float)? = nil

    var body: some View {
        // `.id(appModel.mode)` below makes SwiftUI rebuild the entire
        // RealityView when the user cycles modes from the in-viz button —
        // each mode's scene needs its own entity tree + animate subscription,
        // and tearing down + rebuilding is the simplest reliable hand-off.
        // The make closure is cheap to re-run for our scenes (small entity
        // counts), and the old subscription auto-cancels when AppModel
        // overwrites `sceneUpdateSubscription` in the new make.
        RealityView { content in
            // No explicit PerspectiveCamera entity. `RealityViewCameraContent`
            // already manages an implicit virtual camera; adding our own
            // breaks `renderingEffects.customPostProcessing` (precondition
            // fails inside ARView.renderCallbacks.setter). Instead, we drive
            // framing by transforming the *world* — same pattern the visionOS
            // immersive view uses (`useHeadLockedCamera: true` in animate).

            // RealityView's default background is transparent. Additive
            // blend math (dst = bg + src) doesn't compose onto a transparent
            // destination — the pixels stay alpha-zero and SwiftUI's
            // `.background(Color.black)` shows through unchanged, so the
            // additive beams never light up. A big opaque-black sphere with
            // backface-culling-off acts as a render-only backdrop: camera
            // sits inside it, every ray exits through the sphere first, the
            // additive beams have a concrete dark surface to add onto.
            // Backdrop colour matches the HTML reference's clearcolor 0x070709
            // (very dark blue-black, not pure black). Cloud-mode sprites use
            // alpha blending against this; pure black would produce harder
            // edges where the sprite alpha falls to zero.
            let backdrop = ModelEntity(
                mesh: .generateSphere(radius: 50),
                materials: [UnlitMaterial(color: PlatformColor(
                    red: 7.0/255, green: 7.0/255, blue: 9.0/255, alpha: 1.0
                ))]
            )
            // Default sphere is single-sided front-facing; flip the scale
            // so the inward face is what the camera sees.
            backdrop.scale = [-1, 1, 1]
            content.add(backdrop)

            // Film grain is now handled by `GrainOverlay` (SwiftUI .overlay
            // below) — a faithful port of the HTML reference's timbre-driven
            // tiled noise canvas. RealityKit's built-in `cameraGrain` ran on
            // every pixel uniformly and didn't react to the audio, so we keep
            // it off here.
            // HDR rendering on capable displays so HDR-boosted colors drive
            // the panel past SDR white instead of being silently clipped.
            content.renderingEffects.dynamicRange = .default
            // Real Gaussian bloom via CIBloom. Requires NO explicit camera
            // entity in the scene (see comment above) — that's why this
            // setup looks different from a typical RealityView.
            content.renderingEffects.customPostProcessing = .effect(BloomPostProcessEffect())

            // In live system-audio mode the visualizers grow incrementally
            // from frames streamed by `SystemAudioListener` — pre-built
            // makeXxx(from: frames) would only see whatever was loaded
            // before the toggle (typically the preview frames). The Live
            // path builds an empty root + a state component; animate-tick
            // scans newly-appended frames for onsets and spawns entities.
            #if os(macOS)
            let isLive = appModel.useSystemAudio
            #else
            let isLive = false
            #endif
            // Slipstream-specific: local-file playback wants the
            // live-spawn path (incremental gates with stem-isolated
            // onsets) rather than the preview-path pre-spawn (which
            // assumes constant corridor speed and breaks for full
            // songs where bass-modulated speed accumulates drift —
            // gates flow off-screen before reaching the camera).
            // Treat local file as live for Slipstream, with a
            // playback-bounded scan so we don't process all of
            // `frames` in a single tick.
            let isLocalFilePlayback = appModel.hasLocalPlaybackSource && !isLive

            // Snapshot frames.count at view-open time. Live builders seed
            // `lastSeenFrameIndex` to this so the first scanForNewOnsets
            // tick only walks frames that arrive AFTER the visualizer
            // opens — otherwise the visualizer would catch up on every
            // accumulated onset (potentially hundreds, since system audio
            // can have been on for a while in ContentView) in a single
            // tick and stall the render.
            let liveStartIndex = appModel.frames.count
            let liveStartResetCounter = appModel.liveModeResetCounter

            // Each `case` below adds its scene root to `content` AND publishes
            // a weak ref to AppModel.debugSceneRoot so the diag logger can
            // recursively count entities per snapshot. The ref is overwritten
            // on every mode-cycle remount; the prior root releases naturally
            // since debugSceneRoot is `weak`. Done inside the switch (not at
            // the top) so we capture the actual mode-specific root entity.
            // RELEASE-CLEANUP — five `appModel.debugSceneRoot = …` assignments
            // below; remove with the rest of the diag chain. See note in
            // AppModel.swift.

            switch appModel.mode {
            case .crystal:
                // V2 only. The legacy v1 (stacked cylinders) was
                // retired with the Visualizers-page rebuild —
                // CrystalVisualizer.swift is dead code now, kept on
                // disk for diff context only.
                let crystal: Entity
                if isLive {
                    crystal = await CrystalVisualizerV2.makeCrystalLive(
                        startingFrameIndex: liveStartIndex,
                        startingResetCounter: liveStartResetCounter
                    )
                } else {
                    crystal = await CrystalVisualizerV2.makeCrystal(from: appModel.frames)
                }
                crystal.position = .zero
                content.add(crystal)
                appModel.debugSceneRoot = crystal
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    if isLive {
                        CrystalVisualizerV2.scanForNewOnsets(
                            crystal,
                            frames: appModel.frames,
                            appResetCounter: appModel.liveModeResetCounter
                        )
                    }
                    // Head-locked: animate applies the inverse camera
                    // transform to the cluster so the implicit virtual
                    // camera at origin sees the HTML orbital frame.
                    CrystalVisualizer.animate(
                        crystal,
                        clock: appModel.playbackTime,
                        energy: appModel.currentEnergy(),
                        deltaTime: event.deltaTime,
                        camPos: &appModel.camPos,
                        camLook: &appModel.camLook,
                        useHeadLockedCamera: true,
                        // Windowed RealityView's implicit virtual camera
                        // sits at world origin — not at the immersive-space
                        // eye height of 1.5m. Without overriding the eye,
                        // the inverse-camera transform pushes the cluster
                        // ~1.5m above the camera and only the top fringe
                        // intersects the viewport.
                        eye: .zero
                    )
                }

            case .clouds:
                // In live system-audio mode, pass `frames.count` so the new
                // scene starts at the live tip and the first animate tick
                // doesn't replay every onset accumulated before view-open.
                // In preview mode pass 0 = walk-all-frames (default).
                let clouds = CloudVisualizer.makeClouds(
                    from: appModel.frames,
                    startingFrameIndex: isLive ? liveStartIndex : 0,
                    startingResetCounter: liveStartResetCounter
                )
                // CloudVisualizer builds sprites around cloudCenter (0, 1.45, -1.5).
                // To frame them as if the camera were at (0, 1.45, 1.0) looking
                // at (0, 1.45, -1.5), translate the cluster by -eye so the
                // implicit camera at origin (looking down -Z) gets the same view.
                clouds.position = SIMD3<Float>(0, -1.45, -1.0)
                content.add(clouds)
                appModel.debugSceneRoot = clouds
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
                        // Pass the reset counter so Shazam-driven track
                        // changes clear per-song state (lastIndex, onsetKick,
                        // main-sprite perturbations). No-op in preview mode
                        // (counter never bumps).
                        appResetCounter: appModel.liveModeResetCounter
                    )
                }

            case .rings:
                let rings = await RingsVisualizer.makeRings(
                    from: appModel.frames,
                    startingFrameIndex: isLive ? liveStartIndex : 0,
                    startingResetCounter: liveStartResetCounter
                )
                // RingsVisualizer.makeRings sets root.position = (0, 1.3, -2.5)
                // assuming the visionOS immersive eye-height frame. The
                // windowed virtual camera sits at world origin, so position
                // the cluster directly in front (y=0) instead — otherwise it
                // appears low/cut-off at the bottom of the window. Same
                // class of fix as the eye=.zero parameter for the Crystal
                // animate path.
                rings.position = SIMD3<Float>(0, 0, -2.5)
                // Orientation is set inside makeRings (downward tilt) and
                // captured lazily by animate() as the base for auto-orbit.
                // Don't re-set it here.
                content.add(rings)
                appModel.debugSceneRoot = rings
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    RingsVisualizer.animate(
                        rings,
                        clock: appModel.playbackTime,
                        frames: appModel.frames,
                        deltaTime: event.deltaTime,
                        // Track-change reset wiring — same as Clouds. Clears
                        // ripples and re-inits hue smoothing on track change.
                        appResetCounter: appModel.liveModeResetCounter,
                        bpmOverride: appModel.shazamBpmOverride,
                        happinessOverride: appModel.shazamHappinessOverride,
                        keyOverride: appModel.shazamKeyOverride
                    )
                }

            case .slipstream:
                // Three constructor paths:
                //   • isLive (system-audio streaming): empty root,
                //     scanForNewOnsets walks live-appended frames.
                //   • isLocalFilePlayback (full-song from library /
                //     import): empty root, scanForNewOnsets walks
                //     frames bounded by current playbackTime so gates
                //     spawn incrementally as playback advances.
                //   • else (preview-only): pre-spawn all gates from
                //     the 30-second iTunes preview.
                let useLiveSpawn = isLive || isLocalFilePlayback
                let slipstream: Entity = useLiveSpawn
                    ? SlipstreamVisualizer.makeSlipstreamLive(
                        // Local file starts from frame 0 so gates spawn
                        // throughout the song. Live streaming seeds
                        // past current frames so we don't replay
                        // history of onsets captured pre-toggle.
                        startingFrameIndex: isLive ? liveStartIndex : 0,
                        startingResetCounter: liveStartResetCounter
                      )
                    : SlipstreamVisualizer.makeSlipstream(from: appModel.frames)
                // Same windowed-eye-height adjustment as Rings / Architecture
                // — the immersive eye frame puts the corridor at y=1.45,
                // but the windowed virtual camera is at origin, so center
                // vertically. The corridor lives along -Z to +Z so x stays 0.
                slipstream.position = SIMD3<Float>(0, 0, 0)
                content.add(slipstream)
                appModel.debugSceneRoot = slipstream
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    if useLiveSpawn {
                        // For LOCAL FILE: bound the scan to current
                        // playback frame + ~2s lookahead. The lookahead
                        // lets gates spawn slightly ahead of the audio
                        // onset so they have time to flow from the
                        // spawn frontier (-spawnDistance) forward to
                        // the camera as playback reaches their onset
                        // moment. ~60 frames = 2 sec at 30 fps.
                        // For LIVE streaming: no bound (frames grows
                        // naturally, scan everything available).
                        let bound: Int? = isLocalFilePlayback
                            ? Int((appModel.playbackTime * 30).rounded()) + 60
                            : nil
                        SlipstreamVisualizer.scanForNewOnsets(
                            slipstream,
                            frames: appModel.frames,
                            appResetCounter: appModel.liveModeResetCounter,
                            stemFeatures: appModel.stemFeatures,
                            stemFrameOffset: appModel.stemFrameOffset,
                            playbackUpperBoundFrame: bound
                        )
                    }
                    SlipstreamVisualizer.animate(
                        slipstream,
                        clock: appModel.playbackTime,
                        frames: appModel.frames,
                        deltaTime: event.deltaTime,
                        appResetCounter: appModel.liveModeResetCounter,
                        bpmOverride: appModel.shazamBpmOverride,
                        danceabilityOverride: appModel.shazamDanceabilityOverride,
                        aggressivenessOverride: appModel.shazamAggressivenessOverride,
                        happinessOverride: appModel.shazamHappinessOverride,
                        timbreBrightnessOverride: appModel.shazamTimbreBrightnessOverride,
                        stemFeatures: appModel.stemFeatures,
                        stemFrameOffset: appModel.stemFrameOffset
                    )
                }

            case .ambient:
                // Ambient's makeAmbient positions the root at visionOS eye
                // height (0, 1.45, 0); override to (0, 0, 0) for the
                // windowed virtual camera at world origin. The 12 streaks
                // are placed in the XZ plane at streakRadius=6m around
                // the root, so the windowed viewer sees the ring centered
                // and at eye level. Same windowed-eye-height-fix pattern
                // used by Rings/Architecture/Slipstream.
                //
                // Reset draggable-camera state on every mount so each
                // entry into Ambient starts at the curated framing — the
                // horizon at ~35% from the top of the frame, lake filling
                // the lower 2/3. Pitch +0.17 rad ≈ 10° down-tilt achieves
                // that with the standard windowed FOV.
                appModel.ambientDragYaw = 0
                appModel.ambientDragPitch = 0.17
                let ambient = await AmbientVisualizer.makeAmbient(from: appModel.frames)
                ambient.position = SIMD3<Float>(0, 0, 0)
                content.add(ambient)
                appModel.debugSceneRoot = ambient
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    // Apply draggable-camera orientation. yaw_quat first
                    // then pitch_quat (read right-to-left in the
                    // multiplication) gives "yaw around world Y, then
                    // tilt around the resulting local X" — the natural
                    // first-person look-around composition.
                    let yawQ = simd_quatf(angle: appModel.ambientDragYaw, axis: [0, 1, 0])
                    let pitchQ = simd_quatf(angle: appModel.ambientDragPitch, axis: [1, 0, 0])
                    ambient.orientation = pitchQ * yawQ
                    AmbientVisualizer.animate(
                        ambient,
                        clock: appModel.playbackTime,
                        frames: appModel.frames,
                        deltaTime: event.deltaTime,
                        appResetCounter: appModel.liveModeResetCounter,
                        stemFeatures: appModel.stemFeatures
                    )
                }

            case .dodecahedron:
                // makeDodecahedron places the root at visionOS eye height
                // and faceDistance in front of the viewer. Override to
                // world origin for the windowed virtual camera; the
                // dodecahedron is already centered in its local space
                // relative to the root, so the forwardDistance offset
                // (-1.5 m) is preserved by NOT zeroing the entire root.
                // Instead zero just the Y component.
                let dodec = await DodecahedronVisualizer.makeDodecahedron(from: appModel.frames)
                dodec.position = SIMD3<Float>(0, 0, DodecahedronVisualizer.forwardDistance)
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
                        danceabilityOverride: appModel.shazamDanceabilityOverride,
                        acousticnessOverride: appModel.shazamAcousticnessOverride,
                        aggressivenessOverride: appModel.shazamAggressivenessOverride,
                        happinessOverride: appModel.shazamHappinessOverride,
                        voiceVocalOverride: appModel.shazamVoiceVocalOverride,
                        timbreBrightnessOverride: appModel.shazamTimbreBrightnessOverride,
                        timeSigOverride: appModel.shazamTimeSigOverride,
                        partyOverride: appModel.shazamPartyOverride,
                        relaxedOverride: appModel.shazamRelaxedOverride,
                        keyOverride: appModel.shazamKeyOverride,
                        stemFeatures: appModel.stemFeatures
                    )
                    // Surface beat tracker bpm + confidence to the
                    // debug BeatBadge. Throttled inside recordBeat so
                    // it doesn't fire SwiftUI redraws every frame.
                    if !appModel.frames.isEmpty {
                        let i = max(0, min(appModel.frames.count - 1,
                            Int((appModel.playbackTime * 30).rounded())))
                        let beat = appModel.frames[i].beat
                        appModel.recordBeat(bpm: beat.bpm, confidence: beat.confidence)
                    }
                }

            case .fractal:
                let fractal = await FractalVisualizer.makeFractal(from: appModel.frames)
                content.add(fractal)
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    FractalVisualizer.animate(
                        fractal,
                        clock: appModel.playbackTime,
                        frames: appModel.frames,
                        deltaTime: event.deltaTime,
                        appResetCounter: appModel.liveModeResetCounter,
                        stemFeatures: appModel.stemFeatures
                    )
                }
            }
        }
        // Force a full RealityView remount on mode change so the new
        // scene's entity tree + animate subscription are clean. Without
        // this, switching modes from the in-viz button would leave the
        // old entities + subscription running.
        .id(appModel.mode)
        // Fill the parent. Without this, RealityView can settle at a
        // small intrinsic size on iPhone — leaving black bars around
        // the scene and the badge HStack floating in nowhere-land.
        // Combined with the parent's .ignoresSafeArea(.all), the scene
        // extends edge-to-edge including past the Dynamic Island in
        // landscape on iPhone.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        // HTML reference layers scene.fog (pale lavender-grey lifting darks)
        // then a #grain canvas (timbre-driven noise) on top of the 3D scene.
        // We do the same in SwiftUI overlay order: fog first, then grain.
        .overlay(FogOverlay())
        .overlay(GrainOverlay())
        // Empty-state nudge when no song is loaded. Without a song the
        // visualizer renders an unreactive static scene; this overlay
        // points the user at the ways to start playback. Hidden as
        // soon as any source becomes active.
        .overlay(alignment: .center) {
            if shouldShowEmptyState {
                EmptyStatePrompt()
            }
        }
        // Mode-cycle + BPM debug pill moved to the GlobalNowPlayingFooter
        // chrome — viz canvas is fully clean now, no floating
        // bottom-leading widgets.
        #if os(macOS)
        // macOS: float the same GlobalNowPlayingFooter at the bottom
        // of the viz. Replaces what used to be three separate
        // overlays — NowPlayingBadge (system-audio readout),
        // LocalPlaybackHUD (local transport), and the right-side
        // inspector for Up Next / Lyrics. Footer carries all three
        // by virtue of its source block + transport + popover
        // affordances. Less chrome, more parity with the main
        // window's footer.
        .overlay(alignment: .bottom) {
            GlobalNowPlayingFooter()
                .environment(appModel)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
        #else
        // Local-file transport HUD (play/pause/restart + next-track
        // for library mode) — visible only when a local AVAudioPlayer
        // is the active source (imported file OR library pick).
        // Positioned bottom-trailing on iOS / iPadOS / visionOS where
        // the macOS footer doesn't apply.
        .overlay(alignment: .bottomTrailing) {
            if appModel.hasLocalPlaybackSource {
                LocalPlaybackHUD()
                    .environment(appModel)
                    .padding(16)
            }
        }
        #endif
        #if os(iOS)
        // fullScreenCover on iOS has no built-in dismiss gesture
        // (unlike .sheet which has swipe-down). Provide an explicit
        // close button in the upper-right. Aligned to the top — the
        // bottom is busy with mode/badge/system-music rows.
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel("Close visualizer")
        }
        #endif
        // Ambient draggable camera. The gesture is always attached but
        // gated on `appModel.mode == .ambient` inside — other modes have
        // their own camera logic (Crystal inverse-camera, Rings auto-
        // orbit, Slipstream forward-flight) that drag would fight, so
        // we only honor drag in Ambient where the world is otherwise
        // static. visionOS users get head tracking instead; this gesture
        // is meaningful on macOS / iOS / iPadOS / tvOS only — but it's
        // also harmless on visionOS where DragGesture would fire from
        // a pinch-and-move, in which case "drag to rotate ambient"
        // is a nice bonus interaction.
        .gesture(ambientDragGesture)
        // iOS presents this view via .fullScreenCover (see
        // ContentView.showVisualizer) so we're not in a NavigationStack
        // here — no nav bar to hide. The fullScreenCover modifier in
        // ContentView already applies .ignoresSafeArea(.all) on both
        // the visualizer and its black background. Reapplying here
        // would be redundant but harmless.
        #if os(iOS)
        .ignoresSafeArea(.all)
        // Hide the iPhone home indicator after a moment of no
        // interaction (and keep the screen alive while the visualizer
        // is on). The home indicator at the bottom is otherwise a
        // bright pill over the visualizer's lower edge.
        .persistentSystemOverlays(.hidden)
        #endif
        // `.onAppear { startPlayback() }` is the legacy entry point
        // for the iOS / ContentView flow where picking a song calls
        // `loadSong` (features only) and then opening the visualizer
        // kicks audio. On macOS the queue paths already start audio
        // via `loadAndPlayLocalFast`; the re-entry guard inside
        // `startPlayback` no-ops the duplicate call here.
        //
        // **No matching `.onDisappear { stopPlayback() }`** — that
        // fired on every `.id(appModel.mode)` remount (mode-cycle),
        // releasing the live player mid-song and the next `onAppear`
        // would rebuild a fresh player from 00:00 (audible as a
        // song restart on every mode swap). Audio is now owned by
        // the queue / source layer and survives closing the
        // visualizer — matches Music.app behavior.
        .onAppear { appModel.startPlayback() }
        #if os(macOS)
        // Inspector drawer removed — replaced by the floating
        // GlobalNowPlayingFooter overlay above, which carries the
        // same Up Next + Lyrics content via its source-block
        // popover. The legacy ContentView path on iOS still uses
        // an inspector; the shell-level RootShellView + viz now
        // share the footer as the canonical surface.
        #endif
    }

    /// Free-look gesture for Ambient. Drag right → look right (yaw +);
    /// drag down → look down (pitch +). Pitch clamp widened to
    /// [-0.6, 0.9] rad (~-34° up to ~+52° down) for the lake-and-sky
    /// version — user can tilt the view fully up to see the starfield
    /// or fully down to study near-camera lake tiles, but can't flip
    /// the world upside-down. 200 px per radian: a half-screen drag
    /// spans ~1 rad (~57°), which feels right for a casual look-around.
    private var ambientDragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard appModel.mode == .ambient else { return }
                if ambientDragStart == nil {
                    ambientDragStart = (appModel.ambientDragYaw, appModel.ambientDragPitch)
                }
                let start = ambientDragStart!
                let yawDelta = Float(value.translation.width) / 200
                let pitchDelta = Float(value.translation.height) / 200
                appModel.ambientDragYaw = start.yaw + yawDelta
                let target = start.pitch + pitchDelta
                appModel.ambientDragPitch = max(-0.6, min(0.9, target))
            }
            .onEnded { _ in
                ambientDragStart = nil
            }
    }

    /// Show the "pick a song" empty-state nudge when there are no
    /// frames AND no live input source running. As soon as any source
    /// becomes active (mic / system audio / system music) we hide it
    /// — those modes start producing frames within a beat.
    private var shouldShowEmptyState: Bool {
        guard appModel.frames.isEmpty else { return false }
        if appModel.useMic { return false }
        #if os(macOS)
        if appModel.useSystemAudio { return false }
        #endif
        #if os(iOS)
        if appModel.useSystemMusic { return false }
        #endif
        return true
    }
}

/// Centered prompt shown when no song is loaded and no live input
/// source is active. Tells the user how to start playback. Sized to
/// be unobtrusive when no controls are visible (visionOS / iOS
/// full-screen modes).
private struct EmptyStatePrompt: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.6))
            Text("No song loaded")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            #if os(macOS)
            Text("Use the controls to import a file, browse your audio library, or listen to your Mac's system audio.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: 360)
            #elseif os(iOS)
            Text("Open the Music app and turn on system-music mode, or import a local file from the controls below.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: 320)
            #else
            Text("Connect a song source from the controls below.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: 320)
            #endif
        }
        .padding(28)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

/// Bottom-left pill in the visualizer: shows the current mode and
/// advances to the next on tap. Mode list = `VisualizerMode.allCases`,
/// wraps around at the end.
struct ModeCycleButton: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button {
            cycleMode()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(appModel.mode.displayName)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "arrow.right.circle.fill")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Switch to next visualizer mode")
    }

    private func cycleMode() {
        let modes = VisualizerMode.allCases
        guard let idx = modes.firstIndex(of: appModel.mode) else { return }
        let next = modes[(idx + 1) % modes.count]
        appModel.mode = next
    }
}

/// Small debug pill showing the visualizer's frame rate. Reads
/// `appModel.publishedFPS`, which is updated at ~2 Hz from each
/// visualizer's animate subscription — keeps redraw load minimal
/// while still feeling live. Style matches `ModeCycleButton` so the
/// two read as a paired set in the corner.
/// Condensed BPM pill that opens a popover with the full debug
/// readout. Replaces the row of FPS / Beat / Stems / Mic / System-
/// Music badges that used to fill the viz's bottom-left corner —
/// quieter chrome by default, full diagnostics still reachable in
/// one click.
struct BpmPillExpander: View {
    @Environment(AppModel.self) private var appModel
    @State private var expanded = false

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            Text(bpmLabel)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Tap for full debug readout")
        .popover(isPresented: $expanded, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 10) {
                FrameRateBadge().environment(appModel)
                BeatBadge().environment(appModel)
                #if os(macOS)
                StemsBadge().environment(appModel)
                #else
                TierBadge().environment(appModel)
                if appModel.useMic {
                    MicDiagBadge().environment(appModel)
                }
                #if os(iOS)
                if appModel.useSystemMusic {
                    SystemMusicBadge().environment(appModel)
                }
                #endif
                #endif
            }
            .padding(14)
        }
    }

    /// Same selection logic as BeatBadge but stripped to just the
    /// bpm number — the popover carries the full compound when the
    /// user wants details. Shazam-verified bpm gets the ✓; tracker-
    /// inferred bpm is shown plain (or "—" when confidence is
    /// below the display threshold).
    private var bpmLabel: String {
        if let override = appModel.shazamBpmOverride {
            return "\(Int(override.rounded())) bpm ✓"
        }
        let conf = appModel.publishedBeatConfidence
        if conf < 0.3 { return "— bpm" }
        let folded = BeatHelpers.octaveFoldBpm(appModel.publishedBeatBpm)
        return "\(Int(folded.rounded())) bpm"
    }
}

struct FrameRateBadge: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Text("\(Int(appModel.publishedFPS.rounded())) fps")
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .help("Render frame rate — debug")
    }
}

/// Debug pill showing the beat tracker's current bpm + confidence.
/// Surfaces what `FeatureFrame.beat.bpm` and `.confidence` actually
/// look like at runtime — used to verify tempo-driven visualizer
/// behavior (e.g. dodecahedron's slow/fast intensity scaling) actually
/// has a valid tempo to react to. Shows "—" when confidence is below
/// the visualizer's confidence floor (~0.3) since the bpm is too noisy
/// to trust at that point.
struct BeatBadge: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let conf = appModel.publishedBeatConfidence
        let label: String = {
            // Shazam-verified override takes precedence — show it
            // distinctly so we can see in the UI when the visualizer
            // is on locked-canonical-bpm vs falling back to the
            // tracker. Includes danceability + key when available.
            if let override = appModel.shazamBpmOverride {
                var parts: [String] = ["\(Int(override.rounded())) bpm"]
                if let dance = appModel.shazamDanceabilityOverride {
                    parts.append("D\(Int(dance.rounded()))")
                }
                if let acoust = appModel.shazamAcousticnessOverride {
                    parts.append("A\(Int(acoust.rounded()))")
                }
                if let aggro = appModel.shazamAggressivenessOverride {
                    parts.append("X\(Int(aggro.rounded()))")
                }
                if let happy = appModel.shazamHappinessOverride {
                    parts.append("H\(Int(happy.rounded()))")
                }
                if let voc = appModel.shazamVoiceVocalOverride {
                    // 'V' for vocal, 'I' for instrumental (visual mnemonic)
                    parts.append(voc >= 50 ? "V\(Int(voc.rounded()))" : "I\(Int((100-voc).rounded()))")
                }
                if let brt = appModel.shazamTimbreBrightnessOverride {
                    parts.append("T\(Int(brt.rounded()))")
                }
                if let party = appModel.shazamPartyOverride {
                    parts.append("P\(Int(party.rounded()))")
                }
                if let relax = appModel.shazamRelaxedOverride {
                    parts.append("R\(Int(relax.rounded()))")
                }
                if let ts = appModel.shazamTimeSigOverride {
                    parts.append(ts)
                }
                if let key = appModel.shazamKeyOverride {
                    // Compact key notation: "Em" / "C" / "F#m"
                    let modeSuffix = key.mode == .minor ? "m" : ""
                    parts.append("\(key.tonic.name)\(modeSuffix)")
                }
                return parts.joined(separator: " · ") + " ✓"
            }
            if conf < 0.3 {
                return "— bpm"
            }
            let raw = appModel.publishedBeatBpm
            let folded = BeatHelpers.octaveFoldBpm(raw)
            // Show folded bpm with raw in parens when they differ
            // (so half/double-time tracker locks are visible).
            if abs(folded - raw) < 1.0 {
                return "\(Int(raw.rounded())) bpm · \(Int((conf * 100).rounded()))%"
            }
            return "\(Int(folded.rounded()))←\(Int(raw.rounded())) bpm · \(Int((conf * 100).rounded()))%"
        }()
        Text(label)
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            // Single-line + tail-truncate. With many override axes
            // populated (D, A, X, H, V, T, P, R, etc.) the compound
            // can hit ~250pt natural width and otherwise wraps to
            // many vertical lines when the parent HStack runs out
            // of horizontal room on iPhone landscape.
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .help("Beat tracker bpm + confidence — debug")
    }
}

/// Provenance + state of the stem-separation pipeline for the
/// currently-playing song. Four states:
///   • idle      → "stems —"        (dim grey)   no stems, band-split
///   • computing → "stems …"        (yellow-ish) separation in flight
///   • cached    → "stems ✓ cached" (green)      instant cache hit
///   • fresh     → "stems ⟳ fresh"  (blue)       just computed this session
///
/// Reads the small observable `stemStatus` enum — NOT the giant
/// `stemFeatures` struct — so this view re-renders cheaply on
/// status transitions only.
/// Shows which fidelity tier the visualizer is currently reading from.
/// Used on iOS / iPadOS / visionOS in place of the StemsBadge (which
/// is macOS-relevant since stem separation only runs locally there).
/// Tier 3 = preview-extrapolated frames; Tier 2 = preview + AB beats;
/// Tier 1 = full real audio analysis; none = no frames loaded yet.
struct TierBadge: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let (label, color, help): (String, Color, String) = {
            switch appModel.currentFrameTier {
            case .none:
                return ("tier —", .secondary,
                        "No frames loaded yet.")
            case .tier3:
                return ("tier 3", .yellow,
                        "Preview-extrapolated frames. Beat grid is BPM-extrapolated from the 30s preview; chord progression loops the preview.")
            case .tier2:
                return ("tier 2", .blue,
                        "Preview chromagram + AcousticBrainz full-song beat positions. Beat-accurate; chord progression scripted.")
            case .tier1:
                return ("tier 1 ✓", .green,
                        "Full real-audio analysis (live tap or cached frames). Every onset and chromagram value is ground truth.")
            }
        }()
        Text(label)
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .help(help)
    }
}

struct StemsBadge: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let (label, color, help): (String, Color, String) = {
            switch appModel.stemStatus {
            case .idle:
                return ("stems —", .secondary,
                        "No stems for this song — visualizer is on band-split fallback.")
            case .computing(.none):
                return ("stems …", .yellow,
                        "Separation in flight — visualizer is on band-split until stems land.")
            case .computing(.some(let fraction)):
                let pct = Int((fraction * 100).rounded())
                return ("stems \(pct)%", .yellow,
                        "Throttled separation — \(pct)% complete. Audio + visualizer stay smooth while the sidecar yields between chunks.")
            case .ready(fromCache: true):
                return ("stems ✓ cached", .green,
                        "Stems loaded instantly from local cache. Disco ball is drum-isolated.")
            case .ready(fromCache: false):
                return ("stems ⟳ fresh", .blue,
                        "Stems just computed this session. Disco ball is drum-isolated.")
            }
        }()
        Text(label)
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .help(help)
    }
}

#if !os(macOS)
/// iOS / iPadOS / visionOS diagnostic pill — surfaces MicListener's
/// session config + streaming-analyzer frame emit count on-screen.
/// Visible only while `appModel.useMic == true`. Lets us debug the
/// mic pipeline without Console.app: if `frames=0` after audible
/// audio is playing → StreamingAnalyzer isn't seeing input → audio
/// session or format issue. If `frames` ticks up → pipeline is
/// healthy and any visualizer issues are downstream.
struct MicDiagBadge: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let session = appModel.micListener.publishedSessionInfo
        let frames = appModel.micListener.publishedFramesEmitted
        let loudness = appModel.micListener.smoothedLoudness
        let tapCalls = appModel.micListener.publishedTapCalls
        let peak = appModel.micListener.publishedTapPeak
        // Compact 2-line label so we can fit everything on iPhone.
        // Top line: session config (cat/mode/sr)
        // Bottom line: pipeline diagnostics (tap calls, peak, frames, loudness)
        let label = "🎙 \(session)\ntaps=\(tapCalls) pk=\(String(format: "%.3f", peak)) f=\(frames) L=\(String(format: "%.2f", loudness))"
        Text(label)
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.orange)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
#endif

#if os(iOS)
/// iOS-only badge for the system-music-follow mode. Shows what Music.app
/// reports playing + the live playhead in seconds, plus prev/play-pause/
/// next transport controls. Companion to MicDiagBadge for the other
/// (mic-based) iOS audio path. Mirrors the macOS NowPlayingBadge's
/// transport row.
struct SystemMusicBadge: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let title = appModel.systemMusic.title
        let artist = appModel.systemMusic.artist
        let pos = appModel.systemMusic.currentPlaybackTime
        let isPlaying = appModel.systemMusic.isPlaying
        VStack(alignment: .leading, spacing: 4) {
            Text(titleLabel(title: title, artist: artist, isPlaying: isPlaying, pos: pos))
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(isPlaying ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            transportRow(isPlaying: isPlaying, hasTrack: !title.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        // Tighter cap so we don't dominate the badge HStack on iPhone
        // landscape. Title truncates aggressively; transport row is
        // compact icons.
        .frame(maxWidth: 200, alignment: .leading)
    }

    private func titleLabel(title: String, artist: String,
                            isPlaying: Bool, pos: Double) -> String {
        guard !title.isEmpty else { return "♫ —" }
        let icon = isPlaying ? "▶" : "❚❚"
        let posStr = String(format: "%d:%02d", Int(pos) / 60, Int(pos) % 60)
        // Drop the artist on iPhone — the title alone is what the user
        // needs to confirm the sync. Title truncates inside the parent
        // Text via .lineLimit(1)/.truncationMode(.tail).
        return "\(icon) \(title)  \(posStr)"
    }

    private func transportRow(isPlaying: Bool, hasTrack: Bool) -> some View {
        HStack(spacing: 14) {
            Button {
                appModel.systemMusic.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
            }
            .disabled(!hasTrack)

            Button {
                appModel.systemMusic.togglePlayPause()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(!hasTrack)

            Button {
                appModel.systemMusic.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(!hasTrack)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(hasTrack ? .primary : .secondary)
    }
}
#endif

#if os(macOS)
/// Small in-corner readout: which process is being tapped + what's
/// playing + (when AM is playing in-app) transport controls so the user
/// can prev/restart/play-pause/next without leaving the visualizer.
/// Hidden when not in live system-audio mode.
private struct NowPlayingBadge: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if appModel.useSystemAudio {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    // Opens the full Now-Playing inspector. The badge
                    // hides while the inspector is up (see
                    // VisualizerView's bottom-trailing overlay), so
                    // this button only ever needs the "open"
                    // affordance. Left-aligned so it pairs visually
                    // with the source label that follows it.
                    Button {
                        appModel.showNowPlayingInspector = true
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open Now Playing panel")
                    .accessibilityLabel("Open Now Playing panel")

                    if let source = appModel.systemAudio.tappedProcessName {
                        sourceLabel(for: source)
                    }
                }
                Text(nowPlayingLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Show transport controls when we can drive *something*:
                //   • in-app AM playback via ApplicationMusicPlayer, OR
                //   • Music.app system-audio-tap mode via SystemMusicPlayer
                //     (public MusicKit API — drives Music.app's own
                //     transport, the visualizer resets cleanly on each
                //     next/prev via `bumpLiveResetForTrackChange`).
                // For Spotify / browser sources we can't drive playback —
                // skip the controls to avoid misleading buttons.
                if appModel.isControllingSystemMusic
                    || appModel.musicKit.isPlaying
                    || appModel.musicKit.nowPlaying != nil
                {
                    transportControls
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 320, alignment: .trailing)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 14) {
            Button {
                Task { await appModel.playerSkipToPrevious() }
            } label: {
                Image(systemName: "backward.fill")
            }
            .help("Previous song")

            Button {
                appModel.playerRestart()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help("Restart this song")

            Button {
                Task { await appModel.playerTogglePlayPause() }
            } label: {
                Image(systemName: appModel.isPlayingForUI
                      ? "pause.fill" : "play.fill")
            }
            .help(appModel.isPlayingForUI ? "Pause" : "Play")

            Button {
                Task { await appModel.playerSkipToNext() }
            } label: {
                Image(systemName: "forward.fill")
            }
            .help("Next song")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.top, 2)
    }

    private var nowPlayingLabel: String {
        // When we control AM playback in-app, prefer the live nowPlaying
        // song over the Shazam-identified title — the AM metadata is
        // authoritative for what's actually playing right now and
        // updates instantly on next/prev (Shazam takes ~10s to catch up).
        if let np = appModel.musicKit.nowPlaying {
            return "\(np.title) — \(np.artistName)"
        }
        switch appModel.shazam.status {
        case .matched(let title, let artist):
            return "\(title) — \(artist)"
        case .listening:
            return "Identifying…"
        case .failed(let msg):
            return msg
        case .idle:
            return ""
        }
    }

    /// Friendly source label for the tap-process row. Special-cases
    /// `RemotePlayerService` — the macOS helper process Apple Music
    /// uses to render audio — to the Apple-logo + "Music" treatment
    /// so the badge matches the user's mental model. Other sources
    /// keep the speaker glyph + raw process name (Spotify renders as
    /// "Spotify", Safari as "Safari", etc.).
    @ViewBuilder
    private func sourceLabel(for raw: String) -> some View {
        if raw == "RemotePlayerService" {
            Label {
                Text("Music")
            } icon: {
                Image(systemName: "applelogo")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            Label(raw, systemImage: "speaker.wave.2.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

#endif
