# Stereo NDI Preview for iPad — PRD

**Status:** Draft v1
**Owner:** Matt Celia (LightSailVR)
**Date:** 2026-05-01
**Bundle ID:** `com.lsvr.stereondi`

---

## Problem Statement

Stereoscopic camera shoots require continuous, hands-on alignment of the two camera eyes — convergence and horizontal image translation (HIT) must be tuned in real time as the rig is set up, repositioned, and adjusted between takes. Today this work happens with a mix of bulky monitors, laptop-bound NDI tools, and "trust me, it looks fine" eyeballing. None of those workflows survive a moving production:

- The on-set stereographer needs an alignment surface they can hold in their hands while standing next to the rig, not a monitor on a cart.
- Creatives (directors, DPs, producers) want to see the actual stereoscopic 3D result on a Meta Quest in another room — but only after the alignment operator has confirmed the eyes line up. Today there's no portable preview path that produces both an alignment view (anaglyph) and a Quest-ready feed (full-bandwidth side-by-side) from the same two NDI sources.
- Set networks are unstable. WiFi flaps as camera carts move. Sources come and go. Existing NDI tools don't degrade gracefully — they black out, drop sessions, and force the operator to repick sources mid-take.

There is no off-the-shelf iPad tool that takes two NDI inputs, produces a stereoscopic composite for both an in-hand alignment screen and a downstream Quest viewer, exposes precise HIT/convergence controls, and survives a real shoot day.

## Solution

A single-purpose iPad app — built for iPad Pro M-series, latest iPadOS, dark mode, landscape-locked, distributed via TestFlight — that:

1. Receives two NDI sources from any NDI-aware camera or capture device on the local network (full-bandwidth or HX/HX2).
2. Composites them through a Metal pipeline into a stereoscopic frame, with two independent output paths sharing all upstream stages:
   - **iPad screen:** operator-selectable between side-by-side, luma red/cyan anaglyph, and a channel-test pattern. Used for alignment.
   - **NDI output:** always full-bandwidth side-by-side, BT.709 limited UYVY 4:2:2. Consumed by the Quest in another room (and any other NDI receiver).
3. Provides precise convergence and per-eye HIT controls — slider plus two-finger-drag-on-preview, sub-pixel, ±400 px range — with a crop toggle so the operator can choose between a clean cropped image and seeing exactly what's being shifted.
4. Discovers NDI sources via mDNS, falls back to manual URL entry, remembers favorites, and silently reconnects to the last pair on launch and after WiFi drops.
5. Survives the failure modes of a real production network: source disappearance, framerate/resolution mismatches, interlaced sources, partial-source connection, and thermal throttling.

The result is a tool the alignment operator carries in two hands while walking around the rig, and a 3D preview the creatives watch on a Quest, both fed from the same two NDI cameras with a single iPad in the middle.

## User Stories

### Alignment operator (primary user — the stereographer holding the iPad)

