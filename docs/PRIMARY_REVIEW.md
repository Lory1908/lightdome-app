# Primary review of `agent/pre-home-work`

Review date: 2026-10-08

The agent branch was compared with its base commit `9028953`. The original
branch was not modified and no device operation was performed.

## Corrections applied after review

- Turning autorun off while replacing the active autorun pattern now removes
  its persisted boot selection. A different autorun pattern is preserved.
- Changing a recipe type while editing no longer displays a different filename
  from the file that will actually be replaced.
- Volume, bass, mid and treble weights plus beat boost now contribute to the
  computed light intensity; the original implementation only used volume.
- Audio level transport now serializes requests and coalesces pending frames so
  a fast capture source cannot create overlapping HTTP writes to the ESP8266.
- Explicit non-audio firmware actions disarm the audio watchdog before taking
  control of the light.

## Independently repeated verification

- Flutter static analysis: passed with no issues.
- Flutter tests: 25 passed.
- LLM authoring Python tests: 4 passed.
- ESP8266 PlatformIO build: passed; RAM 68.7%, flash 41.2%.
- Git whitespace validation: passed.

## Intentionally still incomplete

- Windows WASAPI loopback capture is not implemented; the system-audio button
  remains disabled and says so explicitly.
- Browser system/tab audio capture is not implemented.
- Lamp, low-brightness, 150/250/300 Hz, autonomous playback, watchdog fallback
  and iPhone Safari behavior still require their documented physical checks.
