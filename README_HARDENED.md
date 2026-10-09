# Husk 1.1.1-hardened

Full Husk 1.1.0 source tree with all hardening patches applied + Arabic (Gulf colloquial).

**App name: Husk** (unchanged)

## New Swift files (add to Xcode target)
- PathSanitizer.swift
- HuskPerformance.swift
- HuskL10n.swift

## Localization
- ar.lproj / en.lproj under src/app/Husk/
- Set device language to Arabic for UI

## Build
Open src/app/Husk.xcodeproj in Xcode, add the three new files to the target, build & sign as usual.
