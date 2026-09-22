# RemoteFiles preview status

Recorded **22 September 2026**. The runnable iOS 27 preview implements saved connections, dedicated SSH identities, explicit host trust, real read-only SFTP browsing, favourites, recent references, Markdown/source/plain-text reading, refresh, cancellation, and bounded in-memory caching. **The decisive physical-iPhone-over-cellular/Tailscale acceptance remains outstanding.**

## Tested environment and dependency pins

- Host: macOS **27.0 (26A428)**, arm64; Xcode **27.0 (27A266a)**; Apple Swift **6.4** compiler. The app/core package uses Swift 5 language mode; Textual has its own Swift 6 package requirements.
- Simulator: **iPhone 18 Pro, iOS 27.0**, destination `E7C0844C-DA29-4328-96B7-C0ADB322D623`. The minimum deployment target remains **iOS 27.0** for app, test host, and tests.
- Independent server: system OpenSSH **10.3p1 / LibreSSL 3.3.6**, temporary loopback-only server and generated keys/fixture directory. No existing SSH keys, Remote Login settings, firewall configuration, or Tailscale configuration were changed.
- Citadel: vendored at **`ae8562f895de06ccb86fdb1cbb65fd99c8976e12`**, with two narrow connection-cancellation hooks and no cryptography/algorithm-default changes. See [source provenance](Vendor/Citadel/UPSTREAM.md) and [SSH spike](docs/SSH_SPIKE.md).
- Textual: **`01b51875a5406eefc95f52a058cb059e7bc94dc4`**, behind `DocumentContentView`. See [renderer spike](docs/RENDERER_SPIKE.md).
- [Package.resolved](Package.resolved) and the [Xcode resolution file](RemoteFiles.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) contain matching pin arrays. Key resolved versions include NIO 2.103.0, NIOSSH fork 0.3.7, and Swift Crypto 3.15.1.

## Executed builds and tests

| Check | Actual result |
| --- | --- |
| Main app, iOS Simulator Debug | Final ad-hoc-signed build **passed** with `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` |
| Main app, iOS Simulator Release | Ad-hoc-signed optimized build **passed**, signature verification passed, and the installed Release app launched successfully |
| Main app, generic iOS device destination | Final unsigned compilation **passed** with `CODE_SIGNING_ALLOWED=NO`; no physical installation claimed |
| Final signed iOS XCTest suite | **32 tests passed, zero failures**, completed at 13:22:28; 3.187 seconds suite elapsed |
| macOS core suite | **30 tests passed, zero failures** at 13:17:04; 3.579 seconds suite elapsed |
| Two subsequently added bounded-reader tests on macOS | **2 passed, zero failures** at 13:20:11; included in the final 32-test iOS run |

The final iOS suite contains 2 bounded-reader, 7 document-policy, 5 identity/trust, 5 real SFTP integration, and 13 state/persistence tests. The small `RemoteFilesTestHost` independently links the core package for hosted tests. An earlier unsigned run could not access Keychain (`-34018`); the final signed run passed actual Keychain attribute/save/reload/delete checks. No personal development team or custom Keychain entitlement was needed for simulator signing.

The evidence produced during this run is local and temporary:

- Simulator build: `/private/tmp/remotefiles-main-signed-build.log`.
- Simulator Release build: `/private/tmp/remotefiles-release-build.log`.
- Generic device build: `/private/tmp/remotefiles-final-device-build.log`.
- Final iOS tests: `/private/tmp/remotefiles-ios-signed-tests.log` and `/private/tmp/remotefiles-ios-signed-results.xcresult`.
- macOS tests: `/private/tmp/remotefiles-core-final.log` and `/private/tmp/remotefiles-growth-tests.log`.

Exact repeatable commands are in [README.md](README.md). Running `swift test` without the OpenSSH fixture explicitly skips real-server cases; those skips do not establish SFTP success.

## What those checks establish

