# Build and test

[Documentation](README.md) · [RemoteFiles](../README.md)

Run commands from the repository root. Use Xcode 27.0 or newer and an available iOS 27 simulator; substitute your simulator name in the examples.

## Build and run

1. Open `RemoteFiles.xcodeproj` in Xcode 27.0 or newer.
2. Select the shared **RemoteFiles** scheme and an iOS 27 simulator. Dependencies resolve from the checked-in lockfile.
3. Run. The app starts with an empty real library. **Settings → Explore Demo** is an explicit sample workspace; it is never used as a connection-error fallback. The `--demo` launch argument also selects that mode.
4. The project uses the Iris Giertuga development team for this workspace. For another developer, select your own signing team under Signing & Capabilities and set an available bundle ID if necessary. Keep the paired iPhone unlocked with Developer Mode enabled when installing or running tests.

```sh
xcodebuild -project RemoteFiles.xcodeproj -scheme RemoteFiles \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
xcodebuild -project RemoteFiles.xcodeproj -scheme RemoteFiles \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData-device \
  CODE_SIGNING_ALLOWED=NO build
```

Simulator signing is ad hoc and requires no personal development team. The generic device command checks compilation; it does not produce an installable signed iPhone build.

The local Swift package contains `RemoteFilesCore` and `RemoteFilesUI`. Xcode owns the runnable app, hosted iOS core-test target, and native UI-test target. The UI test uses the explicit demo workspace and exercises browsing, rendered/source reading, refresh, and back navigation without touching saved real connections. Tests use the separate minimal `RemoteFilesTestHost`. The hosted image lifecycle regressions also link `RemoteFilesUI` to check the production viewer and memory-warning handler. After adding test files, regenerate its small project with `python3 scripts/generate-project.py`; the script does not fetch packages or modify source files. Commit both `Package.resolved` and `RemoteFiles.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` when dependency resolution changes.

## Reproducible verification

```sh
swift test                         # unit tests; real-server cases explicitly skip without a fixture
scripts/test-openssh.sh swift test  # isolated real OpenSSH fixture, generated temporary keys
scripts/test-openssh.sh xcodebuild -project RemoteFiles.xcodeproj \
  -scheme RemoteFiles -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath DerivedData -collect-test-diagnostics never \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
python3 -B scripts/test_runner_finalization.py -v  # runner failure/cleanup regressions
python3 Fixtures/generate-fixtures.py /private/tmp/remotefiles-fixtures
# Optional actual iOS VoiceOver speech/focus checks (Xcode 27, local fixtures):
scripts/test-voiceover.sh SIMULATOR_UDID /private/tmp/remotefiles-voiceover-run
```

The optional VoiceOver runner copies the project into its output directory and substitutes a local fixture entry point. It tests the current production reader/image views, records actual `XCUIVoiceOverService` utterances and screenshots, and restores the original Simulator VoiceOver enabled state after each test. Use a fresh output directory. It does not install on a physical phone or open external links. Simulator speech/focus checks do not establish touch gestures, rotor behaviour, Braille, or physical-device acceptance.

Use the signed simulator test command for the actual Keychain tests: an unsigned simulator test host returns Keychain error `-34018`. The fixture launcher forwards its environment into iOS XCTest through `TEST_RUNNER_REMOTEFILES_*`; do not run the integration test command without the launcher and count skipped server tests as passed. `-collect-test-diagnostics never` avoids diagnostic collection unrelated to this bounded test run.

The OpenSSH fixture binds loopback port 22222 (override `REMOTEFILES_TEST_PORT`), authorises only generated test keys in a temporary file, uses its own host keys/config, disables passwords/PAM, and cleans up on exit. It does not edit the Mac’s SSH configuration or existing keys. It runs under the current account, so tests intentionally touch only its generated fixture directory. Starting this fixture requires permission to run local loopback networking in restricted environments.

### Latency benchmark

Loopback has almost no latency, so it hides round-trip costs. `scripts/benchmark-latency.sh` starts the same isolated fixture and puts `scripts/latency_proxy.py`, a loopback TCP proxy that delays each direction by half the RTT, in front of it. It then times cold connect, listings, a symlink lookup, small and large reads, an unchanged reopen and a 3 MiB download. Arguments are RTT in milliseconds (default 40), per-direction Mbit/s (default 0, unlimited) and runs (default 5); each `BENCH` line reports the median and fastest run.

```sh
scripts/benchmark-latency.sh 40        # Tailscale or good Wi-Fi
scripts/benchmark-latency.sh 150 20    # cellular-like: 150 ms RTT, 20 Mbit/s
```

The proxy models fixed delay only, with no loss, jitter or reordering, and it changes no system network settings. Use it to compare revisions on the same Mac, not to predict field timings.

See [PREVIEW_STATUS.md](../PREVIEW_STATUS.md) for **actual** results and outstanding acceptance, [SSH_SPIKE.md](SSH_SPIKE.md) for the dependency decision, [RENDERER_SPIKE.md](RENDERER_SPIKE.md) for rendering evidence, and [ROADMAP.md](../ROADMAP.md) for deferred scope. Citadel is vendored from an exact upstream commit with a narrow cancellation patch and original license; see [its provenance](../Vendor/Citadel/UPSTREAM.md).

## Full acceptance

For repeatable verification of the current source, use
[scripts/test-acceptance.py](../scripts/test-acceptance.py) with an available iOS 27
Simulator and a fresh evidence directory. It records the exact source snapshot,
requires all macOS/OpenSSH, signed hosted/demo UI, actual VoiceOver and Release
compile lanes, and reports missing tests or unexpected skips as failures.
[Automated acceptance](AUTOMATED_ACCEPTANCE.md) distinguishes these results
from the physical-device and human checks that remain.

## GitHub Actions CI

[CI](https://github.com/eyeb0l/RemoteFiles/actions/workflows/ci.yml) runs on
pull requests, pushes to `main`, and manual dispatch. New commits
cancel older runs for the same pull request or branch.

The fast **Repository checks** job verifies the generated Xcode project and
runs the Python failure/cleanup regressions. **Xcode 27 acceptance** uses the
GitHub-hosted `xcode-27` image, explicitly selects Xcode 27.0, creates a disposable
iOS 27.0 simulator, and invokes the existing full acceptance runner. It requires
all macOS/OpenSSH, signed iOS core/demo UI, VoiceOver, and unsigned Release device
compile lanes. Missing tests and unexpected skips fail the run; only the existing
real-server opt-in UI tests and the physical-device Data Protection assertion may
skip on Simulator. Benchmark operations run once against the loopback fixture;
these timings do not measure network latency. No signing certificates, saved connections,
repository secrets, or real server access are required.

The Actions job summary displays the lane results; downloadable acceptance artifacts
retain logs, JSON reports and xcresult bundles for seven days, including failed
runs. Build caches, copied sources and generated SSH fixture keys are excluded.
The job has a 150-minute limit and the runner keeps its 30-minute per-command
deadline. Simulator results do not establish physical-iPhone acceptance. CI does
not change branch protection or publish app builds.

## Renderer performance

Textual is locally vendored at the original pinned revision with focused startup and reader accessibility fixes. [Provenance](../Vendor/Textual/UPSTREAM.md) records the changes and license; [performance evidence](READER_PERFORMANCE.md) records simulator and physical-iPhone measurements, tests, and remaining limits.
