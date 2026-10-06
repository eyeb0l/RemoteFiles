# Audio and video previews

RemoteFiles recognizes MP4, M4V, MOV, 3GP and 3G2 video files, and MP3,
M4A/M4B, AAC, WAV/WAVE, AIFF/AIF/AIFC, CAF, FLAC and AC3/EAC3 audio files.
Playback depends on the codecs supported by the device. A damaged file or
unsupported codec shows a retryable explanation with the option to use
**Save Original to Files** and open the file in another app. AVI, MKV, WebM and
network playlists are outside the native preview scope.

Opening a file downloads it through the existing authenticated, cancellable
SFTP resource pipeline, capped at 128 MiB per file. While downloading, a progress
bar and live received/total sizes are shown (for example, `18.4 MB / 63.1 MB`).
The sizes use decimal KB/MB/GB and a shared unit. The SFTP file handle supplies
the total; if it is unavailable or a growing file exceeds it, the UI reports only
bytes downloaded. EOF supplies the actual final size. Cache hits report completion
immediately, and the screen switches to preparing the preview after transfer.
Refreshes also show transfer progress above the previously loaded copy.
Playback starts only when
the user presses Play after the download finishes. Video renders through AVKit
and has a solid fullscreen button beside the inline playback controls, outside
the video. Fullscreen presents the native iOS AVPlayerViewController directly,
with system controls and dismissal, using the same player and playback position.
Both inline video and audio have visible Play/Pause controls and an accessible
seek bar, backed by a local AVPlayer. Audio has a filename and waveform
presentation. Refresh pauses the old copy and replaces
it only after the new file passes playback validation; failed refreshes label
the previous copy. Runtime playback failures show the same recovery guidance.

The player uses a protected temporary hard link (or copy) with the original
extension so cache eviction and refresh cannot remove its active bytes.
AVFoundation forbids every external media reference, including local reference
movies and references to web resources. There is no web player or transcoding
service. Playback and its temporary file are released when leaving the preview,
disconnecting or backgrounding. Picture in Picture and background playback are
disabled. The underlying bounded resource cache follows its existing retention
policy.

Explore Demo includes four-second synthetic MP4/H.264/AAC and M4A/AAC examples.
They were generated locally with FFmpeg (solid purple video, white rectangle,
quiet sine tones); no user content is included. Small MP3, WAV, FLAC, AIFF,
ADTS AAC and MOV variants support codec regression tests. Hosted tests exercise real AVKit
assets, seeking, cache unlinking, cancellation, damaged refreshes, runtime
failures and background cleanup. UI tests exercise both demo formats and their
visible Play/Pause controls. Physical-device codec compatibility still needs device
testing.

## Verification, 6 October 2026

On iPhone 18 Pro Simulator / iOS 27.0 with Xcode 27.0:

- Nine hosted playback tests and one demo UI test passed with zero failures or
  skips on the final implementation. The UI check opens both media previews,
  plays/pauses, refreshes and opens/dismisses fullscreen video.
- MP4/H.264, MOV/H.264, M4A/AAC, MP3, WAV/PCM, FLAC, AIFF/PCM and ADTS AAC
  decoded, sought and played. Other recognized extensions remain dependent on
  device/container/codec compatibility; they were not separately decoded.
- Nine document-policy and seven resource-cache tests also passed in this
  change's earlier focused run. The final playback changes do not alter either
  policy or the resource resolver.
- The signed Debug app compiled and launched in Simulator. No physical-device
  install, playback or network acceptance is claimed for this feature.

Final media evidence: `test_sim_2026-10-06T19-18-47-805Z_pid8837_be5413d9.xcresult`
under the XcodeBuildMCP `RemoteFiles-4cb9c1492648/result-bundles` workspace.


## Native fullscreen update, 6 October 2026

The fullscreen action now uses an opaque system-colored button beside Play/Pause,
outside the image. It presents the native iOS AVPlayerViewController directly,
with system playback, seeking, speed, mute and dismissal controls. The custom
fullscreen layout has been removed. Returning restores the inline video display;
the player, playback position and paused/playing state are retained.

Ten hosted playback tests and the demo UI test passed (11 total, no failures or
skips), including direct native-controller presentation, retained playback
position, Close and reopening, and dismissal when the playback session stops.
Captured screenshots confirm the button placement and native fullscreen chrome.
The signed iOS device build passed with a valid code signature. The revision
was installed on the paired iPhone 17 Pro / iOS 27.0 and its launch was verified.
Native fullscreen interaction was exercised in Simulator.

Result bundle: `test_sim_2026-10-06T20-27-34-513Z_pid8837_225407e8.xcresult` in the
same XcodeBuildMCP result-bundles workspace as above.

## Download progress update, 6 October 2026

Chunk progress propagates through the file-service adapter and coalesced resource
resolver to each active consumer. Cancellation removes its progress observer;
retired transfers cannot update a replacement request. Existing size limits,
canonical path checks and local-file cleanup remain in the streaming path.
The demo streams its synthetic bytes in chunks to exercise the visible loading state.

The broader regression run caught an intermittent native fullscreen teardown
failure while SwiftUI deferred updates to the covered inline view. The native
presentation coordinator now observes removal of the player's current item and
dismisses its AVKit controller directly when playback stops.

The final Simulator run passed 21 tests with no failures or skips: 11 hosted
playback/loading checks, nine resource/formatting/cache/cancellation checks and
the demo audio/video UI journey. The loading screenshot was inspected for the
size pair, progress bar and legible caption.
Result: `test_sim_2026-10-06T20-41-50-842Z_pid8837_08065e24.xcresult` in the same
XcodeBuildMCP workspace above.

The isolated real OpenSSH streaming check also passed, verifying multiple live
chunk updates, monotonic byte counts and the exact final 3 MiB file size, with
canonical-root and size-limit rejection retained. Evidence:
`/private/tmp/RemoteFiles-download-progress-sftp.xcresult`. The signed device
build passed signature verification and was installed on the paired iPhone 17 Pro.
Launch was verified separately: the installed app was running on the iPhone
with PID 64005 and an executable path matching its new installation.
