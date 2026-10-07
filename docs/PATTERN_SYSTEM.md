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
- reserved: unsigned 16-bit zero
- payload: one unsigned 16-bit little-endian brightness sample per frame,
  clamped to `0..1023`

This sampled representation can express arbitrary easing, acceleration,
randomness, pulses, fades and long timelines without requiring the ESP8266 to
parse an evolving high-level recipe schema.

## Creation surfaces

The embedded web interface and Flutter app compile high-level recipes to the
same `LDY1` payload. The current recipe types are breath, pulse, sunrise and
organic. They expose duration, minimum and maximum brightness, duty cycle,
easing, randomness, loop and autorun.

External `.ldy` files use the same validated, atomic upload path. Uploads are
received as multipart data into a temporary LittleFS file, validated, and only
then promoted to their final program name.

## Smooth live control

Live controllers send a target brightness. The firmware renders a local
smoothstep transition at 250 Hz, so HTTP timing jitter no longer appears as
visible jumps. Stored programs continue to use their own sample timing.

## Audio contract

Live audio processing stays on the phone or computer. A future transport can
send volume, bass, mid, treble and beat features, with gain, gate, attack and
release applied before or on the device. If that stream stops, the dome must
fade out or switch to a configured stored fallback.

## AI authoring

An LLM integration should generate a declarative recipe or an `LDY1` file,
never executable code. Every generated result must pass the same validator and
be previewed before upload.
