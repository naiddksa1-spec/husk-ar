# Husk 1.1.1-hardened — Best reachable source package

Deep hardening of Husk 1.1.0. See `CHANGELOG_1.1.1-hardened.md`.

## Complete file list (18 items)

### Replace existing
```
src/app/Husk/HuskApp.swift
src/app/Husk/JITBootstrap.swift
src/app/Husk/ContentView.swift
src/app/Husk/QemuRunner.swift
src/app/Husk/HuskBridgeFS.swift
src/app/Husk/HuskMetalPresenter.swift
src/app/Husk/HuskAudio.swift
src/app/Husk/IncomingFiles.swift
src/app/Husk/TranslationLayer.swift
src/app/Husk/SettingsTab.swift
src/app/Husk/JITCard.swift
src/app/Husk/CrashReport.swift
src/ios-jit/husk-ios-jit.c
```

### Add new (Xcode target membership required)
```
src/app/Husk/PathSanitizer.swift
src/app/Husk/HuskPerformance.swift
```

### Docs
```
README_PATCHES.md
CHANGELOG_1.1.1-hardened.md
husk-ios-jit-trap-hardening.patch
```

## One-liner install
```bash
cp husk_patches/{HuskApp,JITBootstrap,ContentView,QemuRunner,HuskBridgeFS,HuskMetalPresenter,HuskAudio,IncomingFiles,TranslationLayer,SettingsTab,JITCard,CrashReport,PathSanitizer,HuskPerformance}.swift src/app/Husk/
cp husk_patches/husk-ios-jit.c src/ios-jit/
# Then enable PathSanitizer.swift + HuskPerformance.swift in Xcode target
```

## What you get
- No more silent launch crashes from unserviced brk
- QEMU never starts without JIT → no mystery SIGSEGV
- Adaptive JIT memory for old phones
- Safer guest shell (injection-resistant)
- Better Metal + audio under real device conditions
- Settings control for JIT size + live performance readout
- Richer crash reports for debugging

Build with your usual Xcode / TrollStore / SideStore flow.
