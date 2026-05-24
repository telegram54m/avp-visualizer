# AVP Visualizer

An Apple Vision Pro music visualizer that turns the audio you're already
listening to into spatial, reactive 3D visualizations. Works across
visionOS / iOS / iPadOS / macOS / tvOS — passive immersive experience
first, no controls to fiddle with.

**Status:** personal work-in-progress. Built around a Swift package
(`AudioAnalysis/`) that does the DSP — FFT, chromagram, key detection,
onset detection, beat tracking, multi-band split — and a RealityKit app
(`High Videlity/`) that renders the visualizations. macOS taps system
audio output via Core Audio Process Tap, so it reacts to whatever's
playing through your Mac (Apple Music, Spotify, browser audio).

## Visualizer modes

- **Crystal** — onset-driven shards radiating outward, additive beams
- **Clouds** — atmospheric haze + HDR sprite bloom
- **Rings** — concentric glow-particle rings, beat-locked
- **Architecture** — accumulating 3D torus-ring constellation
- **Slipstream** — forward-flight corridor; time becomes a spatial axis
- **Ambient** — calm-cosmic water + procedural caustics + nebula sky
- **Dodecahedron** — 12 pentagonal faces = 12 pitch classes; metallic
  plates with per-face emissive beams; tempo-aware intensity scaling

## Attribution

Tempo data is enriched via [GetSongBPM](https://getsongbpm.com) — when
Shazam identifies a track, the canonical BPM is looked up to sidestep
the half/double-time interpretations that any onset-based local beat
tracker occasionally locks onto. Thanks to GetSongBPM for making this
data accessible.
