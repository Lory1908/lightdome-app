# LightDome next steps

## Checkpoint 2026-10-14

The Android app currently installed on the Galaxy Z Flip8 is the stable
`c9bb257` build. Manual brightness control, automatic reconnect and the
`respiro` pattern were physically verified with the lamp and are usable.

Resume the phone-audio validation from here:

1. Start **Audio del telefono** and share the **entire screen**.
2. Play the prepared non-DRM file
   `J:\data\lightdome\test-audio\lightdome-capture-check.wav` on the phone.
   It contains 2 seconds of silence, then 4 seconds each of bass, mid and high
   tones, followed by 8 seconds of pulsing bass.
3. Verify that volume, bass, mid, treble and beat indicators move, then check
   that the lamp follows them smoothly.
4. Repeat with the app in the background and with the phone locked/unlocked.
5. Verify explicit stop, permission revocation, Wi-Fi loss and the firmware
   fade/fallback watchdog.
6. Run a 20-minute session and check latency, heat, battery and reconnects.

The first real-phone capture session proved that the foreground service stays
active in the background and the lamp enters audio-stream mode. Spotify shared
as a single app produced protected silence (all values remained at zero), so it
is not a valid functional source for the remaining test. The capture was
stopped before ending the session.

## Waiting for access to the lamp

- Flash and complete the physical 150/250/300 Hz comparison described in
  `PATTERN_SYSTEM.md`.
- Recheck low brightness only if later firmware or PWM changes regress it; the
  1-20% range is currently physically verified without flicker.
- Recheck saved-pattern autonomy only after relevant firmware changes; the
  current `respiro` pattern was verified running independently of the UI.

## Work that does not require the lamp

The software-only preparation currently planned is complete: Flutter can edit
and atomically replace saved recipe-based patterns, the local LLM authoring kit
contains a schema, prompt, examples, validation and preview, Android playback
capture is wired to the firmware watchdog, and the Web build includes the
mobile/PWA metadata needed for adding it to an iPhone Home Screen.

The remaining work needs either a real device or release credentials:

1. Test Android 10+ playback capture on a real phone with multiple capturable
   apps and verify volume, bass, mid, treble and beat response on the lamp.
2. Verify the audio watchdog on real hardware: fade out or start the selected
   local fallback after permission revocation, app closure and network loss.
3. Test installation from Safari and normal controls on an iPhone. Audio
   capture intentionally remains Android-only.
4. Create the final Android application id, signing key and signed release.
5. Harden maintenance and recovery: authenticated OTA update, progress,
   automatic reconnect and clear fallback when mDNS is unavailable.

Audio capture is Android-only for now. Web, iOS and desktop are intentionally
unsupported. A microphone mounted in the lamp is a possible future direction,
but is not part of the current implementation.
