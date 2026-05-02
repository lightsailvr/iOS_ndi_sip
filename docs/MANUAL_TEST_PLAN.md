# Manual integration test plan

Run the full plan before every TestFlight upload. The unit-test suite (run via `xcodebuild test`) catches Swift-side regressions; this document covers the integration surfaces that aren't testable on a CI host (NDI bridge, Metal, sender/receiver wire interop, on-device gestures, thermal behavior).

## Prerequisites

Hardware:
- One iPad Pro (M-series, M1 or later). Test build installed via `xcrun devicectl device install app …` or Xcode Run.
- Two NDI-capable cameras OR one Mac running NDI Test Patterns (`/Library/NDI Tools/Test Patterns.app`) + a second Mac running the same. Anything that emits a stable NDI source is fine.
- One Mac running NDI Studio Monitor (`/Library/NDI Tools/Studio Monitor.app`).
- One Meta Quest with NDI Theater (or NDI HX Camera companion app — NDI Theater preferred).
- All devices on the same Wi-Fi LAN (5 GHz, no AP isolation). The iPad and at least one source on the same band ideally.

Software:
- Latest TestFlight / Xcode 15.4+ (16+ recommended). iPadOS 17.0+ on the device.

## Pre-flight (one-off setup, also run if shaders or compositor logic changed)

