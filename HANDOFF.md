---
name: HANDOFF-render-crash-and-ram
description: "Session handoff 2026-05-31: render-thread crash (NOT fixed, recurs) + RAM bloat (mostly fixed, footprint still reducible). Where to resume, exact files/lines, and how to verify. Start a FRESH session for the render-crash refactor — this session's tool channel was corrupting output by the end."
metadata:
  node_type: handoff
  type: handoff
  status: open
  originSessionId: 2026-05-31-memory-crash
---

# HANDOFF — render crash + RAM bloat

Read [[memory-leak-and-render-crash-fixes]] alongside this — it has the
full per-fix detail. This file is the "what to do next" summary.

## Git state at handoff
4 commits landed on `main`, local HEAD `faee53c`, working tree CLEAN.
Pushed to origin (github.com/telegram54m/avp-visualizer) — clean
fast-forward from `9b9e8a5`, ahead 4 / behind 0 at push time.

Commits (newest first):
- faee53c feat(swift-backend): in-process Swift stem backend + probes
- 4f2bc0b fix(memory): cached artwork, all-songs retention, render-thread hygiene
- a09a0f3 feat(stem-cache): ISRC-canonical cache identity (Shazam dup fix)
- c978e09 chore(gitignore): ignore model weights / parity traces / pyc

⚠️ The session tool channel was garbling command output near the end
(cancelled batches, contradictory file contents). RE-VERIFY git state
with fresh clean reads before building on this. The 4 commits above were
confirmed with clean reads at the time; the push-readiness numbers were
NOT trustworthy.

---

# WORKSTREAM 1 — Render-thread crash (Crystal refactor LANDED, awaiting soak)

## Status update 2026-05-31 (fresh session)
**Crystal recycle-pool refactor IMPLEMENTED + builds clean + SOAK-CONFIRMED.**
User soaked live Crystal for ~1 HOUR (pool wrapped many times over) — NO
crash, no new .ips. Crystal render-crash considered FIXED.
Original implementation notes:
- `makeCrystalLive` now pre-allocates the full fixed pool of
  `liveModeShardCap` (300) shardGroups via `buildEmptyShardGroup`, all
  inactive (scale .zero, `ShardComponent.active = false`).
- `scanForNewOnsets` reconfigures slot `liveShardCount % cap` in place via
  the new `configure(...)` — ZERO add/removeFromParent after scene build.
- Track-change reset deactivates slots in place (no child removal).
- `ShardComponent` gained `active: Bool` (default true → preview path
  unaffected); `CrystalVisualizer.animate` skips inactive slots so they
  neither render nor capture the camera.
- `spawnShardGroup` is now `buildEmptyShardGroup` + `configure` (preview
  path identical behavior). All per-frame logic lives once in `configure`.
- grep confirms no `removeFromParent` calls remain in CrystalVisualizer*
  (only comments). macOS build SUCCEEDED.
**NEXT: user soaks live system-audio Crystal >5 min so the pool wraps
(300+ onsets) + mode-cycles + viz open/close. Watch for stale-visual
bleed on recycled slots and the reused-slot pop. If clean → Slipstream.**

## Slipstream recycle-pool refactor — IMPLEMENTED + builds clean + SOAK-CONFIRMED
User soaked live Slipstream ~10 min (mode-cycle, viz open/close) — NO
crash, no new .ips, no visual bleed. Slipstream live render-crash FIXED.
Implementation notes:
Same fix applied to SlipstreamVisualizer.swift, scoped to the LIVE path:
- New `isLivePool` flag on `SlipstreamRootComponent`; `active` flag on
  `SlipstreamGateComponent`.
- `makeSlipstreamLive` pre-allocates the fixed pool of `liveModeGateCap`
  (80) gates via `buildEmptyGate` (each with `maxNestedRings`=3 ring
  children, all `isEnabled=false`). Fog + vocal glow untouched (no gate
  component → skipped by gate scans).
