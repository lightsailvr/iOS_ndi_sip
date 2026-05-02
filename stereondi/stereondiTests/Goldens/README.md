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

Slice #4 ships the test scaffolding without the actual reference PNG
because the agent that wrote slice #4 ran on Linux where Metal isn't
available. The first developer who runs the tests on a Mac will see
`GoldenImageError.missingReference("sbs_zero_hit_gradient")`. The fix
is to run the test once with `STEREONDI_UPDATE_GOLDENS=1` to seed the
reference PNG, then re-run normally to confirm the comparison passes.

## File-system-synchronized test target

The `stereondiTests` Xcode target uses `PBXFileSystemSynchronizedRootGroup`,
so PNGs dropped into this directory are auto-included in the test
bundle's Resources phase — no `project.pbxproj` edits needed.
