# Agent conventions for stereondi

Shared conventions for the autonomous agents implementing the slices in `docs/PRD.md`. Read this before doing anything.

## Repo layout

```
stereondi/
  stereondi/                  # app target source root (file-system-synchronized; just drop files in)
    stereondiApp.swift
    ContentView.swift
    Assets.xcassets/
    NDI/                      # ObjC++ bridge over libndi_ios.a (this slice creates it)
    Metal/                    # MTKView + compositor + shaders
    Views/                    # SwiftUI views
    Persistence/              # UserDefaults-backed state
    Resilience/               # NWPathMonitor + reconnect logic
    stereondi-Bridging-Header.h
  stereondiTests/             # unit tests (file-system-synchronized)
  stereondiUITests/
  stereondi.xcodeproj/
Vendor/
  libndi_ios.a
  include/Processing.NDI.*.h
docs/
  PRD.md
  AGENT_CONVENTIONS.md        (this file)
  MANUAL_TEST_PLAN.md         (added in slice #15)
```

## File-system-synchronized groups — important

The Xcode target uses `PBXFileSystemSynchronizedRootGroup`. **Do not edit `project.pbxproj` to add source files.** Just create `.swift`, `.mm`, `.h`, `.metal` files inside the appropriate target's source root and Xcode picks them up automatically.

The only times you should touch `project.pbxproj`:
- Changing build settings (deployment target, search paths, linker flags, bridging header path).
- Adding a new `PBXNativeTarget` (none of the slices need this).

## Bridging header

`stereondi/stereondi/stereondi-Bridging-Header.h` exposes the ObjC++ NDI classes to Swift. Add new ObjC/ObjC++ headers there as you create them.

## Naming

- Swift files: `PascalCase.swift`, one type per file where reasonable.
- ObjC/ObjC++ files: pair `Foo.h` + `Foo.mm` (always `.mm` so we can include `Processing.NDI.Lib.h`).
- Metal shader files: `Foo.metal`.
- Test files: `<TypeUnderTest>Tests.swift` using Swift Testing (`import Testing`).

## Branching, commits, PRs

- Branch off the **previous slice's branch**, not main. Branch name format: `cursor/issue-<n>-<short-slug>-2c32`.
- One PR per slice. PR base branch = the previous slice's branch (so the diff is just this slice's work).
- PR title: `Issue #<n>: <slice title>`.
- PR body: paste the issue's acceptance criteria as a checklist with checked items reflecting what's done and explicit notes on items deferred to manual / HITL.
- Commits: one logical change per commit, descriptive imperative messages. No batching.
- Push with `git push -u origin <branch>`.

## What you can and cannot test

You are running on Linux. There is no Xcode, no `xcodebuild`, no iOS simulator, no Metal. **You cannot build the project, run the app, or execute tests.** All build/run validation is HITL on the user's Mac.

Therefore:
- Write code to compile cleanly under iOS 17+ / Swift 5/6 strict concurrency (the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`).
- Write unit tests that are **pure** (no UIKit, no Metal, no NDI network) so the user can run them in seconds. Pure compositor math goes in pure-Swift helpers; the Metal pipeline that uses them is a separate file. Pure pairing logic goes in `FramePairer`; the receiver wrappers it consumes are protocols with mock conformance.
- For Metal golden-image tests, write the test scaffolding + reference-image-load helper, but generate reference PNGs on the user's Mac (the test target should have a `--update-references` env-var path that re-emits PNGs and is documented in the PR).
- For NDI-bridge slices (`NDIReceiver`, `NDISender`, `NDIDiscovery`), write the ObjC++ wrapper carefully against the headers in `Vendor/include/` and document the manual integration test plan in the PR description. The user runs it.

## Concurrency

- The project enables Swift strict concurrency with `MainActor` as the default isolation. Background work (NDI receive thread, `CADisplayLink` callback, `NWPathMonitor`) must explicitly hop off `@MainActor`.
- `NDIReceiver` and `NDISender` ObjC++ classes manage their own threads internally. Their Swift-facing API should be thread-safe and document which methods are main-actor-only vs callable from any thread.
- Use `nonisolated` deliberately. Don't sprinkle `@MainActor` blindly.

## Style

- 4-space indent for Swift, `// MARK: -` section markers.
- No comments that narrate what the code does. Comments only for non-obvious intent or invariants.
- No emoji.
- Prefer `private`/`internal` until a wider scope is needed.
- `import Foundation` only when used; same for other modules.

## Per-slice handoff state

When you finish your slice, update `docs/SLICE_STATUS.md` (create if missing) with one line summarizing: branch name, what's in, what's deferred, any non-obvious assumptions the next slice should know.
