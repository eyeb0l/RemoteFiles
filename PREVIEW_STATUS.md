# RemoteFiles preview status

This is a dated record of feature work and validation, not a live test dashboard. Each result applies to the build, environment and date described with it; an installation or Simulator pass does not establish later physical-device acceptance. For current behavior, start with the [documentation index](docs/README.md). For checks still to perform, see [manual acceptance](docs/MANUAL_ACCEPTANCE.md) and the [roadmap](ROADMAP.md).

**25 October 2026: offline folders and document links.**

Individual files and complete folder trees can be kept in a protected, device-local Offline library with explicit updates/removal and saved dates. Folder snapshots preserve subfolders and empty directories, offer a hidden-file choice, and skip symbolic links and special files. Failed or cancelled updates keep the previous complete snapshot. The library is bounded to 32 folders, 100 files, 128 MiB per original and 512 MiB of committed originals, and Demo is isolated.

Relative Markdown links open saved documents locally, including heading fragments. Folder links stay within their own snapshot; individually saved documents link to other individual copies from the same saved connection route. Missing or excluded targets explain how to save them without starting SFTP. Local readers and original sharing use verified leases. Synchronization and external Markdown resources remain deferred. See [offline files and folders](docs/OFFLINE_FILES.md), including synthetic iPhone/iPad screenshots and the distinction between simulator checks and physical locked-device acceptance.

Local verification passed 43 focused offline/document-navigation tests on macOS and in the signed iOS test host, three offline UI journeys on both iPhone and iPad Simulators, two existing connected-link UI journeys on iPhone, and 38 Python repository checks. The final signed Simulator build, generated-project consistency and whitespace checks passed. Physical locked-device and real-server offline acceptance remain separate.

**22 October 2026: jump-host connections and iPad workspace.**

Connections can use one SSH bastion with separate identities and host-key verification. Regular-width iPad windows show the library, folder and reader together; iPhone keeps stack navigation. Route changes isolate resource caches, and editing/deleting the visible connection clears old routes. See [jump hosts](docs/JUMP_HOSTS.md) and [iPad workspace](docs/IPAD.md), including simulator screenshots. Local verification covered two-server OpenSSH, hosted core tests, full iPhone UI, focused iPhone/iPad lifecycle and form checks, VoiceOver and unsigned Release compilation. Two VoiceOver cases required isolated fixture state; the fresh-simulator speech-service limitation and retained rerun evidence are recorded in the PR. Physical iPad/windowing and production-bastion acceptance are not claimed.

**21 October 2026: RSA and ECDSA OpenSSH identity imports.**

RSA (2048–8192 bits) and ECDSA (P-256/P-384/P-521) now work with encrypted or unencrypted imports, passphrase unlock, optional biometric copies and explicit public-key installation. RSA authentication uses SHA-512/SHA-256. Independent OpenSSH tests passed on macOS and hosted iOS, including a SHA-256-only RSA server configuration on macOS. UI acceptance covers RSA and P-256 imports through the native paste control. See [key support](docs/KEY_SUPPORT.md) for the permitted and tested matrix. This update has not been installed or accepted on a physical device.


## Key export, rich Markdown and managed downloads — 29 October

Implemented private-key export with explicit acknowledgement and device-owner authentication, preserving encrypted imported originals; opt-in public-key installation during direct connection setup; offline Mermaid, KaTeX mathematical notation and semantic HTML in Markdown; and a persistent download queue with iOS continued-processing support. Standalone HTML remains a separate static preview. See [SSH keys](docs/KEY_SUPPORT.md), [installation](docs/PUBLIC_KEY_INSTALLATION.md), [rich Markdown](docs/MARKDOWN_RENDERING.md) and [downloads](docs/DOWNLOADS.md).

Validation in this worktree on 29 October:

