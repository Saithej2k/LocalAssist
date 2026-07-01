# LocalAssist iOS App

This folder contains the app entry point and iOS metadata for the LocalAssist phone experience. The reusable SwiftUI surface lives in the Swift package target `LocalAssistAppUI`, and `project.yml` generates the checked-in Xcode project used for simulator builds.

## Build In Xcode

```bash
xcodegen generate
env -u LD -u LDFLAGS DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project LocalAssist.xcodeproj \
  -scheme LocalAssist \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO build
```

Run on an iPhone 17 or iOS 26 simulator to exercise the Foundation Models path. Toggle offline fallback in the app to exercise deterministic execution.

If Homebrew `lld` is exported through `LD`, unset `LD` and `LDFLAGS` for Xcode commands so Xcode uses Apple’s Mach-O linker.
