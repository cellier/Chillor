# Source-release validation — 2026-10-01

- All eight `Tests/*test.py` scripts passed using bundled CPython 3.12, each in a separate process via `scripts/test-python.py`. This covers SDK/context checks, MCP file tools, provider serialization, artifact handling, proxy policies, sandbox gating and web-tool policies. It is not a live-model reliability benchmark.
- Fixed the sandbox gating test to inject a failed probe into the actual server being tested. Previously it created a second workspace, which could successfully probe the Mac and invalidate the test's assumption.
- Scanned the publication file list for credential patterns and developer-specific paths. No matches were found. Runtimes, weights, user state, internal notes, outputs and work logs are excluded.
- The default native build with Command Line Tools Swift 6.4 and the macOS 27 SDK failed in vendored NetworkImage because `SwiftUIMacros.StateMacro` is missing from that toolchain. Re-running `swift build -c release --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` **passed** on this Mac. `scripts/build.sh` accepts `CHILLOR_SWIFT_SDK` to select this SDK explicitly. This verifies source compilation, not a fresh installer or UI acceptance run.
- No new DMG, signing/notarization result, UI regression result, automatic capability installer, or live video-download result is claimed by this publication.
