# Contributing

Thanks for your interest. The ground rules are short:

## Setup

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test                     # must stay green
swift run localassist-selftest
swift run localassist-eval --min-score 0.9
xcodegen generate && open LocalAssist.xcodeproj
```

The full Xcode toolchain is required — plain CommandLineTools builds but
silently skips XCTest.

## Principles

1. **Nothing leaves the device.** No networking, no analytics SDKs, no
   crash reporters that phone home. Diagnostics are written to local files.
2. **Verification is deterministic.** New behavior comes with unit tests;
   engine behavior changes must keep the eval suite at or above the CI
   gate. No LLM-judged tests.
3. **The eval dataset is append-only.** Add cases; never mutate existing
   ones, so score history stays comparable.
4. **Zero warnings.** The build is warning-free under strict concurrency;
   keep it that way. SwiftLint runs in CI.

## Pull requests

Branch from `main`, keep commits focused with imperative titles and prose
bodies, and make sure `swift test`, the self-test, and the eval gate pass
locally before opening the PR.
