# Physical-device acceptance still required

Use a dedicated authorised test directory and the normal Mac account’s Remote Login service. Never rotate the real Mac’s host keys for testing. The independent OpenSSH fixture covers changed trust without doing that.

1. In Xcode choose your signing team, run on an iPhone with iOS 27, and add the dedicated app key’s public key to the Mac account.
2. Enable existing Tailscale on both devices. On iPhone disable Wi-Fi and use cellular. Open a saved favourite directly, verify the host fingerprint, browse, and open a real agent Markdown report.
3. Scroll the folder first; open/back from a report and confirm the folder position. Change the report in the approved Mac test directory, refresh in the reader, and confirm new content. Interrupt the network during another refresh and confirm the previous copy remains clearly labelled.
4. Verify encrypted-key unlock, cancel/swipe-dismiss, background/foreground reconnect, no passphrase persistence, and keychain availability after locking/unlocking the device. Trust a fixture, deliberately change only that fixture's server key, and confirm the connection is blocked before account authentication.
5. On local Wi-Fi deny Local Network permission, confirm a useful failure state and navigable UI, then grant permission in Settings and retry. A timeout must not be described as a proven Tailscale/sleep/firewall diagnosis.
6. Check light/dark appearance, accessibility Dynamic Type, VoiceOver reading/focus, Reduce Motion and Reduce Transparency. Long-press to select/copy rendered text and source. Pan a wide code block/table horizontally without widening the overall document.
7. Profile a 1,000-entry folder and the generated 191,002-byte report on the device using Instruments SwiftUI / Animation Hitches. Record cold/warm timings, main-thread hitches and memory; do not interpret Simulator/loopback times as cellular performance.

The app has no background modes and makes no promise of keeping SSH open while suspended. Complete this journey before describing the preview as physically verified.
