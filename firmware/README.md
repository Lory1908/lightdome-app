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

Do not commit Wi-Fi credentials, OTA passwords, or other secrets. The current
baseline has empty station credentials and uses the generic `LightDome-Setup`
open development AP when no station credentials are configured. Definitive
provisioning is not implemented yet; WiFiManager and captive portal work are
reserved for a later phase. ArduinoOTA and HTTP OTA are disabled.

## Programs

Programs are stored on LittleFS as `.ldy` files. A valid file contains the
existing `LDY1` header followed by exactly `frames` little-endian `uint16_t`
samples; the header sample rate and frame count must both be greater than zero.
Program names are limited to 48 ASCII letters, numbers, `-`, and `_`.
Program endpoints return HTTP 503 when LittleFS cannot be mounted. Uploads are
received into a temporary file, validated, and then atomically promoted to the
program path. Autorun metadata is written only after a valid program is saved.

`GET /api/state` keeps `brightness` as the current output level on the legacy
0..255 scale. It also exposes the master limiter explicitly as
`brightnessMaster` (0..1) and `brightnessPct` (0..100), together with `gamma`,
so clients do not have to overload the legacy field.
