# RemoteFiles preview status

**6 October 2026: audio/video previews added.** The final signed iPhone 18 Pro /
iOS 27 Simulator run passed nine playback regressions and one demo UI check,
including visible controls, refresh and fullscreen video. Nine document-policy
and seven resource-cache checks passed in an earlier focused run for this
change. MP4, MOV, M4A, MP3, WAV, FLAC, AIFF and AAC playback were exercised;
other recognized extensions depend on device codecs. A subsequent native fullscreen revision passed ten playback tests and one
demo UI check, then was installed and launched on the paired iPhone 17 Pro.
Native fullscreen interaction was verified in Simulator; broader physical-device
media acceptance remains unverified. See [audio/video scope and evidence](docs/AUDIO_VIDEO.md).

Recorded **22 September 2026**, with folder-navigation results updated **27 September 2026**. The runnable iOS 27 preview implements saved connections, dedicated SSH identities, explicit host trust, real read-only SFTP browsing, favourites, recent references, Markdown/source/plain-text and standalone image/PDF reading, refresh, cancellation, and bounded caching. **Real-server browsing, reading and changed-file refresh now pass on the physical iPhone via Tailscale. Locked-device, encrypted-key, accessibility, and broader performance checks remain outstanding.**

## Tested environment and dependency pins

- Host: macOS **27.0 (26A428)**, arm64; Xcode **27.0 (27A266a)**; Apple Swift **6.4** compiler. The app/core package uses Swift 5 language mode; Textual has its own Swift 6 package requirements.
- Simulator: **iPhone 18 Pro, iOS 27.0**, destination `E7C0844C-DA29-4328-96B7-C0ADB322D623`. The minimum deployment target remains **iOS 27.0** for app, test host, and tests.
- Independent server: system OpenSSH **10.3p1 / LibreSSL 3.3.6**, temporary loopback-only server and generated keys/fixture directory. No existing SSH keys, Remote Login settings, firewall configuration, or Tailscale configuration were changed.
- Citadel: vendored at **`ae8562f895de06ccb86fdb1cbb65fd99c8976e12`**, with two narrow connection-cancellation hooks and no cryptography/algorithm-default changes. See [source provenance](Vendor/Citadel/UPSTREAM.md) and [SSH spike](docs/SSH_SPIKE.md).
- Textual: locally vendored from **`01b51875a5406eefc95f52a058cb059e7bc94dc4`**, behind `DocumentContentView`. See [renderer spike](docs/RENDERER_SPIKE.md) and [performance patch](docs/READER_PERFORMANCE.md).
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

The following recordings predate the [performance patch](docs/READER_PERFORMANCE.md). A valid **45-second Debug Time Profiler browse/read recording** exists at `/private/tmp/remotefiles-browse-reader.trace`. Its exported potential-hangs table, `/private/tmp/remotefiles-profile-hangs.xml`, records **one 577.84 ms main-thread hang starting 1.617 seconds into the recording**. A subsequent **45-second Release recording**, `/private/tmp/remotefiles-release-journey.trace`, reproduced a **604.71 ms cold-reader main-thread hang at 12.279 seconds**; `/private/tmp/remotefiles-release-hangs.xml` contains that single event and no second event above 250 ms during the warm reopen. The Release result confirms the cold stall remains in an optimized build. It does not establish the sub-200 ms cached-display target, and the performance acceptance gate has **not passed**. The earlier 40-second `/private/tmp/remotefiles-ui-journey.trace` contains idle Home only and is not used as browse/read evidence.

Sampling during the **Debug** interval implicates **cold rendered-view and Swift type-metadata initialization**: 169 of 283 main-thread CPU samples had protocol-conformance lookup at the leaf during SwiftUI dynamic-property/view-list and text setup; 47 included Textual's first `CodeTokenizer.shared` JavaScriptCore/Prism setup; 38 included Textual block-stack layout/cache construction. Inclusive stacks overlap, so these counts must not be summed or treated as allocations of the 577.84 ms wall duration. Markdown preparation appeared on background threads before the hang; the hang's main-thread stacks contained no SFTP/authentication, Markdown-preparation, or accessibility-automation frames. The complete wall-time cause has not been isolated. Detailed sampled-stack evidence is retained at `/private/tmp/remotefiles-profile-attribution.md`; those sample counts are not a separate analysis of the Release trace.

## Outstanding acceptance and known limits