1. As an alignment operator, I want to launch the app and have it auto-reconnect to my last source pair, so that I don't pick sources every time I relaunch mid-shoot.
2. As an alignment operator, I want to pick my two NDI sources from a live discovery list, so that I can connect to whichever cameras are streaming on the network without typing.
3. As an alignment operator, I want to enter a source URL manually when discovery doesn't find it, so that I'm not blocked by mDNS failures on a studio network.
4. As an alignment operator, I want to save my current source pair as a named favorite, so that I can one-tap reconnect to a known rig on the next shoot day.
5. As an alignment operator, I want to swap left and right with a single button, so that I can correct a mislabeled rig without reopening pickers.
6. As an alignment operator, I want a single Convergence slider that shifts both eyes oppositely, so that I can do the most common alignment operation with one control.
7. As an alignment operator, I want per-eye fine HIT sliders behind a disclosure, so that I can correct asymmetric lens offsets without cluttering the main UI.
8. As an alignment operator, I want HIT measured in source pixels with sub-pixel precision, so that the values are repeatable, communicable, and align with how alignment plugins in DaVinci/Nuke quote their math.
9. As an alignment operator, I want a ±400 px range, so that hyper-stereo rigs with wide interaxials are still alignable.
10. As an alignment operator, I want to drag two fingers across the preview to adjust convergence, so that I can do alignment without looking at a slider.
11. As an alignment operator, I want pinch-to-zoom on the preview, so that I can inspect alignment at 100% or 200% to catch sub-pixel error.
12. As an alignment operator, I want ± nudge buttons (1 px and 0.1 px) and a Reset, so that I have keyboard-style precision without a keyboard.
13. As an alignment operator, I want to toggle between auto-cropping the common region and showing the full frame with black bars, so that I can see exactly what HIT is doing and choose a clean image when working with creatives looking over my shoulder.
14. As an alignment operator, I want the iPad screen to show pure-luma red/cyan anaglyph, so that I can spot misalignment instantly without color-channel noise confusing my eyes.
15. As an alignment operator, I want a swap-eyes toggle for anaglyph mode, so that mismatched glasses or mislabeled sources don't force me to redo the source pickers.
16. As an alignment operator, I want a channel-test mode (solid red on left, solid cyan on right), so that I can verify my glasses are oriented correctly before doing real alignment.
17. As an alignment operator, I want to switch the iPad screen between SbS and anaglyph independently of the NDI output, so that I can iterate between alignment and "creative look" views without breaking the Quest viewer's stream.
18. As an alignment operator, I want my convergence, per-eye HIT, mode, and crop toggle to persist across launches, so that I resume exactly where I left off.
19. As an alignment operator, I want a "Reset session" action that clears HIT but keeps sources and favorites, so that I can start fresh between scenes without re-picking everything.
20. As an alignment operator, I want a status row showing each source's name, resolution, and framerate, so that I notice immediately if a camera is mis-set.
21. As an alignment operator, I want a non-blocking "Reconnecting…" indicator with the last good frame frozen on screen when a source disappears, so that the alignment view doesn't go black mid-take.
22. As an alignment operator, I want auto-retry every 2 seconds without my intervention when a source drops, so that brief WiFi flaps recover by themselves.
23. As an alignment operator, I want an interface that auto-hides the top bar after 3 seconds, so that I get maximum preview area while I'm working.
24. As an alignment operator, I want the convergence slider always visible at the bottom, so that I never have to dismiss UI to make the most common adjustment.
25. As an alignment operator, I want the iPad locked to landscape, so that rotation bugs never disrupt me mid-take.
26. As an alignment operator, I want the app forced into single-window fullscreen (no Stage Manager), so that I get predictable performance and no resize surprises.
27. As an alignment operator, I want the app to default to dark mode, so that the screen doesn't blow out my night vision on a dim set.

### Creative reviewer (director, DP, producer — the Quest viewer in another room)

28. As a creative reviewer, I want to see the stereoscopic camera output as full-bandwidth NDI on my Quest in NDI Theater, so that I can evaluate the actual 3D experience without compression artifacts.
29. As a creative reviewer, I want the NDI output stream to have a recognizable, customizable name, so that I can find it among other NDI streams on the network.
30. As a creative reviewer, I want the NDI stream to keep streaming smoothly even when the iPad operator is fiddling with anaglyph or channel-test on their screen, so that my preview is uninterrupted.
31. As a creative reviewer, I want the NDI stream to maintain source-rate framerate, so that motion in the preview matches what was shot.

### Camera operator / DP (cares about how sources are presented)

32. As a camera operator, I want to see partial preview (one eye live, the other showing a placeholder) when only one of my two cameras is connected, so that I can verify a single camera is streaming before I bring up the second.
33. As a camera operator, I want the app to handle resolution mismatches between my two sources by scaling to the smaller and showing a warning, so that a mis-set camera doesn't crash the tool or silently lie about alignment.
34. As a camera operator, I want the app to handle framerate mismatches without judder via FrameSync, so that one camera at 59.94 and another at 60 still produces clean stereo.

### Production tech / on-set IT (cares about deployment and reliability)

35. As an on-set IT lead, I want the app delivered through TestFlight to internal team Apple IDs, so that I can deploy to a controlled set of operators without going through full App Store review.
36. As an on-set IT lead, I want the app to prompt for local-network access on first launch with a clear explanation, so that operators understand why and grant the permission.
37. As an on-set IT lead, I want the app to handle WiFi interface changes (cart moves between APs), so that mid-session reconnection happens automatically.
38. As an on-set IT lead, I want the iPad to stay responsive even under sustained dual-NDI load, so that thermal throttling doesn't silently degrade output to the Quest.

### Future external creative tester (post-v1, for Beta App Review)

39. As an external creative tester invited to TestFlight, I want to install the app via a public TestFlight link without being on the developer team, so that I can preview shoots without LightSailVR onboarding me into their developer account.

### Developer (cares about maintainability and field-debuggability)

