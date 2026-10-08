# LightDome next steps

## Waiting for access to the lamp

- Flash and complete the physical 150/250/300 Hz comparison described in
  `PATTERN_SYSTEM.md`.
- Verify low brightness from 1% to 20% by eye, not only through API responses.
- Confirm a saved pattern keeps running with the app and browser closed.

## Work that does not require the lamp

1. Bring saved-pattern editing to feature parity in Flutter: load the stored
   recipe metadata, edit it and replace the existing program.
2. Define and implement the computer/system-audio feature stream: volume, bass,
   mid, treble and beat, plus gain, gate, attack and release.
3. Add a safe audio-disconnect behavior: fade out or start a selected local
   fallback pattern.
4. Prepare the user-facing authoring package for an LLM: documented recipe
   schema, examples, validation and preview before upload.
5. Prepare distribution: signed Android release and an iPhone-friendly web
   experience that can be added to the Home Screen.
6. Harden maintenance and recovery: authenticated OTA update, progress,
   automatic reconnect and clear fallback when mDNS is unavailable.
