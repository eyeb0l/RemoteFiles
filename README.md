# RemoteFiles

A native, read-only iPhone browser for a Mac’s SFTP folders and agent-produced Markdown reports. Minimum deployment target **iOS 27.0**. Open a favourite, browse a project, read a document, and refresh it after an agent changes it.

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

## Connect your Mac

Do these setup steps yourself on the Mac you intend to access. The app does not enable services, install keys, change permissions, or expose ports.

1. Enable **System Settings → General → Sharing → Remote Login** for the intended Mac account. Keep the Mac awake. The account must be able to read the chosen project directory.
2. In RemoteFiles, choose **Add Connection → Generate or Import Key**. Prefer a dedicated generated Ed25519 identity; copy/share its **public** key. Append that public key to the intended account’s `~/.ssh/authorized_keys` on the Mac (directory permission 700; file permission 600). Never copy a private key into that file.
3. If connecting away from home, install/sign in to Tailscale independently on both devices. Use the Mac’s MagicDNS hostname or Tailscale IP; ensure tailnet policy permits TCP port 22. This uses ordinary macOS OpenSSH over Tailscale, **not the separate Tailscale SSH service**. Do not forward a router port.
4. Enter the Mac account’s short username, hostname, identity and optional absolute project directory. An empty starting directory uses the server’s default directory; literal `~` is not expanded locally.
5. Verify the displayed server SHA-256 fingerprint using a trusted channel. On the Mac, the public host-key fingerprint can be inspected with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256` (choose the public file for the algorithm presented). Accept trust only when it matches.
6. Open a folder and choose **Folder actions → Add Favourite**. Open a `.md` report. Use **Rendered / Source**, **Copy Source**, and **Refresh** from its actions menu.

The first connection on a local network may require iOS Local Network permission. A timeout alone does not identify whether the Mac is asleep, the tunnel is unavailable, a permission was denied, or network policy blocked access. Check these possible causes individually. Denial and Settings recovery were verified on the physical iPhone; see [device permissions and lifecycle evidence](docs/DEVICE_PERMISSIONS_LIFECYCLE.md).

## Keys and trust

Generated Ed25519 keys and verified OpenSSH Ed25519 import formats are documented in [KEY_SUPPORT.md](docs/KEY_SUPPORT.md). Imports accept extensionless files and explicit paste. Encrypted originals remain encrypted in Keychain; an unlocked key is retained only for the foreground session. Passphrases are never persisted. Keychain uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, with synchronisation disabled. This does not imply hardware-backed Ed25519 protection.

Unknown hosts require explicit trust. Changed host keys block before account authentication. The reset flow removes trust and requires another verification; it does not silently accept the new key. A key used by a saved connection cannot be deleted.

Profiles, favourites, recent references, and public identity metadata are stored atomically in Application Support. Private material stays in Keychain. Recent files are references, not persistent offline copies. In-memory cache is bounded to ten prepared directory listings and at most four documents / 6 MiB, and cleared on memory warnings or disconnect. Returning to a cached folder preserves its scroll position without a new listing; use pull-to-refresh or **Refresh** to check for remote changes. Networking and unlocked keys are retired on backgrounding.

## Reader scope

Markdown and UTF-8 text/config/code use a 2 MiB receive-time bound and explicit empty/binary/unsupported states. Standalone JPEG, PNG, HEIC/HEIF, GIF, TIFF, WebP and BMP images open with bounded SFTP caching and downsampled display; tap for full-screen zoom and Share. Animated images show their first frame. PDFs open in a native scrolling, zoomable reader. Image/PDF transfers are capped at 128 MiB per file. Markdown images load lazily through SFTP relative to the document directory, with bounded disk/pixel caches, retry, zoom and Share. Web/file/data image URLs never load. See [remote image policy](docs/REMOTE_IMAGES.md). Only a tapped absolute HTTP/HTTPS Markdown link may open; unsafe schemes and relative links are disabled. Tables/code scroll within the rendered document. Markdown source and plain text remain read only. A failed refresh labels the previous content as previously loaded.

Source files and the Markdown **Source** tab have automatic syntax highlighting in light and dark appearances, using the filename to select the bundled grammar (including Swift, JavaScript/TypeScript, Python, JSON, YAML, shell, HTML/CSS and SQL). Plain source appears immediately; tokenization and color preparation happen off the main actor. Selection and **Copy Source** retain the original text. Unknown formats, sources above 256 KiB, and results above 16,000 tokens stay plain to bound rendering work; the existing 2 MiB text-preview limit is unchanged. The tokenizer runs locally and loads no remote scripts. Its token cache holds at most two documents within an estimated 2 MiB budget and clears on disconnect/background or memory warning. Leaving the source view cancels publication of unfinished highlighting.

## Reproducible verification

```sh
swift test                         # unit tests; real-server cases explicitly skip without a fixture
scripts/test-openssh.sh swift test  # isolated real OpenSSH fixture, generated temporary keys
scripts/test-openssh.sh xcodebuild -project RemoteFiles.xcodeproj \
  -scheme RemoteFiles -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath DerivedData -collect-test-diagnostics never \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
python3 Fixtures/generate-fixtures.py /private/tmp/remotefiles-fixtures
# Optional actual iOS VoiceOver speech/focus checks (Xcode 27, local fixtures):
scripts/test-voiceover.sh SIMULATOR_UDID /private/tmp/remotefiles-voiceover-run
```

The optional VoiceOver runner copies the project into its output directory and substitutes a local fixture entry point. It tests the current production reader/image views, records actual `XCUIVoiceOverService` utterances and screenshots, and restores the original Simulator VoiceOver enabled state after each test. Use a fresh output directory. It does not install on a physical phone or open external links. Simulator speech/focus checks do not establish touch gestures, rotor behaviour, Braille, or physical-device acceptance.

Use the signed simulator test command for the actual Keychain tests: an unsigned simulator test host returns Keychain error `-34018`. The fixture launcher forwards its environment into iOS XCTest through `TEST_RUNNER_REMOTEFILES_*`; do not run the integration test command without the launcher and count skipped server tests as passed. `-collect-test-diagnostics never` avoids diagnostic collection unrelated to this bounded test run.

The OpenSSH fixture binds loopback port 22222 (override `REMOTEFILES_TEST_PORT`), authorises only generated test keys in a temporary file, uses its own host keys/config, disables passwords/PAM, and cleans up on exit. It does not edit the Mac’s SSH configuration or existing keys. It runs under the current account, so tests intentionally touch only its generated fixture directory. Starting this fixture requires permission to run local loopback networking in restricted environments.

See [PREVIEW_STATUS.md](PREVIEW_STATUS.md) for **actual** results and outstanding acceptance, [SSH_SPIKE.md](docs/SSH_SPIKE.md) for the dependency decision, [RENDERER_SPIKE.md](docs/RENDERER_SPIKE.md) for rendering evidence, and [ROADMAP.md](ROADMAP.md) for deferred scope. Citadel is vendored from an exact upstream commit with a narrow cancellation patch and original license; see [its provenance](Vendor/Citadel/UPSTREAM.md).

## Renderer performance

Textual is locally vendored at the original pinned revision with focused startup and reader accessibility fixes. [Provenance](Vendor/Textual/UPSTREAM.md) records the changes and license; [performance evidence](docs/READER_PERFORMANCE.md) records simulator and physical-iPhone measurements, tests, and remaining limits.