40. As the developer, I want the NDI SDK static library and headers vendored into the repo, so that anyone cloning the project can build it without re-installing the SDK system-wide.
41. As the developer, I want NDI bridge classes that are granular (one per primitive: discovery, receiver, sender), so that each is independently mockable and testable.
42. As the developer, I want stereo composition done in Metal shaders, so that performance scales on M-series silicon and adding new modes is a shader change.
43. As the developer, I want golden-image tests on the compositor, so that shader regressions are caught in CI rather than reported by an operator on set.
44. As the developer, I want the frame-pairing logic separated from the NDI bridge, so that I can unit-test pairing, stall detection, and single-source fallback with synthetic frames and a fake clock.

## Implementation Decisions

**Platform & distribution**

- Target: iPad-only, iPadOS 17+ deployment target, M-series iPad floor (M1+).
- Landscape-locked, dark-mode-locked, opt out of Stage Manager / multitasking.
- Apple Developer team: "Matthew Celia" (individual), bundle ID `com.lsvr.stereondi`.
- Distribution: TestFlight, internal-only for v1; external testers planned post-v1 (requires Beta App Review on first external submission, privacy policy URL, finalized icon set, beta description).
- Export compliance: standard exemption (TLS only); annual self-classification declared in App Store Connect.

**NDI**

- Use the **Standard NDI SDK for Apple** only. The Advanced SDK is rejected for v1 due to commercial-licensing complexity for redistribution.
- Receive supports both full-bandwidth NDI and NDI HX/HX2 (Standard SDK includes the HX decoder).
- Send is always **full-bandwidth NDI** in BT.709 limited UYVY 4:2:2 progressive — Quest's NDI Theater requires full-bandwidth.
- Frame sync uses `NDIlib_FrameSync` per receiver, pulled at the iPad's CADisplayLink rate. Cameras are assumed genlocked at source.
- The static library `libndi_ios.a` and the C headers are vendored into the repo (`Vendor/`), not referenced from `/Library/NDI SDK for Apple/`. This decouples the build from any specific developer machine.
- NDI® attribution is rendered in the Settings sheet per the SDK license.
- Output stream: user-editable name (default "Stereo Preview"), comma-separated groups field (default `Public`), no metadata channel, no tally.

**Render pipeline**

- Two output pipelines that share all upstream stages: NDI receive → per-eye HIT-corrected texture → an SbS reference texture. From that reference, two final-stage composites diverge:
  - iPad screen: operator-selected mode (SbS, anaglyph, channel-test).
  - NDI output: always SbS.
- All composition is in Metal shaders. RGB→UYVY conversion is also a shader, not CPU.
- Frames cross from the C NDI side to Metal as `CVPixelBuffer` wrappers over NDI frame memory (zero-copy where format permits; one conversion pass otherwise).
- HIT is implemented as a sub-pixel texture-coordinate offset in the sampling shader — bilinear filtering provides sub-pixel for free.
- Crop modes: auto-crop the common region (both eyes cropped by max absolute offset, scaled back to full size) ↔ full frame with black bars on the missing edge. Toggle, not separate modes per eye.
- Anaglyph: pure luma red/cyan. Left source's BT.709 luma → red channel; right source's luma → green and blue channels. Swap-eyes toggle inverts. Channel-test mode bypasses sources and outputs solid red on the left half and solid cyan on the right.

**Modules to be built**

Granular ObjC++ bridge over the C NDI API, plus Swift modules for everything above the bridge:

- **NDIDiscovery** — wraps `NDIlib_find_*`, exposes a live-updating list of NDI sources to Swift.
- **NDIReceiver** — wraps a single `NDIlib_recv_*` plus its FrameSync; per-source connection lifecycle + "latest frame at time T" pull API.
- **NDISender** — wraps a single `NDIlib_send_*`; accepts UYVY frames, owns advertise lifecycle.
- **FramePairer** — connects two NDIReceivers, emits `(LeftFrame?, RightFrame?)` pairs at a display clock; handles single-source fallback, stall detection, zombie sources.
- **StereoCompositor** — Metal pipeline; takes two textures + alignment params + mode, returns a composed texture. Handles SbS, anaglyph, channel-test, crop math, sub-pixel HIT, RGB↔UYVY.
- **NetworkResilience** — `NWPathMonitor` watcher emitting interface-change events that receivers subscribe to.
- **SessionStore** — UserDefaults-backed persistence: last source identifiers, alignment state, output stream config, favorites.
- **AlignmentState / AlignmentViewModel** — observable state owners that mediate between SwiftUI and the engine.
- **MetalPreviewView** — UIViewRepresentable wrapping MTKView for the SwiftUI preview surface.
- SwiftUI views: RootView, SourcePickerSheet, SettingsSheet, BottomBar (convergence + nudges + reset + per-eye fine disclosure), TopBar (sources + swap + mode segmented control + settings gear), EmptyState, StatusRow.
- App entry, scene config, Info.plist (`NSLocalNetworkUsageDescription`, `NSBonjourServices` for `_ndi._tcp`), Assets, launch screen.

