# LocalAssist iOS App

This folder contains the app entry point and iOS metadata for the LocalAssist phone experience. The reusable SwiftUI surface lives in the Swift package target `LocalAssistAppUI`, which lets CI compile the UI without requiring a checked-in generated Xcode project.

## Build In Xcode

1. Open `Package.swift` in Xcode 26 or newer.
2. Create an iOS App target named `LocalAssist`.
3. Add the package products `LocalAssistAppUI`, `LocalAssistAppIntents`, `LocalAssistFoundationModels`, and `LocalAssistCore`.
4. Use `Apps/iOS/LocalAssist/LocalAssistApp.swift` as the app entry point and `Apps/iOS/LocalAssist/Info.plist` as the app metadata.
5. Run on an iPhone 17 or iOS 26 simulator to exercise the Foundation Models path; toggle offline fallback in the app to exercise deterministic execution.

The Command Line Tools environment used by this repo can compile the Swift package, but it cannot boot an iOS simulator because full Xcode and `simctl` are not installed.