- Generated Ed25519 and ordinary unencrypted/default-encrypted OpenSSH Ed25519 imports authenticated and read files from the independent server. Unknown hosts and a changed fixture trust key blocked before account authentication; the fixture log contained no accepted or failed public-key offer for those attempts.
- Real-server cases covered canonical starting paths, Unicode/spaces, dotfiles, empty folders/files, 1,000 entries, a symlink, denied access, removed files, static oversized files, exact read limits, session reuse, and disconnect/reconnect. A silent TCP fixture exercised handshake cancellation, timeout, and immediate retry.
- The production bounded-read helper rejected deterministic growth beyond the receive-time limit and handled short reads and the exact-limit EOF probe. This is controlled chunk evidence; a file growing during a live OpenSSH read was not separately scheduled and verified.
- Tests covered corrupt/newer metadata failing closed without overwrite; profiles/favourites/recents surviving a fresh store instance; failed-write state; coalescing; canceled-request replacement; no work for an already-canceled caller; and retries after error/disconnect.
- Document tests covered empty/BOM/invalid-UTF-8/binary states, Markdown structural intents and task markers, image alt-text preservation with all image URLs removed, inactive HTML, and unsafe/relative link rejection. Both renderer image/emoji loaders also perform no I/O.
- Identity tests covered public-key/fingerprint representation, encrypted originals remaining encrypted in storage, missing/wrong passphrases, malformed/public-only input, deletion safeguards, trust persistence/reset, and unlocked-session clearing. macOS runs the `ssh-keygen` parser matrix; iOS runs the actual Keychain-specific case.

## Supported key matrix

| Input | Verified result |
| --- | --- |
| Generated Ed25519 | Authentication and SFTP passed |
| OpenSSH Ed25519, unencrypted | Import, authentication, and SFTP passed |
| OpenSSH Ed25519, ordinary default AES-256-CTR / bcrypt 16 | Import, authentication, and SFTP passed |
| OpenSSH Ed25519, AES-128-CTR / bcrypt 16 | Parser import passed; separate authentication not exercised |
| bcrypt 32; AES-256-CBC | Explicit unsupported-configuration rejection passed |
| Missing/wrong passphrase; public-only; malformed | Specific rejection paths passed |

The parser policy permits AES-128/256-CTR with bcrypt rounds **1–31**, but every round count has not been tested. RSA, ECDSA, security-key identities, PEM/PKCS#8, and other encryption/KDF formats are not advertised as supported. [KEY_SUPPORT.md](docs/KEY_SUPPORT.md) records the exact policy and secret lifecycle.

## Measurements and visual evidence

These samples describe their measured environment, not remote-network guarantees:

| Measurement | Environment | Result |
| --- | --- | --- |
| Cold connection/authentication | Final iOS Simulator to loopback OpenSSH | 90.4 ms |
| Cold directory, including connection | Same final simulator run | 119.6 ms |
| Warm 173,321-byte report read | Same final simulator run | 9.97 ms |
| Warm 1,000-entry directory | Same final simulator run | 598.1 ms |
| Browse/read session totals before explicit disconnect | Same final simulator run | 1 SSH authentication; 173,419 bytes; 9 read requests |
| Cold connection / cold directory | macOS loopback, 13:17:04 run | 34.0 / 53.1 ms |
| Warm report / 1,000-entry directory | Same macOS run | 4.56 / 201.1 ms |
| Prepare 191,002-byte Markdown fixture | Optimized macOS CLI, Foundation parsing plus policy formatting | 91.55 ms cold; 57.28–60.23 ms for seven subsequent runs |

The transport fixture report (173,321 bytes) and richer renderer fixture (191,002 bytes) are intentionally separate synthetic inputs. `Fixtures/generate-fixtures.py` generated the latter plus the required large-directory and edge-case data. Markdown preparation timing excludes SwiftUI layout, scrolling, display latency, and network I/O. No sub-200 ms cached-display or UI-hitch target is claimed as achieved.