**Persistence**

- All settings via `UserDefaults`. No Core Data, no SQLite. Persisted: last L/R source identifiers, convergence value, per-eye fine HIT, crop toggle, output mode, swap-eyes, output stream name, output groups, default-mode-on-launch preference, favorites list (named pairs with their saved alignment values).
- "Reset session" action clears HIT but preserves sources and favorites.

**Resilience and edge-case handling (v1, hard requirements)**

- Source disappearance during a session: freeze last good frame, show "Reconnecting…" indicator, retry every 2 seconds, auto-recover.
- WiFi interface change: same pathway via `NWPathMonitor`.
- Resolution mismatch between sources: scale both to the smaller resolution at the receive→stereo-pair stage; banner warning. HIT math operates in the smaller-source-pixel space.
- Framerate mismatch: handled implicitly by FrameSync; surface both rates in the status row.
- Color-space mismatch: convert both to BT.709 limited at receive time. HDR sources are downconverted to SDR.
- Interlaced sources: deinterlace via FrameSync where possible; otherwise pass dominant field with a warning.
- Sources with alpha: pre-multiply against black at receive.
- Zombie / stalled sources (no frame ≥2 s without disconnect): show "Stalled" indicator, distinct from "Disconnected." Auto-recover on resumption.
- Empty state (launched with no sources): full-screen prompt with the two pickers and instructional copy.
- Single-source partial preview: show that eye on its half, "No source / Reconnecting" placeholder on the other half. Don't black out both.
- Thermal degradation: NDI output stream never drops rate. iPad preview falls to 30 fps under sustained GPU pressure with a "Preview limited" indicator.

## Testing Decisions

**What makes a good test in this codebase**

Tests should verify externally observable behavior, not the implementation strategy. For the stereo compositor, that means the *pixels of the output texture* given specific inputs, not which Metal command buffer was created. For the frame pairer, that means the sequence of `(left, right)` pairs emitted given a scripted sequence of frame arrivals and clock ticks, not whether a particular buffer was retained internally. Tests must run fast and offline — anything that requires a real NDI source on the network is an integration test, not a unit test, and is run manually before each TestFlight upload rather than in every commit.

**Modules with isolated unit tests in v1**

- **StereoCompositor** — golden-image tests. Synthetic input textures (gradients, color fields, known patterns) → render → compare output texture to a stored reference image, per mode (SbS, anaglyph, channel-test) and per HIT value (zero, positive, negative, sub-pixel, edge-of-range). Catches shader regressions silently introduced by Metal/iOS updates or refactors.
- **FramePairer** — fake `NDIReceiver` doubles + a manually advanced clock. Verify: pair emission order under matched arrival, single-source fallback when one side stalls, stall-detection threshold, zombie recovery on frame resumption, behavior across interface-change events.
- **SessionStore** — round-trip every persisted field through UserDefaults and assert get-after-set equality. Verify migrations / default values when keys are absent.
- **Alignment value math** — pure functions: HIT clamping to ±400 px, crop-region math given two HIT values, sub-pixel offset → texture-coordinate conversion, swap-eyes parity for anaglyph.

**Integration tests (manual, not CI)**

- NDI bridge classes (`NDIReceiver`, `NDISender`, `NDIDiscovery`) require live network conditions. Manual checklist run before each TestFlight upload: launch NDI Test Patterns app on the same network, verify discovery shows it, connect both eyes to it, confirm send appears in NDI Studio Monitor on a separate machine, verify color/format/framerate of the sent stream. Documented as a manual test plan in the repo.

**No tests in v1**

- SwiftUI views (snapshot tests) — UI is in rapid iteration and snapshot churn is not worth the time.
- The thermal-degradation 30-fps fallback path — exercised manually by stressing the device.

**Prior art**

- This is a greenfield repo (empty as of 2026-05-01), so there is no in-repo prior art for test style. The Metal golden-image testing approach mirrors the pattern Apple uses in its own sample shader test code (test bundles that load reference PNGs from `Bundle.module` and compare against a freshly rendered texture). The frame-pairer fake-clock approach mirrors standard test patterns for time-driven Combine / async streams. Both are described in the relevant module-level READMEs as they're written.