1. **Physical device:** [real-server acceptance](docs/REAL_SERVER_ACCEPTANCE.md) now verifies saved connection → real folder → rendered/source report → changed-file refresh → back via Tailscale, plus a fresh launch and actual project report. The screenshots show 5G; an independently controlled off-site run and preserved long-folder scroll position remain unverified.
2. **Device permissions/lifecycle:** denied Local Network access, Settings recovery, real SSH socket teardown in the background, and automatic foreground refetch now pass on hardware ([evidence](docs/DEVICE_PERMISSIONS_LIFECYCLE.md)). Encrypted-key and locked-device behavior remains to be checked.
3. **Reader interaction/accessibility:** verify selection/copy, Copy Source clipboard contents, independent wide regions, VoiceOver, Reduce Motion, and Reduce Transparency. Light/default and dark/accessibility-large reader configurations have been visually inspected; the full interaction and accessibility matrix remains unverified.
4. **Performance:** the [renderer patch](docs/READER_PERFORMANCE.md) moves highlighter startup off the main thread and reduced one measured simulator reader stall from 627.30 to 314.92 ms. Both physical before/after journeys recorded zero >250 ms hangs. Residual simulator runtime initialization remains; profile the representative large report and 1,000-entry directory and measure cached display. No additional >250 ms hang was recorded during the Release warm reopen, but neither the no-hitch nor sub-200 ms cached-display target is established.
5. **Real connection setup, refresh, and navigation:** setup/authentication, matching host trust, actual read/changed-file refresh, saved-connection reopen and back navigation now pass on the physical phone. Still verify previous content remaining clearly stale after a failed refresh and preserved long-folder position.
6. **Formats/scope:** Markdown SFTP images support lazy inline loading, zoom and Share ([evidence](docs/REMOTE_IMAGES.md)). Standalone images and PDFs now have native previews, with text/config/code still read as UTF-8. Relative document links, HTML, Mermaid, math, editing, uploads, original-file export, private-key export, and background transfers remain deferred in [ROADMAP.md](ROADMAP.md). The remote account itself may still have write permission; this app's operations are read only.

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

Physical-run evidence: `/private/tmp/remotefiles-physical-verified.log` and `/private/tmp/remotefiles-physical-verified.xcresult`. Visually inspected captures: [normal Home](docs/screenshots/physical-home.png), [rendered report](docs/screenshots/physical-reader.png), and [folder after back](docs/screenshots/physical-browser.png). These show actual iPhone UI, but demo content; the displayed cellular status is not proof of an SFTP connection over cellular/Tailscale. Real remote setup/connectivity remains a separate acceptance check. Subsequent hardware demo profiling is recorded in [READER_PERFORMANCE.md](docs/READER_PERFORMANCE.md).

The first physical screenshot exposed a malformed vertically stretched Add Connection action in the empty Home view. Replacing the unavailable-content action container with a bounded native stack fixed it. The final device UI test checks a visible, tappable, reasonably sized action, opens setup, and cancels successfully. Final screenshots above show the corrected build.

## Performance patch verification

The optimized patched build is installed on the physical iPhone. The final run at **14:40:42** passed **27 core and 2 UI tests**, with **5 real-server cases skipped** and zero failures. Three focused tokenizer tests passed separately. See [READER_PERFORMANCE.md](docs/READER_PERFORMANCE.md) for measured before/after results and residual performance limits.

## Real-server update

At **15:08:30**, the physical iPhone completed an actual OpenSSH/SFTP journey against this Mac over Tailscale, including independently verified host trust and changed-file refresh. At **15:10:15**, a fresh app launch reopened the saved connection and read the real performance report. Three opt-in device tests (identity preparation, real journey, saved reopen) passed, zero failures in the final runs. **My MacBook** and the project favourite remain configured. The user explicitly approved a dedicated public-key authorization restricted to read-only SFTP. See [full evidence and remaining limits](docs/REAL_SERVER_ACCEPTANCE.md).

## Remote Markdown images

The physical iPhone now displays the real Wardrobe audit screenshots using the existing SFTP transport. The audit test passed inline display, full-screen opening, pinch zoom and the Share sheet. A separate device run passed nested/duplicate references, missing-image actions and a **73.5 MB** streamed image. Core OpenSSH/resource tests: **40 passed, zero failures**. See [REMOTE_IMAGES.md](docs/REMOTE_IMAGES.md) for exact limits, policy and evidence.

## Blank rendered Markdown fix — 22 September, evening

