# Android playback audio report

Date: 2026-10-08  
Branch: `agent/pre-home-work`  
Starting commit: `0563998`  
Implementation commit: `8e2940e`
Lifecycle hardening commit: `6739f79`
Flutter-engine reattach commit: `6cf85c8`

## Scope and result

Playback audio capture is implemented only for the Android app on Android 10
(API 29) or newer. No Windows, Web or iOS capture path is enabled. No request
was sent to a lamp and no firmware was flashed.

The feature is compiled and unit-tested, but it has **not** been validated with
a real Android phone, a real media app or the lamp. It must not be described as
physically tested until the manual checklist below is complete.

## Architecture

- `MainActivity` owns the runtime permission and MediaProjection consent flow.
  A fresh `createScreenCaptureIntent()` is used for each new session; the token
  is not stored or reused.
- `PlaybackCaptureService` is a `mediaProjection` foreground service. It builds
  Android's official `AudioPlaybackCaptureConfiguration` and an `AudioRecord`
  at 48 kHz, PCM16, mono.
- `PlaybackCaptureBridge` sends transient PCM chunks and lifecycle state over
  an EventChannel. A MethodChannel exposes availability, start and stop.
- `AndroidPlaybackAudioSource` validates byte length, channel count and sample
  rate, then converts little-endian PCM16 to normalized Dart samples in
  `[-1, 1]`. PCM is never written to files, preferences or logs.
- `AudioFeatureProcessor` computes volume, bass, mid, treble and beat. The
  existing gain, gate, attack, release, weights and min/max controls determine
  the brightness.
- `AudioStreamCoordinator` coalesces brightness updates and never overlaps HTTP
  writes. Android capture remains alive when the Flutter tab changes and the
  foreground service supports normal app backgrounding.
- On an unexpected stop or permission revocation, the app stops producing
  packets. The firmware watchdog then fades out or starts the configured local
  fallback. An explicit user stop sends the smooth-stop command.

## Permissions and Android lifecycle

Manifest permissions:

