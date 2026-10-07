# Husk 0.8.1 review pass

Not built or run: no Xcode/Mac here. Everything below is source-level and must be built and tested on a device.

## Changed
- New icon set (all 7 variants + in-app previews), see src/app/Husk/Assets.xcassets and Resources/icon-*.png
- AppSource.swift: downloads are https-only, must return 2xx, size <= 2 GB, must start with "PK", and the saved filename is sanitised (no path tricks from a remote catalogue)
- husk-tl-jni.c: GetStringUTFRegion strcpy -> bounded memcpy, integer-overflow-safe range check
- husk-tl-va.c: strcpy of a literal -> memcpy

## Reviewed, left as is (on purpose)
- NSAllowsArbitraryLoads: guest Android apps use plain http through Husk's own networking; removing it would break them
- get-task-allow: required for JIT via a debugger

## Not done
- Full rewrite, new run flow, new in-app UI: needs a Mac build + device testing loop
