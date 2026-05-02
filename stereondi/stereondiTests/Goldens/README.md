# Compositor goldens

This directory holds reference PNGs the StereoCompositor's golden-image
tests compare against. They are committed to git.

## Why this directory

The compositor renders deterministic pixels for a given input pair,
mode, and HIT value. A golden-image test catches regressions silently
introduced by Metal/iOS updates, shader edits, or refactors of the
draw structure. Each test renders into an off-screen MTLTexture, reads
it back to a CGImage, and compares to the bundled reference here.

## Updating after a deliberate compositor change

```
STEREONDI_UPDATE_GOLDENS=1 xcodebuild test \
  -project stereondi/stereondi.xcodeproj \
  -scheme stereondi \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'

git add stereondiTests/Goldens/
git commit -m "Re-seed compositor goldens after <change>"
```

The test harness writes the freshly rendered PNG straight back into
this directory (resolved from `#filePath`) when the env var is set,
then exits the test as a pass without comparing.

## First-run on a fresh checkout

Slice #4 shipped the test scaffolding without the reference PNGs
because the agents writing slices #4, #6, #7, and #8 ran on Linux
where Metal isn't available. The first developer who runs the tests
on a Mac will see `GoldenImageError.missingReference(...)` for any
unseeded golden. The fix is to run the tests once with
`STEREONDI_UPDATE_GOLDENS=1` to seed the reference PNGs, then re-run
normally to confirm the comparisons pass.

Goldens currently expected (slices #4, #6, #7, #8):

- `sbs_zero_hit_gradient.png` — convergence 0 (slice #4 baseline)
- `sbs_hit_p50_crop_auto.png` — convergence +50, AUTO crop (renamed from `sbs_hit_p50.png` in slice #7 — same render, AUTO was implicit before)
- `sbs_hit_p50_crop_off.png`  — convergence +50, OFF crop (slice #7; should show a thin black bar on the inside edge of one half)
- `sbs_hit_n50.png`  — convergence −50 (auto)
- `sbs_hit_p200.png` — convergence +200 (auto)
- `sbs_hit_p0_3.png` — convergence +0.3 (sub-pixel, auto)
- `anaglyph_zero_hit_gradient.png` — slice #8; pure-luma red/cyan anaglyph, convergence 0, swap-eyes off, red gradient → red channel, blue gradient → green+blue channels.
- `anaglyph_swapped_zero_hit_gradient.png` — slice #8; same render with swap-eyes ON; red and cyan source assignments invert.
- `channel_test.png` — slice #8; sources nil, `screenMode = .channelTest`. Solid red on the left half, solid cyan on the right half.

Slice #7 note: if `sbs_hit_p50.png` is left over from a slice-#6 seed,
delete it after re-running the seeding pass — the test now looks for
the suffixed name.

Slice #8 sanity check: re-running ALL existing SbS goldens should
still pass byte-identically — `renderScreen` with `screenMode = .sbs`
routes through the unchanged SbS draw path. If they drift after this
slice, something in the shared-upstream refactor is wrong.

## File-system-synchronized test target

The `stereondiTests` Xcode target uses `PBXFileSystemSynchronizedRootGroup`,
so PNGs dropped into this directory are auto-included in the test
bundle's Resources phase — no `project.pbxproj` edits needed.