Fixed the image integration's lazy-layout regression that left image-free text
rows at zero height. Text mounts eagerly; image I/O remains viewport-gated.
A new regression test reproduced the blank README before the fix. The installed
signed Release build passed three real-SFTP iPhone UI tests afterward: README
rendering/source/refresh, another project Markdown document, and nested/missing/
large inline images. See [details and screenshot](docs/REMOTE_IMAGES.md#text-only-rendering-regression-22-september-evening).

## Standalone formats — 24 September

Standalone JPEG/PNG/HEIC/HEIF/GIF/TIFF/WebP/BMP files now use the existing bounded SFTP resource cache and ImageIO downsampling. Tap an image for the existing full-screen zoom and Share view. PDFs use the same 128 MiB transfer cap and open in PDFKit; UTF-8 text/config/code, CSV and JSON retain the 2 MiB text-reader limit. `python3 Fixtures/generate-format-fixtures.py .test-server/remote-images` creates a tiny PNG, one-page PDF, CSV and JSON without scanning the remote directory. A signed Release UI test on the physical iPhone passed PNG display and full-screen opening, PDF page count and visible page content, and CSV reading over the saved real SFTP connection. [The PDF capture](docs/screenshots/standalone-pdf-iphone.png) was inspected visually. The full local core suite passed **41 tests, zero failures**, with **six optional real-server cases skipped**. Original-file export remains deferred.

## Folder navigation — 27 September

Code review found that returning to a folder started a new SFTP listing despite an existing directory cache. The folder initially mounted a loading/empty state, then published sorted rows, and formatted size/date metadata in row bodies during scrolling. The folder cache now holds prepared rows: ordinary return navigation mounts them immediately without a network refresh, while explicit Refresh, pull-to-refresh and foreground reconnection still fetch. Sorting and metadata preparation run off the main actor; filtering and alternate date sorting also run away from list rendering. A signed Release UI test on the physical iPhone scrolled five times in the 1,000-file demo folder, opened a report, and returned to the same visible row without a cached-folder refresh banner. This is interaction acceptance; no before/after frame-time trace was captured, so a measured frame-rate improvement is not claimed.

## Source syntax highlighting — 3 October

Code/text files and the Markdown Source tab now reuse the bundled Prism tokenizer with filename-based language selection and light/dark palettes. Source remains literal, selectable and read only. Plain text mounts immediately; tokenization, color preparation and bounded cache bookkeeping run away from the main actor. Unknown formats, files above 256 KiB and results above 16,000 tokens keep plain text. The two-document token cache has an estimated 2 MiB budget, clears with the app's disconnect/background and memory-warning handlers, and distinguishes canonically equivalent Unicode with different bytes. No new dependency or network resource loading was added.

Six focused tests passed on macOS and on the physical iPhone, covering language detection, common grammars, exact Unicode/whitespace/trailing-newline preservation, both palettes, cancellation and fallback limits. The final signed Release build passed the demo Swift-source → Copy Source action → folder → Markdown Rendered/Source/Rendered journey on the iPhone. The preceding device run also passed the 1,000-file scroll/open/back regression. [Swift source](docs/screenshots/source-syntax-swift-iphone.png) and [scrolled Markdown source](docs/screenshots/source-syntax-markdown-iphone.png) were inspected in light appearance. Dark colors were checked at the attributed-text level; native selection gestures and exact system-clipboard bytes were not separately tested in this pass. These UI tests use explicit demo content, not a new real-SFTP acceptance run.

Evidence: `/private/tmp/remotefiles-syntax-unit.log`, `/private/tmp/remotefiles-syntax-device.xcresult` (folder regression), and `/private/tmp/remotefiles-syntax-final.xcresult` (six checks and one UI test, zero failures). The verified app was then launched normally on the iPhone with saved connections.

## Download progress — 6 October

Media previews and refreshes now show actual SFTP bytes received, total size when
available, and a determinate progress bar. Unknown totals retain a byte count;
completed downloads show preparation while decoding/loading. Formatting uses
matching decimal units, such as `18.4 MB / 63.1 MB`. Observer cancellation and
request/session guards prevent old transfers from updating a replacement view.

The final iOS 27 Simulator run passed **21 checks, zero failures or skips**,
including the captured loading screen and native playback UI. One additional
isolated real OpenSSH check passed, validating live chunk counts and exact final
bytes alongside canonical-path and transfer-limit checks. The broader run also
exposed and fixed native fullscreen teardown when SwiftUI defers covered-view
updates: the coordinator observes AVPlayer current-item removal directly.

Evidence: XcodeBuildMCP result `test_sim_2026-10-06T20-41-50-842Z_pid8837_08065e24.xcresult`,
`/private/tmp/RemoteFiles-download-progress-sftp.xcresult` and the signed-device
build log `/private/tmp/RemoteFiles-download-progress-device-build.log`. The
signed Debug app was installed on the paired iPhone 17 Pro.
Launch was verified separately: the installed app was running on the iPhone
with PID 64005 and an executable path matching its new installation.