- `scanForNewOnsets` reconfigures slot `liveGateCount % cap` via
  `configureGate`/`configureRing` (rebuilds material + MeshInstances as
  component updates — safe); old count-cap removeFromParent loop deleted.
- `animate` Z-eviction + track-reset DEACTIVATE slots in place (isEnabled
  false + active false) when `isLivePool`; PREVIEW keeps removeFromParent.
- `animate` gate loop skips `!gc.active` slots.
- `makeRingEntity` split into `buildEmptyRing` + `configureRing`.
- grep confirms the only two remaining `removeFromParent` calls are the
  preview-only `else` branches (live `toEvict` stays empty). macOS build
  SUCCEEDED.
**NEXT: user soaks live system-audio SLIPSTREAM the same way (>5–10 min,
mode-cycle, viz open/close). Watch for: gate visuals bleeding across a
recycled slot (ring count/particle density/hue from prior occupant), a
slot popping back to the frontier visibly, or fog/vocal-glow loss on
track change.**

## KNOWN FOLLOW-UP (not the reported crash): Slipstream PREVIEW path
Preview (`makeSlipstream`, local-file / fully-analyzed) still removes
gates per-tick in `animate` (the `else` branches) — a latent version of
the same race, but NOT the observed live-mode crash. `makeSlipstream`
also pre-builds one gate PER ONSET for the whole song (could be 1000s),
so it can't trivially reuse the 80-slot pool. If the preview race ever
surfaces, the fix is a pooled preview path with frame-seeded recycling.
Left as-is for now to keep preview behaviour byte-identical.

## Original diagnosis (below) — applied to both modes
## Status: render-crash root cause (live path of both modes now fixed)
Two crash reports, identical signature, second one on a build that
already had this session's mitigation:
- `2026-05-30-150107.ips` (PID 11081)
- `2026-05-30-163956.ips` (PID 18443 — HAD the weak-capture + teardown fix)

Both: `EXC_BAD_ACCESS / SIGSEGV`, PAC failure, backtrace
`objc_msgSend → re::encodeDrawCalls → ... → re::RenderThread` (the
DRAW path, on a CoreRE render thread, main thread idle). Use-after-free:
the renderer drew a freed entity.

## Root cause (high confidence)
Live visualizers structurally mutate the scene graph EVERY audio tick —
`root.children.first?.removeFromParent()` etc. — from inside the
`SceneEvents.Update` closure, while RealityKit's render thread
concurrently draws that same graph. The per-tick remove races the draw.
**Corroboration: Clouds is the ONLY live mode that never calls
removeFromParent in its loop (it toggles `sprite.isEnabled` on a fixed
sprite set) and Clouds is implicated in NEITHER crash.**

## What was already shipped (committed, INSUFFICIENT — keep, don't revert)
- VisualizerView.swift: all 7 update closures `[weak root]` + guard.
- RootShellView.swift: `.onChange(of: showVisualizer)` nils
  sceneUpdateSubscription + debugSceneRoot on overlay close.
These are correct hygiene but DON'T stop the per-tick-remove-vs-draw race.

## The fix the user chose: recycle-pool refactor (Clouds pattern)
Convert Crystal + Slipstream from spawn/removeFromParent to a FIXED
pre-allocated entity pool; recycle by repositioning/reconfiguring the
oldest slot instead of removing it. Then NO structural mutation ever
happens after scene build → nothing for the renderer to race.

### removeFromParent sites to eliminate
- CrystalVisualizerV2.swift:388 (track-change reset, scanForNewOnsets)
- CrystalVisualizerV2.swift:425 (per-onset cap evict)
- SlipstreamVisualizer.swift:595 (reset), :667 (cap evict), :819 (Z-evict in animate), :1172
- (Rings:285/380 = removeAll on a struct array, NOT entities — leave.
   Architecture = CUT mode, ignore.)

