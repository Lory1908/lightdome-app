# LightDome next steps

## Checkpoint 2026-10-14

The Android app currently installed on the Galaxy Z Flip8 is the stable
`859bf55` build. Manual brightness control, automatic reconnect, the `respiro`
pattern and normal non-DRM phone-audio response were physically verified with
the lamp and are usable.

Remaining phone-audio validation:

1. Repeat the phone lock/unlock test using VLC or another source that continues
   playback with the screen off; the YouTube attempt was inconclusive.
2. Run a 20-minute session and check heat, battery and reconnects.

The first real-phone capture session proved that the foreground service stays
active in the background and the lamp enters audio-stream mode. Permission
revocation and Wi-Fi loss both trigger the firmware safety fade. With build
`859bf55`, capture now remains active through a temporary Wi-Fi outage and the
lamp resumes automatically after reconnection without reopening the app or
requesting screen-sharing consent again. Spotify shared as a single app
produced protected silence (all values remained at zero), so it is not a valid
functional source for the remaining test.

## Audio v2: low latency and instant adaptive calibration

- Add a low-latency UDP level stream between the Android app and firmware,
  retaining the current paced HTTP path as a compatibility fallback.
- Measure end-to-end latency on the physical lamp and choose packet cadence,
  interpolation and watchdog values from evidence rather than visual guesswork.
- Add a short automatic calibration window that classifies the current source:
  broadband music, bass/beat-heavy music, sparse percussive clicks, or a mostly
  single-frequency tone.
- For broadband music, use balanced volume and band energy with an optional
  bass emphasis. For a single dominant sound, follow its dominant band instead
  of allowing unrelated band weights to suppress it.
- Detect broadband transients as well as bass transients so a metronome or
  short click is not missed merely because it contains little bass.
- Calibrate gain and noise gate from the recent signal floor and peaks, with
  safe limits, hysteresis and slow re-evaluation so the selected response does
  not jump between profiles during a song.
- Show the detected response in plain language (for example **Musica**,
  **Battito** or **Tono**) and always provide a manual override and reset.
- Never store or upload captured PCM; calibration must use transient aggregate
  features only.

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

1. Complete the optional Audio v2 adaptive calibration and low-latency work
   described above.
2. Add and verify the optional local-pattern fallback after an audio timeout;
   the current safe fade-to-off watchdog and Wi-Fi recovery are physically
   verified.
3. Test installation from Safari and normal controls on an iPhone. Audio
   capture intentionally remains Android-only.
4. Create the final Android application id, signing key and signed release.
5. Harden maintenance and recovery: authenticated OTA update, progress,
   automatic reconnect and clear fallback when mDNS is unavailable.

Audio capture is Android-only for now. Web, iOS and desktop are intentionally
unsupported. A microphone mounted in the lamp is a possible future direction,
but is not part of the current implementation.
