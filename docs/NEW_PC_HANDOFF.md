# LightDome handoff to another PC

Updated: 2026-10-15

## Source of truth

- Repository: `https://github.com/Lory1908/lightdome-app.git`
- Active branch: `agent/pre-home-work`
- Latest implementation checkpoint: `3e84a58`

Clone and select the checkpoint branch:

```powershell
git clone https://github.com/Lory1908/lightdome-app.git
Set-Location lightdome-app
git switch agent/pre-home-work
flutter pub get
flutter analyze
flutter test
```

## Verified state

- Flutter analysis is clean and all 40 automated tests pass.
- Manual light control, low brightness, autonomous `respiro`, Android playback
  capture, smooth audio response and recovery after a temporary Wi-Fi loss were
  physically verified.
- Automatic audio response distinguishes continuous music from a sparse
  metronome. Fine tuning is intentionally deferred until the final lamp
  hardware.
- ESP8266 firmware, web UI, Wi-Fi setup portal and Android source are all in
  this repository.

## Latest microphone change

Commit `3e84a58` replaces temporary WAV recording with low-latency PCM
streaming, routes microphone levels through the same paced path as phone audio,
adds clear listening/idle feedback, explains every control and provides a
recommended-values reset.

The release APK was built successfully, but it was not installed after this
last UI change because wireless ADB disconnected. First action on the new PC:

1. enable Android wireless debugging or attach the phone by USB;
2. build/install the release APK;
3. physically verify microphone start/stop, feedback, reset and Apply changes.

## Hardware and remaining work

- The ESP8266 appeared on the original PC as an FTDI USB serial device on
  `COM4`. The port number may differ on another PC.
- At boot the firmware waits 15 seconds for the saved Wi-Fi, then starts
  `LightDome-Setup`. A Wi-Fi loss after boot currently retries indefinitely and
  does not automatically reopen the setup AP.
- Next physical tasks: VLC lock/unlock test, 20-minute Android session,
  150/250/300 Hz PWM comparison, then optional UDP low-latency transport.
- Final release tasks still need the chosen Android application id and signing
  credentials, iPhone Safari/PWA validation, and an authenticated firmware
  update/recovery design.

## Intentionally excluded from Git

- Wi-Fi passwords and saved device credentials.
- Android signing keys and other secrets.
- Build caches, temporary audio data and local runtime logs.
- Locally archived APKs. They can be rebuilt from the tagged commit; publish a
  GitHub prerelease asset when a build has passed its final physical test.