The simulator was navigated through Home, Browser, Reader, and SSH Keys before the final rebuild. Screenshots were inspected for readable typography and native hierarchy:

| Home | Browser | Reader | Key setup |
| --- | --- | --- | --- |
| [Home](docs/screenshots/home.jpg) | [Browser](docs/screenshots/browser.jpg) | [Reader](docs/screenshots/reader.jpg) | [SSH Keys](docs/screenshots/key-setup.jpg) |

These screenshots show the explicit demo workspace and empty key-management entry point, not successful real-account setup. The reader capture visibly includes headings, prose, a quotation, and read-only task markers.

The **final signed simulator build** was subsequently navigated repeatedly through **Projects → Latest report symlink → rendered reader → vertical scroll → Source → Rendered**. Both a normal restart and a fresh `--demo` launch navigated successfully. An earlier transient simulator-input failure resolved without a source change.

The installed **Release** build also completed **Home → Projects → Latest report → scroll → back → warm Latest report reopen → Source**. A separate real-server UI attempt successfully generated an SSH identity and reached its saved public-key details. After relaunch, that identity remained available; Copy Public Key produced exactly the displayed Ed25519 public key in the simulator clipboard. The disposable test identity was then deleted through the confirmation flow, and the key list returned to empty. Unreliable simulator text-entry/focus automation prevented trustworthy completion of connection setup, so **UI authentication to a real server is not claimed**; the core integration tests remain the real-SFTP evidence. That attempt's temporary OpenSSH fixture was cleaned up without changing existing SSH files or settings.

The final build was also inspected in dark appearance with an accessibility-large Dynamic Type setting. Its title and body remained legible in [the dark/large reader screenshot](docs/screenshots/reader-dark-large.jpg). The simulator was restored to light appearance and its normal large text setting afterward. This verifies that specific visual configuration, not VoiceOver, selection/copy gestures, independent wide-table/code panning, or every accessibility size.

A valid **45-second Debug Time Profiler browse/read recording** exists at `/private/tmp/remotefiles-browse-reader.trace`. Its exported potential-hangs table, `/private/tmp/remotefiles-profile-hangs.xml`, records **one 577.84 ms main-thread hang starting 1.617 seconds into the recording**. A subsequent **45-second Release recording**, `/private/tmp/remotefiles-release-journey.trace`, reproduced a **604.71 ms cold-reader main-thread hang at 12.279 seconds**; `/private/tmp/remotefiles-release-hangs.xml` contains that single event and no second event above 250 ms during the warm reopen. The Release result confirms the cold stall remains in an optimized build. It does not establish the sub-200 ms cached-display target, and the performance acceptance gate has **not passed**. The earlier 40-second `/private/tmp/remotefiles-ui-journey.trace` contains idle Home only and is not used as browse/read evidence.

Sampling during the **Debug** interval implicates **cold rendered-view and Swift type-metadata initialization**: 169 of 283 main-thread CPU samples had protocol-conformance lookup at the leaf during SwiftUI dynamic-property/view-list and text setup; 47 included Textual's first `CodeTokenizer.shared` JavaScriptCore/Prism setup; 38 included Textual block-stack layout/cache construction. Inclusive stacks overlap, so these counts must not be summed or treated as allocations of the 577.84 ms wall duration. Markdown preparation appeared on background threads before the hang; the hang's main-thread stacks contained no SFTP/authentication, Markdown-preparation, or accessibility-automation frames. The complete wall-time cause has not been isolated. Detailed sampled-stack evidence is retained at `/private/tmp/remotefiles-profile-attribution.md`; those sample counts are not a separate analysis of the Release trace.

## Outstanding acceptance and known limits