## Out of Scope

The following are intentionally not in v1. Each is a deliberate deferral, not an omission:

- **Difference-mode overlay** — confirmed nice-to-have during grilling; deferred to v1.1.
- **Audio passthrough on the output stream** — no audio at all in v1. v1.1 may add "passthrough left source's audio" as a single toggle.
- **NDI Access Manager group filtering on the receive side** — the Settings field exists for the *send* side groups in v1; receiver-side group filtering is v1.1.
- **Output format decoupled from input** — v1 always outputs at 1920×1080 SbS at the source's framerate. Output resolution / framerate selection is v1.1.
- **iPhone support** — explicitly out of scope. iPad-only, M-series.
- **Stage Manager / multitasking support** — explicitly opted out for v1; predictable performance trumps multitasking flexibility.
- **HDR output** — sources downconverted to SDR BT.709 at receive. HDR mastering surface is not the goal.
- **NDI metadata channel and tally** — neither is sent or consumed in v1.
- **Recording / capture** — this is a preview tool, not a recorder.
- **Color correction / LUTs** — not part of the alignment workflow.
- **Multi-rig support** — one stereo pair at a time, one output stream at a time.
- **Background NDI sending** — sender stops when the app backgrounds; this is correct iOS behavior and not worth fighting for v1.
- **Finalized brand assets** — placeholder app icon and launch screen for v1; finalize before external Beta App Review submission.
- **CI** — no CI in v1. Manual integration test pass + local unit test run before each TestFlight upload.
- **Privacy policy URL on lightsailvr.com** — required only when external testers go in, blocked on v1.1 Beta App Review prep.

## Further Notes

**NDI license attribution.** The Standard SDK license requires attribution. Render the required NDI® attribution string in the Settings sheet (and in any About/Credits view if added later). NDI® is a registered trademark of Vizrt NDI AB; do not modify the trademark presentation.

**Why Standard SDK and not Advanced.** The Advanced SDK adds GPU decode and HX2/HX3 send, both of which would be marginally useful, but redistribution of the Advanced lib in a TestFlight or App Store build requires a signed Vizrt commercial agreement. The grilling concluded that the bandwidth and CPU savings don't justify the licensing complexity for v1, especially since the Quest target requires full-bandwidth output regardless. Reconsider if a future requirement demands NDI HX2 sending (e.g., creatives reviewing over a constrained WAN).

**Why FrameSync and not naive latest-wins.** Naive latest-wins pairing produces visible stereo "twitches" on motion when the two source streams' UDP arrival jitter desynchronizes. For an alignment tool specifically, this is unacceptable — the operator can't distinguish a real misalignment from a transient temporal mismatch. FrameSync's ~1–2 frames of added latency is negligible for a creative-preview workflow.

**Why two output pipelines and not one.** The operator wants anaglyph for fine alignment; the Quest viewer wants SbS for actual 3D viewing. Locking them together would force the operator to break the Quest viewer's stream every time they want to spot-check alignment in anaglyph. Two pipelines sharing upstream stages costs ~1 ms of Metal time on M-series and saves the operator from constant mode-flipping pain.

**Why iPad Pro M1 floor.** Two NDI receives + dual decode + Metal composite + NDI send at 1080p60 is genuinely demanding for a tablet. Pre-M-series chips (A14, A15) would thermally throttle under sustained load and ship a degraded experience. Memory bandwidth and 8GB+ RAM matter when holding decoded frames from two sources. Drawing the line at M1 means every supported device handles the workload comfortably with thermal headroom for the alignment session length.

**License redistribution path for vendored library.** `libndi_ios.a` from the Standard SDK is committed to `Vendor/` along with headers. The Standard SDK license permits redistribution as part of an application binary; we are not redistributing the SDK as a developer tool, only as a linked component of the shipping app. Confirm wording in `licenses/libndi_licenses.txt` is reproduced in the app's About/Credits view.

**Network privacy prompt copy.** The `NSLocalNetworkUsageDescription` string must explain *why* the app browses the local network in terms a non-technical operator understands. Suggested copy: "Stereo NDI Preview discovers cameras and other NDI sources on your local network so you can connect to them for stereoscopic preview." Refine before first TestFlight upload.

**Out-of-band Quest NDI Theater configuration.** This app does not configure or control the Quest. The Quest user must independently install NDI Theater (or equivalent NDI receiver) and select this app's stream from the Quest's source list. Document this as a one-paragraph "operator setup" note shipped with the TestFlight beta description.
