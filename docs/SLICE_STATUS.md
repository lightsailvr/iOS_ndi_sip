# Slice status

One line per slice as it merges. Newest at the bottom.

## Slice #1 — Project foundation (branch `cursor/issue-1-foundation-2c32`)
**In:** Vendored NDI Standard SDK linked into target. Bundle ID, signing team, iPad-only / landscape / dark / Stage Manager opt-out, iPadOS 17 deployment target, `NSLocalNetworkUsageDescription` + `NSBonjourServices=_ndi._tcp`. Bridging header + `NDIRuntime` ObjC++ wrapper around `NDIlib_initialize/destroy` (refcounted, started on scene-active, stopped on scene-background). `ContentView` shows NDI version + CPU-supported flag instead of generic Hello World, proving the SDK linked.
**Deferred / HITL:** Archive + sign + run on physical iPad (no Xcode in CI VM). First-launch local-network prompt visible (HITL). All AFK source code is in.
