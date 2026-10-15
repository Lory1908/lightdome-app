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

## Software required on the new Windows PC

### Agent access

- Codex Desktop or Codex CLI, signed in and allowed to access the local clone.
- GitHub authentication for `Lory1908/lightdome-app` if the repository is
  private. Git Credential Manager or GitHub CLI are both suitable.
- Give the agent this file as its first project context, together with the
  repository `AGENTS.md` and machine-level workspace instructions when present.

### Essential for the Flutter Android/Web app

- **Git 2.x**. The verified machine uses Git `2.52.0.windows.1`.
- **Flutter stable 3.35.7**, which includes **Dart 3.9.2**. Add
  `flutter\bin` to `PATH`; the project requires Dart `^3.9.2`.
- **JDK 21 LTS**. Point Flutter at it with
  `flutter config --jdk-dir="C:\path\to\jdk-21"`. The verified Android build
  uses JDK 21 even if another Java version is the shell default.
- **Android SDK** with command-line tools, Platform `android-36`, Build Tools
  `36.1.0` and Platform Tools/ADB. Android Studio is optional if these are
  installed separately.
- Accept the Android SDK licences with `flutter doctor --android-licenses`.
- **Microsoft Edge or Google Chrome** for Flutter Web testing. Edge is enough;
  Visual Studio C++ components are not required because Windows desktop builds
  are outside this project's scope.

Recommended editor setup: VS Code with the Flutter, Dart and PlatformIO IDE
extensions. The editor is optional for an agent that can call the command-line
tools directly.

### Essential for the ESP8266 board

- **PlatformIO Core 6.2.x**, either through the PlatformIO IDE extension or its
  own Python environment. The repository pins Espressif8266 platform `4.2.1`,
  NodeMCU v2 and ArduinoJson `7.4.2`; PlatformIO downloads those dependencies.
- **FTDI VCP USB driver** for the currently connected adapter
  (`VID:PID 0403:6001`). It appeared as `COM4` on the original PC, but the port
  number is not portable. If final hardware uses a CH340 or CP210x adapter,
  install that adapter's driver instead.
- A data-capable USB cable. Serial monitor speed is `115200`.

### Phone connection

- Android Platform Tools provide `adb`.
- For wireless debugging, pair the new PC once with `adb pair IP:PAIR_PORT`,
  then use `adb connect IP:DEBUG_PORT`. Android may change the debug port.
- For USB debugging on the Galaxy phone, install Samsung's USB driver if
  Windows does not expose the device to ADB.

### Remote hardware bridge (verified 2026-10-15)

- The university laptop is reachable over Tailscale through the SSH alias
  `lory-portable` as Windows user `loryc`.
- Its Windows Mobile Hotspot uses `192.168.137.0/24`.
- The ESP resolves as `lightdome.local`, was observed at `192.168.137.79` and
  later `192.168.137.223`, and its embedded web UI answered over HTTP. Treat
  the numeric address as dynamic.
- The ESP FTDI adapter (`VID:PID 0403:6001`) is exposed on the laptop as
  `COM5`. Re-discover the port before every upload instead of assuming it.
- The Galaxy Z Flip8 was observed at `192.168.137.118`. Android wireless-debug
  ports are temporary; read the current IP and port from Developer options.
- The desktop's existing ADB identity can reach the phone through a local SSH
  port forward to the laptop, so installing ADB on the laptop is optional.
- Tailscale does not directly route the hotspot subnet. Run ESP/serial commands
  on the laptop over SSH, or use an explicit SSH port forward.
- Never store pairing codes, private keys or Wi-Fi credentials in this repo.

### Verification commands

```powershell
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter build apk --release
flutter build web

pio --version
pio run -d firmware
pio device list
pio run -d firmware -t upload --upload-port COM4
pio device monitor -p COM4 -b 115200
```

Replace `COM4` with the port discovered on the new PC. Do not upload firmware
until the current board has been identified and the build succeeds.

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
- At boot the firmware waits 8 seconds for the saved Wi-Fi, then starts
  `LightDome-Setup`. The setup portal was physically observed 8.45 seconds
  after reset on 2026-10-15. A Wi-Fi loss after boot currently retries
  indefinitely and does not automatically reopen the setup AP.
- Android Wi-Fi provisioning now sends a fixed-length JSON request because the
  ESP8266 server does not reliably parse chunked request bodies. Scanning and
  saving credentials from the release app were physically verified on
  2026-10-15; the board rebooted and rejoined `LORY-PORTABLE` successfully.
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