1. **Seed compositor reference PNGs** (deferred from slices #4, #6, #7, #8):
   ```sh
   STEREONDI_UPDATE_GOLDENS=1 xcodebuild test \
     -scheme stereondi \
     -destination 'platform=iOS Simulator,name=iPad Pro (M4) (11-inch),OS=latest'
   ```
   Then `git add stereondi/stereondi/Tests/Goldens/` and commit. After this, the golden tests run as ordinary equality checks and gate every subsequent build.
2. **Set build number** (PRD: build = git commit count):
   ```sh
   scripts/set-build-number.sh
   ```
   Add `stereondi/stereondi/build-number.xcconfig` to `.gitignore` if not already; leave it un-committed. (For TestFlight uploads, run the script every time before `xcodebuild archive`.)

## A — NDI receive (single source)

1. Launch NDI Test Patterns on the LAN; let it advertise "Color Bars".
2. Launch the iPad app. Within 5 s, "Color Bars" should appear in the Left source picker dropdown.
3. Pick "Color Bars" as Left → preview shows the SMPTE bars on the left half. Right half is black ("No source — tap to pick").
4. Tap the right half → picker opens. Pick the same "Color Bars" → both halves now show the test pattern.
5. Verify the StatusRow shows source name, resolution, framerate, and a green dot per side.

## B — NDI send (sender pipeline + Quest)

1. With both sources connected from §A, on a separate Mac open NDI Studio Monitor.
2. The Studio Monitor's source list should show `<your iPad name> (Stereo Preview)` within seconds.
3. Select it → the SbS composite renders at 1920×1080. Resolution and framerate match the source ("60 fps" or "59.94 fps").
4. On the Quest, open NDI Theater. Select the same source. The 3D preview should display correctly (assuming your two sources represent left and right of a stereo pair).
5. Background the iPad app → Studio Monitor's source disappears within a couple of seconds. Foreground → it reappears.

## C — Convergence and per-eye HIT

1. With two stereo-paired sources connected, drag the convergence slider in the BottomBar.
2. Both eyes should shift in opposite directions; the readout updates to integer pixels.
3. Tap `+1 px` and `+0.1 px` nudges; verify the readout increments correctly.
4. Open the per-eye fine disclosure. Set `leftFineHIT = +50`, `rightFineHIT = -50`. The readout shows the per-eye totals.
5. Two-finger horizontal drag on the preview → convergence changes. Pinch → zoom from 1.0 → 2.0. Double-tap → zoom resets.
6. Both the iPad screen and the Quest's NDI feed reflect HIT changes within one frame.
7. Toggle Crop Auto / Off; verify Off shows visible black bars on the cropped edges.

## D — Anaglyph, channel test, swap-eyes

1. In the TopBar, switch the segmented mode picker to "Anaglyph".
2. Verify the iPad screen renders red/cyan luma anaglyph (left → red, right → green/blue). Wear red/cyan glasses; left should appear red-tinted to the red eye, etc.
3. While the iPad is in anaglyph, verify the Quest's stream stays SbS (not anaglyph).
4. Open the overflow menu → toggle Swap Eyes. The red/cyan assignment inverts.
5. Switch to "Channel Test". The iPad screen shows solid red (left half) + solid cyan (right half). Verify against your glasses orientation. The Quest's stream stays SbS.
6. Switch back to SbS.

## E — Source-picker flows (auto-discovery + manual + favorites)

1. Pick a source from the discovered list. Switch.
2. Tap "Connect via URL…". Enter `ndi://<machine-ip>:5961/Color Bars` (matching your test source). Connect. Verify the preview switches.
3. With both sides connected and a non-zero convergence, save as favorite "Test Bench". Reset alignment. Tap the favorite → both sides + alignment restore.
4. Swipe-to-delete the favorite. Verify it's gone.

## F — Persistence + silent auto-reconnect

1. With both sides connected, force-quit the app.
2. Relaunch. Within 5 s, both sources reconnect silently (no picker shown, preview comes back).
3. Force-quit again. Disable the source machines. Relaunch. After the 5 s grace window, the EmptyState screen appears with the two pickers.
4. Re-enable a source. Pick it via the EmptyState picker. The single-source partial preview kicks in (live frame on its half, "No source — tap to pick" on the other).

## G — Resilience (drops, stalls, mismatches)

1. **Source disappears:** With two sources connected, kill one of them at the source machine. The affected eye freezes the last good frame within 100 ms; "Reconnecting…" overlay appears within 1 s; the StatusRow dot turns amber. Auto-recovery within 2 s of restoring the source.
2. **Stalled vs disconnected:** Block UDP for the source's port (firewall) without killing the source process. After 2 s the affected eye shows "Stalled" (red dot, distinct from the amber Reconnecting). Unblock; recovery within 2 s.
3. **WiFi handoff:** Move the iPad between two APs serving the same LAN. Both receivers re-establish without operator intervention within 4 s.
4. **Resolution mismatch:** Run two sources at 1920×1080 and 1280×720. The WarningBanner shows "Mismatch: 1920×1080 / 1280×720". Both eyes still render (smaller letterboxed inside its half).
5. **Interlaced source:** Connect a 1080i source. WarningBanner shows "Interlaced source". Verify FrameSync deinterlaces (no comb artifacts in the preview).
6. **Alpha source:** Connect a BGRA-with-alpha source. Premultiply against black should yield no halos.

## H — Thermal degradation

1. With two live sources at 60p and the sender active, cover the iPad's back (block thermal dissipation).
2. After ~5 minutes, `ProcessInfo.thermalState` should hit `.serious`. The "Preview limited" badge appears in the top-right chrome.
3. The on-screen MTKView's redraws drop to 30 Hz visibly (count slider drag updates against a stopwatch, or look at the Studio Monitor's source's live frame counter).
4. Critical: confirm the **NDI output stream stays at 60 fps** (Studio Monitor's frame counter) while the iPad preview is at 30 fps. The sender's pacing is independent of the on-screen redraw gate.
5. Uncover the iPad. After 5 s of nominal frame timing, the preview returns to full rate; the badge disappears.

## I — Settings sheet

1. Open the gear icon. The sheet appears at the `.large` detent.
2. Verify Network section: Stream name + Groups text fields. Edit the Stream name to "Stage A 3D" → within seconds, Studio Monitor reflects the new name.
3. Display section: Default-mode-on-launch picker, Swap eyes toggle, Channel test button.
4. Session section: Tap "Reset session". Convergence + per-eye HIT snap to 0; sources, favorites, modes, output config preserved.
5. About section: App version (1.0.0), build (git commit count), iOS version, iPad model identifier, NDI runtime version. Tap "NDI® attribution" → scrollable monospaced text. Verify the `®` glyph renders.
6. Drag-down dismiss closes the sheet.

## J — Chrome auto-hide

1. Tap the preview area once. The TopBar + StatusRow reappear (if hidden) and stay visible for 3 s.
2. After 3 s of no touches, both fade out. The BottomBar (convergence slider) stays visible permanently.
3. Two-finger drag on the preview does NOT bump chrome visibility.

## K — Privacy prompt

1. Fresh install (delete the app + restart the iPad if needed). On first launch, the local-network permission prompt appears with the operator-friendly copy from `INFOPLIST_KEY_NSLocalNetworkUsageDescription`. Tap Allow.
2. NDI source discovery should populate within 2 s. If denied, document the no-discovery fallback path in the operator-setup notes.

## Pre-upload Xcode dance (HITL — not scriptable from this repo)

1. Open `stereondi/stereondi.xcodeproj` in Xcode 16+.
2. Run `scripts/set-build-number.sh`.
3. Select the `stereondi` scheme, "Any iOS Device (arm64)" destination.
4. Product → Archive. Wait for archive to complete.
5. In the Organizer, select the new archive → Distribute App → App Store Connect → Upload.
6. Confirm the export-compliance declaration (we set `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO`, so the standard TLS exemption applies — no per-upload prompt).
7. In App Store Connect → TestFlight → Internal Testing, add the new build to the internal-tester group.
8. Verify at least one internal tester has installed the build via TestFlight on a physical iPad Pro M-series and run §A → §I from this plan.

## What gets bumped between TestFlight uploads

- Marketing version (`MARKETING_VERSION` in the pbxproj): bumped manually for each public-facing version (e.g. `1.0.0` → `1.0.1` for a bugfix, `1.0.0` → `1.1.0` for the v1.1 backlog items).
- Build number (`CURRENT_PROJECT_VERSION`): auto-derived from `git rev-list --count HEAD` via `scripts/set-build-number.sh`. Re-run before every archive.

## Out of scope for this plan (per PRD)

- External (Beta App Review) testing — needs privacy policy URL on lightsailvr.com, finalized icon, beta description. Tracked separately.
- Background NDI sending verification (sender stops on background by design).
- HDR, audio passthrough, recording, color correction, multi-rig — all v1.1+.
