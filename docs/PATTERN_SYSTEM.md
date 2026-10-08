# LightDome pattern system

## Product rule

The controller creates and starts a pattern; the dome stores and executes it.
Normal patterns keep running when the Flutter app or local web interface is
closed. Audio-reactive live modes are the exception because their audio source
must remain active.

## Runtime format

The hardware runtime remains the compact, deterministic `LDY1` format:

- magic: `LDY1`
- sample rate: unsigned 16-bit little-endian
- frame count: unsigned 32-bit little-endian
- recipe metadata length: unsigned 16-bit little-endian (`0` for legacy files)
- payload: one unsigned 16-bit little-endian brightness sample per frame,
  clamped to `0..1023`
- optional metadata: UTF-8 JSON recipe data after the brightness samples; its
  byte length is stored in the preceding field

This sampled representation can express arbitrary easing, acceleration,
randomness, pulses, fades and long timelines without requiring the ESP8266 to
parse an evolving high-level recipe schema.

## Creation surfaces

The embedded web interface and Flutter app compile high-level recipes to the
same `LDY1` payload. The current recipe types are breath, pulse, sunrise and
organic. They expose duration, minimum and maximum brightness, duty cycle,
easing, randomness, loop and autorun.

New patterns use 250 samples per second by default. This is a quality preset,
not a user-facing setting: it improves short transitions while keeping file
size and ESP8266 filesystem reads within a conservative range. Imported legacy
files retain their own sample rate.

External `.ldy` files use the same validated, atomic upload path. Uploads are
received as multipart data into a temporary LittleFS file, validated, and only
then promoted to their final program name.

## Smooth live control

Live controllers send a target brightness. The firmware renders a local
smoothstep transition at 250 Hz, so HTTP timing jitter no longer appears as
visible jumps. Stored programs continue to use their own sample timing.

## Audio contract

Live playback-audio processing currently runs only in the Android 10+ app.
Android sends transient mono PCM to Dart, where volume, bass, mid, treble and
beat are calculated with gain, gate, attack and release. Only the resulting
brightness is sent to the dome; PCM is never stored. If that stream stops, the
dome fades out or switches to a configured stored fallback.

## AI authoring

An LLM integration should generate a declarative recipe or an `LDY1` file,
never executable code. Every generated result must pass the same validator and
be previewed before upload.

## Pending physical checkpoint

This checkpoint requires the lamp and must not be marked complete from a build
test alone:

1. Flash the next firmware build with 250 Hz pattern generation.
2. Compare the same breath and pulse patterns at 150, 250 and 300 Hz.
3. Check manual control at 1%, 3%, 5%, 10%, 15% and 20% brightness.
4. Let a 250 Hz looping pattern run autonomously for at least five minutes with
   both the app and browser closed.
5. Confirm that starting, stopping, editing and replacing saved patterns remain
   responsive over Wi-Fi.

Keep 250 Hz as the default unless the physical comparison shows a visible
benefit at 300 Hz without harming responsiveness or autonomous playback.
