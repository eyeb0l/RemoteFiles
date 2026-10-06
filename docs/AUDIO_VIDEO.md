# Audio and video previews

RemoteFiles recognizes MP4, M4V, MOV, 3GP and 3G2 video files, and MP3,
M4A/M4B, AAC, WAV/WAVE, AIFF/AIF/AIFC, CAF, FLAC and AC3/EAC3 audio files.
Playback depends on the codecs supported by the device. A damaged file or
unsupported codec shows a retryable explanation with the option to use
**Save Original to Files** and open the file in another app. AVI, MKV, WebM and
network playlists are outside the native preview scope.

Opening a file downloads it through the existing authenticated, cancellable
SFTP resource pipeline, capped at 128 MiB per file. Playback starts only when
the user presses Play after the download finishes. Video renders through AVKit
and has an explicit fullscreen action. Both video
and audio have visible Play/Pause controls and an accessible seek bar, backed
by a local AVPlayer. Audio has a filename and waveform presentation. Refresh pauses the old copy and replaces
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
