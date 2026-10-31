# RSA native-paste UI-test investigation

The 31 October 2026 iPhone 17 Pro / iOS 27.2 Release failure is **not yet explained
conclusively**. The captured artifacts do not contain the generated private key or
its delivered paste string, so the failing bytes cannot be reimported off-device.
No production import, RSA validation, or user-visible UI behavior has been changed.

## Evidence and hypotheses

Both supplied xcresults show that native paste completed with a nonempty string
and validation then reported `malformedKey`. The screenshot shows the selected
source as “Private key pasted”; this does not establish byte equality. ECDSA never
ran in that failed UI journey. Successful real RSA/Ed25519 file imports establish
that those device import paths work, but do not validate this disposable RSA key.

The exact original UI-fixture conversion now lives in shared test support,
`Tests/RemoteFilesCoreTests/ImportedIdentityUIFixture.swift`. Before the paste
isolation change, a macOS Core regression passed with 32 independently generated
RSA 2048 keys and 32 ECDSA P-256 keys. For every RSA key it checked canonical
positive mpints, modulus size, matching check integers, `n = p × q`,
`q × iqmp mod p = 1`, and the private exponent against both primes. Both Citadel
and the app parser accepted the containers with matching canonical public keys.
The existing corruption and ssh-keygen interoperability tests also passed.

Remaining hypotheses, ranked for investigation rather than asserted as causes:

1. Device clipboard interference or text-provider transformation. The original
   UI test used the general clipboard with default cross-device behavior and no
   equality checks. The artifacts cannot prove or exclude a changed payload.
2. An iOS-specific SecKey export/conversion issue. Repeated macOS generation
   rules out a consistent conversion defect there, but cannot establish what
   the physical phone generated.
3. A device/Release-specific RSA importer defect for this input shape. Real RSA
   file import and macOS component checks argue against a general RSA rejection;
   they do not exclude an input-specific device defect.

The simulator baseline built the original UI test, but was interrupted before
any XCTest ran: a process sample showed Xcode blocked in CoreSimulator's
`installApplication:withOptions:installationInfo:error:`. The device-panel tool
initially reported no matching device; read-only simulator inventory confirmed
the requested iPhone Air was available and booted. No other simulator or physical
device was used. The interrupted run is not a test pass or a reproduction.

## Test isolation and diagnostics

The UI test now preflights each generated fixture through the real parser before
launching the app. A failure there isolates generation/import from paste. It writes
explicit UTF-8 text with `localOnly`, then compares the clipboard with the fixture
before and after the native paste action. Assertions never print private values.
This prevents disposable test secrets participating in Universal Clipboard and
makes a changed general clipboard fail at the source. It does not prove what a
separate app's paste callback received.

`IdentitySecKeyFixtureTests` shares the unchanged conversion code, checks the RSA
invariants above, and imports repeated fixtures. Its hosted iOS test round-trips
the local-only clipboard item through `NSItemProvider` and imports the exact
returned string. All material is generated at runtime; none is logged or committed.
These checks preserve the app's existing rejection of corrupted RSA components.

## Physical Release confirmation

With the parent's existing physical-device UDID in `PHONE_UDID`, run from this
branch (do not disable signing for a phone):

```sh
xcodebuild -project RemoteFiles.xcodeproj -scheme RemoteFiles \
  -configuration Release ENABLE_TESTABILITY=YES \
  -destination "platform=iOS,id=$PHONE_UDID" \
  -derivedDataPath /private/tmp/remotefiles-rsafix-device-dd \
  -resultBundlePath /private/tmp/remotefiles-rsafix-device-1.xcresult \
  -only-testing:RemoteFilesTests/IdentitySecKeyFixtureTests \
  -only-testing:RemoteFilesUITests/RemoteFilesUITests/testImportRSAAndECDSAKeysShowsTheirAlgorithmsAndPublicKeys \
  test
```

Use a fresh result-bundle path. The Core tests identify a generated-key or provider
failure before the UI journey. A parser-preflight failure in the UI test implicates
the fixture/importer on that phone; a clipboard assertion implicates interference.
If both pass but the app still rejects the native paste, instrument only a test
build to compare lengths/digests at the paste callback, without exposing private
text. A successful rerun alone does not prove which original hypothesis was true.