### Crystal design (do Crystal FIRST, soak-test, THEN Slipstream)
Today: `makeCrystalLive` (CrystalVisualizerV2.swift:343) returns empty
root + `CrystalLiveStateComponent {lastSeenFrameIndex, liveShardCount,
lastSeenResetCounter}` (struct at :164). `scanForNewOnsets` (:371,
@MainActor) walks new frames, per onset calls `spawnShardGroup` (:450 —
builds a shardGroup Entity w/ 3 children: shard/halo/core, each an
OpacityComponent, scale=.zero until animate fades in) + addChild, then
evicts oldest over cap (liveModeShardCap=300, :440).
`CrystalVisualizer.animate` (the v1 file, shared) iterates root.children,
reads ShardComponent, drives opacity/wobble/scale per frame.

Refactor:
1. `makeCrystalLive`: pre-build all 300 shardGroups via spawnShardGroup
   (placeholder frame, scale=.zero), addChild all once. Pool = the fixed
   set of root.children.
2. Split `spawnShardGroup` into `buildEmptyShardGroup()` (entity/mesh
   skeleton, once) + `configure(_ group:, frame:, elevationFraction:,
   index:)` (resets ShardComponent + per-child material colors + dims +
   wobble + opacity floor).
3. `scanForNewOnsets`: per new onset, slot = `liveShardCount % cap`,
   call `configure()` on that EXISTING child. NO add/remove. Bump
   liveShardCount. Wrap = oldest slot silently replaced.
4. Track-change reset: don't remove children — reset each slot to
   scale=.zero/opacity 0, liveShardCount=0, lastSeenFrameIndex=frames.count.
5. animate side: verify it tolerates a ShardComponent whose onsetTime
   jumped backward (reused slot). It computes age = clock - onsetTime
   each frame so should be fine — but soak-check the reused-slot pop.

RISK: `configure()` must FULLY reset a slot's visual state or stale
visuals bleed from the prior occupant. Test by soaking live system-audio
mode >5 min so the pool wraps (300+ onsets).

### Slipstream (AFTER Crystal confirmed)
Same idea, but gates flow on Z and currently evict when past camera.
Fixed pool of liveModeGateCap gates, recycle by Z-reset. Fog sphere is
child[0] and MUST be preserved (the :667 loop already special-cases it).
More state per gate (odometer/position) → do as a separate pass.

### Build / run / verify
```
xcodebuild -project "High Videlity/High Videlity.xcodeproj" \
  -scheme "High Videlity" -destination "platform=macOS" build
APP=~/Library/Developer/Xcode/DerivedData/High_Videlity-emghceuyvjrcgyepqwamcmkoqrjk/Build/Products/Debug/"High Videlity.app"
open "$APP"
```
Crash reports: `ls -t ~/Library/Logs/DiagnosticReports/*Videlity*.ips`
Parse: file is 2 JSON objects (header line + body); read body, get
`faultingThread`, map frame imageIndex → usedImages[].name.
**CANNOT be unit-verified — needs USER soak-testing** (live audio,
mode-cycling, viz open/close) over several minutes. Do NOT declare fixed
on "didn't crash once." (This session mis-called it fixed once already.)

---

# WORKSTREAM 2 — RAM bloat (mostly fixed; footprint still reducible)

## What's fixed + committed
- **Artwork leak (the 5GB→OOM climb):** ArtworkView now uses a
  process-wide NSCache (48MB + 400-item caps, true CGImage pixel-byte
  cost). Was the unbounded ~126MB Image-IO growth re-decoding per nav.
- **All-songs triple-retention:** SortableSong no longer embeds the full
  Song. "Show all" 11k: 1.4GB → +296MB.
- Net: RAM now plateaus + recovers instead of climbing unbounded. User-
  confirmed "Show all" jump dropped to ~296MB.

## Measurement ground-truth (from vmmap on live PID, the real numbers)
The `ps` RSS poller's big number is misleading. **Physical footprint was
~1.3–1.5GB**, of which:
- IOSurface/GPU ~600MB but **~400MB VOLATILE/purgeable** — system
  reclaims under pressure (why RAM drops on viz close). Not a real risk.
