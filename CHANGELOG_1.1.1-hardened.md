# Husk 1.1.1-hardened (community deep pass)

Based on Husk 1.1.0. This is not an official upstream release — it is a
comprehensive source hardening package focused on launch stability, safety,
and performance.

## Highlights

### Launch stability
- Trap guard installed before any other work in `HuskApp.init`
- JIT `prewarm()` never kills the process; failures set `lastFailure` only
- Dynamic JIT region size: 128 / 256 / 512 MiB from free memory (override in Settings)
- `QemuRunner.start()` refuses to spawn the guest without usable executable memory
- `ContentView.start()` logs and aborts cleanly when JIT is unavailable
- C trap handler is idempotent and uses `SA_NODEFER`

### Performance
- Metal present: short lock snapshot, triple buffering, smoothed FPS
- Audio: interruption + media-services-reset recovery; prefer speaker route
- `HuskPerformance` module for FPS EMA, jetsam headroom, thermal state

### Security
- `PathSanitizer` for path validation and POSIX shell quoting
- Guest bridge: command length/NUL checks; all remote paths properly quoted
- Import size hard cap at 2 GiB (IncomingFiles + Translation Layer)
- Reject path traversal / NUL in shared APK filenames

### UX / diagnostics
- Settings → JIT: region size picker + live performance line
- JIT card shows last prewarm failure reason
- Crash reports include JIT state, free memory, thermal summary

## Files touched
HuskApp, JITBootstrap, ContentView, QemuRunner, HuskBridgeFS, IncomingFiles,
TranslationLayer, HuskMetalPresenter, HuskAudio, SettingsTab, JITCard,
CrashReport, husk-ios-jit.c, PathSanitizer (new), HuskPerformance (new)

## How to build
1. Copy all files from this package into the matching paths under `src/`
2. Add `PathSanitizer.swift` and `HuskPerformance.swift` to the app target
3. Build with your existing Xcode / signing flow
4. Test on TrollStore, SideStore+StikDebug, and Dopamine paths

## Not included (future work)
- Full ART/bionic Translation Layer completeness
- QemuRunner modular split
- Play API certificate pinning
- Official IPA distribution