1. **Physical device:** signing is now configured and the app is installed (see the update below). The physical core/UI checks pass as recorded below; still run favourite → folder → rendered report → back with preserved position → changed-file refresh over cellular with Tailscale. No physical-device, cellular, or Tailscale result is claimed.
2. **Device permissions/lifecycle:** verify denied Local Network permission and actual-network background/foreground teardown/reconnect on hardware. Unit tests establish cancellation and unlocked-cache contracts, not operating-system suspension behavior.
3. **Reader interaction/accessibility:** verify selection/copy, Copy Source clipboard contents, independent wide regions, VoiceOver, Reduce Motion, and Reduce Transparency. Light/default and dark/accessibility-large reader configurations have been visually inspected; the full interaction and accessibility matrix remains unverified.
4. **Performance:** investigate and address the approximately 0.6-second cold-reader main-thread stall reproduced in Debug and Release. Then profile the representative large report and 1,000-entry directory and measure cached display. No additional >250 ms hang was recorded during the Release warm reopen, but neither the no-hitch nor sub-200 ms cached-display target is established.
5. **Real connection setup, refresh, and navigation:** complete a real-server UI session proving connection setup/authentication, previous content remaining clearly stale after a failed refresh, and returning from a document with preserved folder position. Final-build demo navigation, source switching, scrolling, symlink opening, UI key generation, and deterministic service/state tests cover only parts of this journey.
6. **Formats/scope:** image/PDF preview, relative Markdown resources, HTML, Mermaid, math, editing, uploads, general downloads, private-key export, and background transfers remain deferred in [ROADMAP.md](ROADMAP.md). The remote account itself may still have write permission; this app's operations are read only.

The implementation is available for further profiling and device/interaction verification. The working preview has not yet passed the performance gate or the plan's decisive end-to-end acceptance.

## Physical-device signing update

On 22 September 2026, Xcode automatic signing was configured with the existing Iris Giertuga team (`359794K46A`). Xcode created an Apple Development identity and an iOS team provisioning profile. The signed Debug build and device test build passed; the final app signature passed `codesign --verify --deep --strict`. The project generator preserves the team setting for the app and test targets.

RemoteFiles was installed successfully on the paired **iPhone 17 Pro, iOS 27.0 (24A437)** with Developer Mode enabled. The first launch was blocked by the device lock. After the user unlocked it, the physical test run completed successfully at **14:10:54**: **27 core tests and 2 UI tests passed, zero failures, 5 real-server integration tests explicitly skipped** because the host-local fixture was not available to the phone. The core run includes actual device Keychain persistence/accessibility checks. The UI run completed explicit demo Home → Projects → report → Source → Rendered → Refresh → Projects → Home and checked normal Home → Add Connection → Cancel; the two UI tests took 32.027 seconds. It did not change real saved connections. RemoteFiles then launched normally on the phone without demo arguments; the empty Add Connection screen was captured and visually inspected.

Evidence: `/private/tmp/remotefiles-physical-build.log` and `/private/tmp/remotefiles-physical-test-build.log`. Repeat the device tests with the phone unlocked:

```sh
xcodebuild test-without-building -project RemoteFiles.xcodeproj \
  -scheme RemoteFiles -destination 'platform=iOS,name=Iris’ iPhone' \
  -derivedDataPath DerivedData-device -parallel-testing-enabled NO \
  -collect-test-diagnostics never
```

The existing loopback OpenSSH fixture is host-local; a hardware run without an accessible fixture must report its real-server cases as skipped, not successful.

Physical-run evidence: `/private/tmp/remotefiles-physical-verified.log` and `/private/tmp/remotefiles-physical-verified.xcresult`. Visually inspected captures: [normal Home](docs/screenshots/physical-home.png), [rendered report](docs/screenshots/physical-reader.png), and [folder after back](docs/screenshots/physical-browser.png). These show actual iPhone UI, but demo content; the displayed cellular status is not proof of an SFTP connection over cellular/Tailscale. Real remote setup/connectivity and hardware performance profiling remain separate acceptance checks.

The first physical screenshot exposed a malformed vertically stretched Add Connection action in the empty Home view. Replacing the unavailable-content action container with a bounded native stack fixed it. The final device UI test checks a visible, tappable, reasonably sized action, opens setup, and cancels successfully. Final screenshots above show the corrected build.
