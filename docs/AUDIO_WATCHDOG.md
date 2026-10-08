# Audio watchdog (firmware additive)

Firmware protocol, pending physical validation:

- Legacy `GET /set?y=0..1023` is unchanged and **does not arm** audio timeout.
- Audio frames: `GET /set?y=0..1023&smooth=90&audio=1`. This opt-in tag arms/refreshed the watchdog on each frame.
- `POST /audio/config` JSON `{"fallback":null}` (default: fade to 0) or `{"fallback":"stored_name"}` (must exist and pass the usual name validation). Configuration is RAM-only; no secrets or flash wear.
- If **1200 ms** pass without an audio frame, the firmware disarms audio and either starts the selected stored pattern, or fades from the last level to zero over **350 ms**. It never indefinitely keeps the final audio level.
- Normal stream stop: send `/set?y=0&smooth=350` (without `audio=1`), or start an approved saved fallback. For crashes/disconnections, the firmware watchdog provides the emergency behavior.
- `GET /api/state` adds `audioStreamActive` (boolean) and `audioFallback` (string), retaining existing fields.
- On Android 10+, `AudioStreamCoordinator` dispatches intensities produced by
  the native playback-capture provider. It coalesces frames, serializes HTTP
  writes and leaves unexpected loss to this watchdog. An explicit user stop
  sends the normal smooth-stop command. Web, iOS and desktop do not expose an
  audio-capture start action.
- The configuration is deliberately not persisted over reboots; there is no automatic audio mode at boot.
- Any old Flutter/app/web client still uses legacy `/set`, with unchanged semantics.

Not yet verified physically: flash, output settling, Wi-Fi jitter, watchdog/recovery during packet loss, uninterrupted local fallback playback, or behavior on true app crash.