- MALLOC_SMALL heap 170–640MB, 2.6M allocations — MusicKit objects +
  frames + app data. The real heap.
- Image-IO ~126MB (the artwork leak, now fixed).
- The other ~1.6GB of the ps number is shared file-backed framework
  memory (SFSymbols Assets.car 152MB, fonts, dylibs) — not "ours."

## Remaining footprint reducers (none cause a crash; do if it matters)
Ranked by likely payoff:
1. ~~**Per-view MusicKit @State arrays** ("cause A2")~~ **DONE 2026-05-31
   for AppleMusicHomeView.** New `AppleMusicStore` (@MainActor @Observable,
   macOS-only + stub) holds the feed (recommendations/charts) + full
   paginated library (songs/albums/artists/playlists) + loaded/loading
   flags. Held as `let appleMusic = AppleMusicStore()` on AppModel
   (mirrors `let library = LibraryStore()`). AppleMusicHomeView's @State
   removed; it now reads `store.X` and its loadFeed/loadLibrary delegate
   to the store (idempotent). Data survives navigation → single retained
   copy, no re-fetch on return to the landing page. Build green.
   FOLLOW-UP (small, deferred): `AppleMusicLibraryView` (legacy `.sheet`
   in ContentView, capped `librarySongs(limit:100)` fetches, freed on
   dismiss) still has its own @State — smaller + short-lived, left as-is.
   It may also be dead UI (ContentView is the old shell; RootShellView is
   current). Could migrate or delete later.
2. **frames: [FeatureFrame] uncapped in live/mic mode** (latent leak).
   `appendLiveFrames`, AppModel.swift:1167 — appends 30/s forever, no
   eviction; track-change wipe is throttled 60s + suppressed same-song.
   Only bites very long mic/tap sessions. Fix: ring-buffer cap (~10–20k
   frames) with index rebasing (visualizers index by playbackTime*30;
   live clock uses frames.count-1, so a trim needs the same rebasing the
   withTime path already does).
3. **Stem separation during AM playback** — decodes audio per song;
   verify StemSeparationResult isn't retained across songs (single
   optional slot today, looked OK but unverified under rapid skip).
4. **Fractal LowLevelTexture per-remount** — flagged secondary; each
   mode remount builds a fresh LLT+TextureResource. Heavy mode-cycling
   could accrue GPU textures. Lower priority.

## How to actually measure (don't guess)
Best: wire HV-DIAG `startDiagLogging()` to run at app LAUNCH (today it
only starts in tap/mic mode — AppModel.swift:868 & :1036), so the
resident-MB + frames + entity-count slope logs in ALL modes. Then repro
and read `log show --predicate 'subsystem == "com.jessegriffith.HighVidelity"' --last 15m | grep HV-DIAG`.
Or `vmmap <pid>` category summary during repro to see WHICH category
grows (the ps poller only gives total RSS). External poller template is
in [[memory-leak-and-render-crash-fixes]].

---

# ALSO PENDING (from earlier this session, not regressions)
- **Existing 14 Jahya dup cache rows** still on disk (cleanup code shipped
  but not run). User chose to clean via the in-app Stem Cache Audit sheet:
  relaunch (needs new build w/ redundant-dup detection) → redundant dupes
  pre-checked → optionally enable "purge from shared cloud" → Remove.
  See [[shazam-cache-key-duplicates]] (status: fixed) for detail.
- **CloudKit global backfill** of OTHER users' shazam-keyed dup records
  not possible from code (public DB has no enumerate API w/o a Dashboard
  QUERYABLE index). Documented in [[shazam-cache-key-duplicates]].
- **iOS target build fails** on MLX iOS-17 platform floor (pre-existing,
  unrelated to this work; matters for the STEM_USE_SWIFT cutover).

# Recommended next-session order
1. Push the 4 commits (verify git state with clean reads first).
2. Crystal recycle-pool refactor → build → USER soak-test → confirm no
   crash → then Slipstream.
3. (Optional) AM @State → shared store hoist for footprint.
