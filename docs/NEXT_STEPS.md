# LightDome next steps

## Waiting for access to the lamp

- Flash and complete the physical 150/250/300 Hz comparison described in
  `PATTERN_SYSTEM.md`.
- Verify low brightness from 1% to 20% by eye, not only through API responses.
- Confirm a saved pattern keeps running with the app and browser closed.

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
