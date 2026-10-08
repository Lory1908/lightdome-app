# LightDome firmware

Baseline firmware for the NodeMCU V3 ESP8266 ESP-12E. PlatformIO target:
`nodemcuv2`. The single PWM output is D5/GPIO14.

## Local development

From the repository root:

```text
pio run -d firmware -e nodemcuv2
pio device monitor -d firmware -b 115200
```

The future upload command must provide the serial port explicitly, for example:

```text
pio run -d firmware -e nodemcuv2 -t upload --upload-port COM4
```

Do not commit Wi-Fi credentials, OTA passwords, or other secrets. Credentials
are configured through the `LightDome-Setup` captive portal or the Flutter Wi-Fi
setup and kept on the ESP8266 LittleFS (never shipped in the firmware image).
ArduinoOTA and HTTP OTA are disabled.

## Programs

Programs are stored on LittleFS as `.ldy` files. A valid file contains the
existing `LDY1` header followed by exactly `frames` little-endian `uint16_t`
samples and optional trailing JSON recipe metadata (at most 2048 bytes, length
stored in the 12-byte header); legacy files have metadata length 0. The header
sample rate and frame count must both be greater than zero.
Program names are limited to 48 ASCII letters, numbers, `-`, and `_`.
Program endpoints return HTTP 503 when LittleFS cannot be mounted. Uploads are
received into a temporary file, validated, and then atomically promoted to the
program path. Autorun metadata is written only after a valid program is saved.

`GET /api/state` keeps `brightness` as the current output level on the legacy
0..255 scale. It also exposes the master limiter explicitly as
`brightnessMaster` (0..1) and `brightnessPct` (0..100), together with `gamma`,
so clients do not have to overload the legacy field.

## Optional audio watchdog

Only `GET /set?y=..&audio=1` arms the loss-of-audio watchdog; ordinary `/set`
clients are unchanged. After 1200 ms without marked audio frames, the lamp
fades to zero over 350 ms or starts a configured saved fallback. Configure with
`POST /audio/config` (JSON `{"fallback":null}` or a valid stored pattern name).
The state API additionally reports `audioStreamActive` and `audioFallback`.
See `docs/AUDIO_WATCHDOG.md` for behavior, limitations, and pending hardware
checks. This firmware feature is only compiled, not validated on the lamp.