- The complete macOS package suite with isolated OpenSSH fixtures passed **282 tests, zero failures, one optional skip**. It includes actual SSH authentication and confined original-byte downloads. Log: `/private/tmp/remotefiles-opus-fixes-openssh.log`.
- Focused hosted tests on a separate **iPhone 18 Pro simulator, iOS 27.2** passed **73 tests, zero failures, four existing opt-in/device-only skips**. Coverage includes rendered Mermaid SVG geometry, native MathML, static HTML, hostile-script/resource blocking, links/images, persistent downloads, cancellation, per-window credentials and lifecycle, key-install completion callbacks, byte-progress idle deadlines, deferred protection, live Dynamic Type and private-key export file wrappers. Evidence: `/private/tmp/remotefiles-opus-fixes-hosted.xcresult` and `.log`.
- The four hosted skips require simulated Face ID interaction, enrollment-change setup, or physical Data Protection reporting. They are unchanged existing tests. A first run on the shared simulator was disrupted by a concurrent worktree's tests; the successful run used a separate simulator. The HTML security assertion was corrected to scope forbidden document elements to the rendered document, excluding the app-owned stylesheet.
- The ad-hoc-signed Simulator app build passed; `codesign --verify --deep --strict` passed and the built Info.plist contains the download-task wildcard and processing mode. Build log: `/private/tmp/remotefiles-export-fix-build.log`.
- Manual simulator checks passed acknowledgement → simulated Face ID → native Files export with a disposable generated key, install-on-save review with immutable server fields and cancellation, rich Markdown rendering/HTML details/live accessibility text size, and demo download completion/Files picker. The export journey exposed a missing required file-wrapper attribute; the fix passed the repeated journey and a new hosted regression test. [Export](docs/screenshots/managed-features/key-export.png), [Files picker](docs/screenshots/managed-features/key-files-picker.png), [installation](docs/screenshots/managed-features/install-on-save.png), [rich Markdown](docs/screenshots/managed-features/rich-markdown.png), [accessibility size](docs/screenshots/managed-features/rich-markdown-accessibility.png) and [Downloads](docs/screenshots/managed-features/downloads.png) screenshots were visually inspected.
- **39 repository runner/scope tests passed**, bundled renderer distribution hashes matched their provenance, and local documentation targets and `git diff --check` passed.
- PR review follow-up: a hosted regression reproduced display math splitting prose and leaving literal dollar delimiters. Restricting the block-start hint to complete blocks on new lines fixed it; all **nine rich Markdown hosted checks passed**, including surrounding prose, code spans, multiple expressions and standalone display blocks. Evidence: `/private/tmp/remotefiles-pr39-math-before.xcresult` (reproduction) and `/private/tmp/remotefiles-pr39-math-after.xcresult` (passing suite).

Generated private-key exports are unencrypted; imported encryption remains intact. Downloads are bounded to 128 MiB/file and 512 MiB total, restart interrupted files from byte zero, and remain subject to iOS resource decisions and a 60-second network-inactivity deadline. Managed transfers can exceed three minutes while bytes continue arriving; previews/one-off exports keep their existing total deadline. Locked completion retains validated bytes pending final protection; a failed protected manifest write still needs unlock before that state is durable. Physical-device authentication/Files behavior, background processing admission, locking and system cancellation still need acceptance. No production installation or physical-device result is claimed.

## Earlier validation snapshots

The sections below preserve historical observations. Statements such as “now” and “current” refer to the dated work in each section; later features and results may supersede them. Paths under `/private/tmp` were local evidence at the time and may no longer exist.

**17 October 2026: reader navigation, saved positions, scoped refresh and runner fixes.**

- Both Python UI runners now preserve failure status, attempt all cleanup/integrity checks, save their summary and return a nonzero exit code on failure. Four regression tests inject runner success, failure, timeout, mutation and cleanup errors.
- Document refresh invalidates only its old/new image references and corresponding decoded images. Unrelated cached resources and in-flight work survive; superseded downloads cannot overwrite newer cached bytes.
- Document actions now offer local Find with highlighting and next/previous navigation, plus a Markdown heading list. Same-document and relative-file heading links work. Find also reveals offscreen code/table matches. Prepared attributed text updates retain the renderer's native views.
- Text readers save independent Rendered and Source coordinates across launches for the exact connection, path and UTF-8 content revision. Changed text starts at the top; demo mode writes no reading history. Positions remain layout-dependent coordinates, so changes in screen width or text size can alter their meaning.

Current validation: **118 macOS core tests**, **177 signed hosted iOS tests**, **4 end-to-end reader UI tests** and **4 Python runner tests passed**, with no failures. Both Swift suites used the isolated loopback OpenSSH fixture, with no skipped server tests. The final unsigned generic iOS **Release build passed**.

Local evidence: `/private/tmp/remotefiles-batch-prepared-core.log`, `/private/tmp/remotefiles-batch-prepared-final.log`, `/private/tmp/remotefiles-batch-prepared-final.xcresult` and `/private/tmp/remotefiles-batch-prepared-device-build.log`. The combined iOS run includes all hosted tests and four reader UI journeys. Earlier failed runs led to fixes for cold restoration, horizontal Source Find and preserving offscreen code containers on attributed-content updates; the final combined hosted/UI run passed with no failures.

The latest working tree was subsequently rebuilt as a signed **Release** app, passed `codesign --verify --deep --strict`, and was installed on the paired physical **iPhone 17 Pro, iOS 27.0.1**. CoreDevice confirmed a foreground launch of `dev.iris.RemoteFiles`; a later process query confirmed **PID 48826**, with its executable inside the newly installed bundle. Build, signature, installation, launch and continuing process presence were verified separately. Find, heading navigation and cross-launch reading-position behavior still await hands-on physical-device acceptance; their automated checks above ran in Simulator. No new runtime performance profile was captured.