- `RECORD_AUDIO`
- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_MEDIA_PROJECTION`
- `POST_NOTIFICATIONS`

`RECORD_AUDIO` is checked before every start. Android 13+ notification
permission is requested when missing, but its denial does not falsely grant or
block MediaProjection: Android may instead expose the foreground service only
in the system task manager. MediaProjection consent remains mandatory.

The foreground service declares `android:foregroundServiceType="mediaProjection"`
and calls `startForeground` before obtaining the projection, which satisfies
the current target-SDK requirements, including Android 14+. Projection
callbacks, explicit stop, service destruction and removal from Recents release
`AudioRecord` and MediaProjection resources.

Official platform references:

- <https://developer.android.com/media/platform/av-capture>
- <https://developer.android.com/reference/android/media/AudioPlaybackCaptureConfiguration>
- <https://developer.android.com/media/grow/media-projection>
- <https://developer.android.com/about/versions/14/changes/fgs-types-required>

## Capturable-app limits

Android captures playback only when the source app and audio usage allow it.
Apps targeting older policies, apps that explicitly disable capture, calls,
and DRM/protected media may return silence. User consent does not override the
source app's policy. The UI states this before start.

## Files changed by the implementation

- `android/app/src/main/AndroidManifest.xml`
- `android/app/src/main/kotlin/com/example/lightdome_app/MainActivity.kt`
- `android/app/src/main/kotlin/com/example/lightdome_app/PlaybackCaptureBridge.kt`
- `android/app/src/main/kotlin/com/example/lightdome_app/PlaybackCaptureService.kt`
- `lib/controllers/device_controller.dart`
- `lib/core/services/android_audio_session.dart`
- `lib/core/services/android_playback_audio_source.dart`
- `lib/core/services/audio_capture_source.dart`
- `lib/core/services/audio_stream_coordinator.dart`
- `lib/pages/tabs/audio_foundation_panel.dart`
- `lib/pages/tabs/create_page.dart`
- `test/android_playback_audio_source_test.dart`
- `test/audio_foundation_panel_test.dart`

Active product documentation was updated in `README.md`,
`docs/AUDIO_SYSTEM_FOUNDATION.md`, `docs/NEXT_STEPS.md` and
`docs/PATTERN_SYSTEM.md`. Historical review reports were left as historical
records.

No package dependency was added. The implementation uses Android and Flutter
SDK APIs already available to the project.

## Automated verification

- `flutter analyze`: passed, zero issues.
- `flutter test`: passed, 34 tests.
- PCM decoder tests: valid extrema, malformed length and invalid sample rate.
- Android source lifecycle test: availability, start, transient frame and stop.
- Availability widget test: non-Android UI exposes no start control.
- Lifecycle tests: initial stopped state, projection revocation, EventChannel
  loss, source completion and platform-stop failure all clean up once.
- `flutter build apk --debug`: passed.
- `flutter build apk --release`: passed; output
  `build/app/outputs/flutter-apk/app-release.apk` (48.1 MB).
- `flutter build web --release --no-tree-shake-icons`: passed, confirming the
  Android-only code does not break Web.
- `git diff --check`: passed.

The release build currently uses the repository's debug signing configuration;
it is suitable for private testing, not store distribution. During release
compilation the Kotlin daemon reported its known cross-drive incremental-cache
warning (`C:` Pub cache versus `J:` repository), then Gradle's fallback compiler
completed successfully.

The second-pass build used:
`C:\Users\loryc\.vscode\flutter\bin\flutter.bat`. Commands were invoked from
PowerShell with the call operator, for example
`& 'C:\Users\loryc\.vscode\flutter\bin\flutter.bat' test`.

## Lifecycle review fixes

- Native stop now marks capture as stopping, calls `AudioRecord.stop()` to
  unblock the read, waits up to one second for a different worker thread, and
  only then releases the recorder. The capture loop rechecks the stop flag
  before publishing a final chunk. A worker handling its own read error never
  attempts to join itself.
- Coordinator cleanup tolerates an already-detached platform channel and calls
  one completion callback. The Android session then discards its coordinator
  and stale feature values after normal or unexpected loss.
- Each Flutter engine receives an owner-scoped EventChannel handler. A late
  cancellation from an old engine cannot clear the sink attached by a newer
  engine. A newly attached engine immediately receives the current native
  capture status; PCM remains transient and is dropped while no sink exists.
- Availability now attaches the Dart side to the EventChannel immediately. If
  Android recreates the Flutter engine while the foreground service remains
  active, the UI reports that state and can resume processing without asking
  for a second MediaProjection consent.
- If a live Dart EventChannel ends, the source raises an audio loss so the
  coordinator stops and the firmware watchdog can take over.

## Risks still requiring a real phone

- Vendor-specific MediaProjection behavior and notification presentation.
- Whether the chosen music/video app permits playback capture.
- CPU, battery, thermal use and end-to-end latency during a long session.
- Behavior when locking/unlocking the phone and moving between Wi-Fi networks.
- Real HTTP throughput to the ESP8266 and visual smoothness of the lamp.
- Watchdog fade/fallback after force stop, permission revocation and network
  interruption.

## Manual checklist

1. Install the APK on an Android 10+ phone and connect to the same LAN as the
   lamp.
2. Connect LightDome to the lamp before opening **Audio del telefono**.
3. Tap start; grant `RECORD_AUDIO`, notification permission if requested and
   MediaProjection consent.
4. Test at least one non-DRM local player plus the intended streaming app.
5. Confirm volume, bass, mid, treble and beat indicators move plausibly.
6. Check lamp response, especially low brightness, rapid beats and silence.
7. Change gain, gate, attack, release, frequency weights and min/max while
   playing.
8. Put the app in background and lock/unlock the phone; verify notification,
   continued response and stop action.
9. Revoke sharing and verify fade/fallback. Repeat with Wi-Fi disabled and with
   the app removed from Recents.
10. Explicitly stop and verify capture, notification and lamp streaming end.
11. Run a 20-minute session and observe heat, battery, latency and disconnects.

## Rollback

Before integration, the safest rollback is to keep using commit `0563998` or
delete the separate branch. After integration, revert implementation commit
`8e2940e`, lifecycle hardening commit `6739f79`, reattach commit `6cf85c8`, and
their documentation commits together. No data migration or firmware rollback
is required because no persistent format was changed.
