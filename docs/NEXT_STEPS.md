# LightDome next steps

## Waiting for access to the lamp

- Flash and complete the physical 150/250/300 Hz comparison described in
  `PATTERN_SYSTEM.md`.
- Verify low brightness from 1% to 20% by eye, not only through API responses.
- Confirm a saved pattern keeps running with the app and browser closed.

## Work that does not require the lamp

1. Bring saved-pattern editing to feature parity in Flutter: load the stored
   recipe metadata, edit it and replace the existing program.
2. Test Android 10+ playback capture on a real phone with multiple capturable
   apps and verify volume, bass, mid, treble and beat response on the lamp.
3. Verify the audio watchdog on real hardware: fade out or start the selected
   local fallback after permission revocation, app closure and network loss.
4. Prepare the user-facing authoring package for an LLM: documented recipe
   schema, examples, validation and preview before upload.
5. Prepare distribution: signed Android release and an iPhone-friendly web
   experience that can be added to the Home Screen.
6. Harden maintenance and recovery: authenticated OTA update, progress,
   automatic reconnect and clear fallback when mDNS is unavailable.

Audio capture is Android-only for now. Web, iOS and desktop are intentionally
unsupported. A microphone mounted in the lamp is a possible future direction,
but is not part of the current implementation.
