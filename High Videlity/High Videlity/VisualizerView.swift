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
                let crystal: Entity
                if isLive && appModel.useCrystalV2 {
                    crystal = await CrystalVisualizerV2.makeCrystalLive(
                        startingFrameIndex: liveStartIndex,
                        startingResetCounter: liveStartResetCounter
                    )
                } else if appModel.useCrystalV2 {
                    crystal = await CrystalVisualizerV2.makeCrystal(from: appModel.frames)
                } else {
                    // v1 has no live-mode path; fall back to preview build.
                    crystal = await CrystalVisualizer.makeCrystal(from: appModel.frames)
                }
                crystal.position = .zero
                content.add(crystal)
                appModel.debugSceneRoot = crystal
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    if isLive && appModel.useCrystalV2 {
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
                        appResetCounter: appModel.liveModeResetCounter
                    )
                }

            case .slipstream:
                let slipstream: Entity = isLive
                    ? SlipstreamVisualizer.makeSlipstreamLive(
                        startingFrameIndex: liveStartIndex,
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
                    if isLive {
                        SlipstreamVisualizer.scanForNewOnsets(
                            slipstream,
                            frames: appModel.frames,
                            appResetCounter: appModel.liveModeResetCounter
                        )
                    }
                    SlipstreamVisualizer.animate(
                        slipstream,
                        clock: appModel.playbackTime,
                        frames: appModel.frames,
                        deltaTime: event.deltaTime,
                        appResetCounter: appModel.liveModeResetCounter
                    )
                }

            case .architecture:
                let arch: Entity = isLive
                    ? ArchitectureVisualizer.makeArchitectureLive(
                        startingFrameIndex: liveStartIndex,
                        startingResetCounter: liveStartResetCounter
                      )
                    : await ArchitectureVisualizer.makeArchitecture(from: appModel.frames)
                // Same windowed-eye-height adjustment as Clouds and Rings —
                // the immersive eye frame puts the cluster at y=1.3, but the
                // windowed virtual camera is at origin, so center vertically.
                // -2.5 instead of the immersive default -3.0 — the
                // constellation is now ~5.4m wide (radial 0..2.7 + ring
                // 0.93), so at -2.5 it fills the windowed viewport
                // comfortably without clipping at the edges.
                arch.position = SIMD3<Float>(0, 0, -2.5)
                content.add(arch)
                appModel.debugSceneRoot = arch
                appModel.sceneUpdateSubscription = content.subscribe(
                    to: SceneEvents.Update.self
                ) { event in
                    appModel.recordFrameDelta(event.deltaTime)
                    if isLive {
                        ArchitectureVisualizer.scanForNewOnsets(
                            arch,
                            frames: appModel.frames,
                            appResetCounter: appModel.liveModeResetCounter
                        )
                    }
                    ArchitectureVisualizer.animate(
                        arch,
                        clock: appModel.playbackTime,
                        energy: appModel.currentEnergy(),
                        deltaTime: event.deltaTime
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
                        appResetCounter: appModel.liveModeResetCounter
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
                        keyOverride: appModel.shazamKeyOverride
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
            }
        }
        // Force a full RealityView remount on mode change so the new
        // scene's entity tree + animate subscription are clean. Without
        // this, switching modes from the in-viz button would leave the
        // old entities + subscription running.
        .id(appModel.mode)
        .background(Color.black)
        // HTML reference layers scene.fog (pale lavender-grey lifting darks)
        // then a #grain canvas (timbre-driven noise) on top of the 3D scene.
        // We do the same in SwiftUI overlay order: fog first, then grain.
        .overlay(FogOverlay())
        .overlay(GrainOverlay())
        // Mode-cycle button in the lower-left so the user can switch
        // visualizers without navigating back to ContentView. Placed
        // outside the macOS-only block since mode-switching is useful
        // on every platform. FPS badge sits next to it as a small
        // debug aid — useful when tuning per-mode entity counts.
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 8) {
                ModeCycleButton()
                    .environment(appModel)
                FrameRateBadge()
                    .environment(appModel)
                BeatBadge()
                    .environment(appModel)
            }
            .padding(16)
        }
        #if os(macOS)
        // Small "now playing" badge in the lower-right — only when system
        // audio is the source. Shows which app we're tapping + the Shazam-
        // identified song so the user always has context for what the
        // cluster is reacting to.
        .overlay(alignment: .bottomTrailing) {
            NowPlayingBadge()
                .environment(appModel)
                .padding(16)
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
        .onAppear { appModel.startPlayback() }
        .onDisappear { appModel.stopPlayback() }
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
}

/// Bottom-left pill in the visualizer: shows the current mode and
/// advances to the next on tap. Mode list = `VisualizerMode.allCases`,
/// wraps around at the end.
private struct ModeCycleButton: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button {
            cycleMode()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(appModel.mode.displayName)
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
            let folded = DodecahedronVisualizer.octaveFoldBpm(raw)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .help("Beat tracker bpm + confidence — debug")
    }
}

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
                if let source = appModel.systemAudio.tappedProcessName {
                    Label(source, systemImage: "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
}
#endif

#endif