Device-deployment evidence: `/private/tmp/remotefiles-20261017-iphone-build.log`, `/private/tmp/remotefiles-20261017-iphone-install.json`, `/private/tmp/remotefiles-20261017-iphone-app.json`, `/private/tmp/remotefiles-20261017-iphone-launch.json` and `/private/tmp/remotefiles-20261017-iphone-processes.json`. The signed executable SHA-256 was `fa4f47027be4f47e4fbb1d14300e34f78fb368afcaab5307c585d042a3100567`.

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
- Citadel: vendored at **`ae8562f895de06ccb86fdb1cbb65fd99c8976e12`**, with connection/exec cancellation hooks, authentication and key-import changes, and bounded SFTP handling. See [source provenance](Vendor/Citadel/UPSTREAM.md), [SSH spike](docs/SSH_SPIKE.md), and the [upstream release gate](docs/CITADEL_UPSTREAM.md).
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

Exact repeatable commands are in [Build and test](docs/DEVELOPMENT.md#reproducible-verification). Running `swift test` without the OpenSSH fixture explicitly skips real-server cases; those skips do not establish SFTP success.

## What those checks establish

- Generated Ed25519 and ordinary unencrypted/default-encrypted OpenSSH Ed25519 imports authenticated and read files from the independent server. Unknown hosts and a changed fixture trust key blocked before account authentication; the fixture log contained no accepted or failed public-key offer for those attempts.
- Real-server cases covered canonical starting paths, Unicode/spaces, dotfiles, empty folders/files, 1,000 entries, a symlink, denied access, removed files, static oversized files, exact read limits, session reuse, and disconnect/reconnect. A silent TCP fixture exercised handshake cancellation, timeout, and immediate retry.
- The production bounded-read helper rejected deterministic growth beyond the receive-time limit and handled short reads and the exact-limit EOF probe. This is controlled chunk evidence; a file growing during a live OpenSSH read was not separately scheduled and verified.
- Tests covered corrupt/newer metadata failing closed without overwrite; profiles/favourites/recents surviving a fresh store instance; failed-write state; coalescing; canceled-request replacement; no work for an already-canceled caller; and retries after error/disconnect.
- Document tests covered empty/BOM/invalid-UTF-8/binary states, Markdown structural intents and task markers, image alt-text preservation with all image URLs removed, inactive HTML, and unsafe/relative link rejection. Both renderer image/emoji loaders also perform no I/O.
- Identity tests covered public-key/fingerprint representation, encrypted originals remaining encrypted in storage, missing/wrong passphrases, malformed/public-only input, deletion safeguards, trust persistence/reset, and unlocked-session clearing. macOS runs the `ssh-keygen` parser matrix; iOS runs the actual Keychain-specific case.

## Initial key matrix

| Input | Verified result |
| --- | --- |
| Generated Ed25519 | Authentication and SFTP passed |
| OpenSSH Ed25519, unencrypted | Import, authentication, and SFTP passed |
| OpenSSH Ed25519, ordinary default AES-256-CTR / bcrypt 16 | Import, authentication, and SFTP passed |
| OpenSSH Ed25519, AES-128-CTR / bcrypt 16 | Parser import passed; separate authentication not exercised |
| bcrypt 32; AES-256-CBC | Explicit unsupported-configuration rejection passed |
| Missing/wrong passphrase; public-only; malformed | Specific rejection paths passed |

This initial matrix covered Ed25519. RSA and ECDSA support was added on 21 October; security-key identities, PEM/PKCS#8 and other encryption/KDF formats remain unsupported. The parser permits AES-128/256-CTR with bcrypt rounds **1–31**, but every round count has not been tested. [KEY_SUPPORT.md](docs/KEY_SUPPORT.md) records the exact policy and secret lifecycle.

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

## Static HTML Rendered/Source — 6 October

HTML and HTM now have Rendered and Source modes. Rendered uses an ephemeral
WebKit document for static structure and inline CSS; scripts and automatic
resource loads remain disabled, matching the user's selected static-preview scope.
Source retains highlighting, selection, Copy Source and original export. Empty
script-driven app entries show an explanation instead of a blank success state.
The existing UTF-8 validation and 2 MiB document bound remain in force.

The final code passed 17 unique focused Simulator checks across the final
combined run (15 passes) and two clean reruns after a Simulator shutdown/stall.
Checks covered HTML classification/source preservation, styled DOM and pixels,
inactive scripts/resources, empty React-style entries, existing bounded-source
and SVG behavior, and Rendered → Source → Copy Source → Rendered → Refresh.
Both demo screenshots were inspected. See [HTML preview evidence](docs/HTML_PREVIEWS.md).

The signed Debug build passed signature verification, was installed on the
paired iPhone 17 Pro, and launched normally. A separate process check confirmed
PID 64188 running from the new app bundle. Device evidence is in
`/private/tmp/RemoteFiles-html-device-build.log` and the corresponding
`RemoteFiles-html-install.json`, `RemoteFiles-html-launch.json` and
`RemoteFiles-html-processes.json` files. HTML interaction was verified in
Simulator; physical-device HTML interaction was not separately exercised.
