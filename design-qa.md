# LightDome visual QA

## Evidence

- Source visual truth:
  - `C:\Users\loryc\AppData\Local\Temp\codex-clipboard-e1a58403-b1c3-4ba1-a5f5-23a0e17fe20b.png`
  - `C:\Users\loryc\AppData\Local\Temp\codex-clipboard-94b2a26d-63d4-43f6-b073-011ca9cff590.png`
  - `C:\Users\loryc\AppData\Local\Temp\codex-clipboard-446c43e5-8410-42ba-ae7c-deb67aacaa9c.png`
- Browser-rendered implementation: `http://192.168.1.171/` on the flashed ESP8266.
- Implementation screenshots: captured in the Codex in-app browser during this
  QA run. The capture surface returned rendered image evidence but no
  file-backed screenshot path.
- Viewports:
  - desktop: 1787 × 1245 CSS px, device scale 1;
  - mobile: 390 × 844 CSS px, device scale 1.
- States compared: desktop dark Home, mobile dark Home, mobile dark Create,
  mobile light Help/Advanced, empty library, running stored pattern, manual
  brightness control.
- Density normalization: the references are presentation moodboards rather
  than a single production screen, so evaluation uses matched component scale,
  hierarchy, palette and interaction density instead of pixel-for-pixel frame
  geometry.

## Required fidelity surfaces

- Fonts and typography: passed. Offline system fonts preserve the reference's
  compact grotesk hierarchy. Headings, numeric output, labels and helper copy
  have visibly distinct weights and remain readable in both themes.
- Spacing and layout rhythm: passed. The 12–26 px spacing/radius system creates
  integrated panels and a floating bottom navigation. Desktop uses a focused
  two-column control surface; mobile collapses cleanly without horizontal
  overflow.
- Colors and visual tokens: passed. Graphite surfaces, warm light accents,
  restrained borders and cool connection status match the reference language.
  The light theme preserves the same hierarchy rather than falling back to a
  generic white form.
- Image quality and asset fidelity: passed for the mono-light product. The
  reference photography and RGB wheel are moodboard material, not LightDome
  assets. No low-quality placeholder imagery was introduced.
- Copy and content: passed. Daily actions use plain Italian; autonomy and audio
  limitations are explained where decisions are made. Technical status is
  hidden under the Advanced/Diagnostics layer.

## Full-view comparison

The implementation carries the selected visual direction into a practical
embedded UI: large primary light control, integrated status card, low-noise
surfaces, clear selected states and compact persistent navigation. It is less
ornamental than the marketing references by design, keeping the ESP8266 page
fast and legible while retaining the same premium dark-surface character.

## Focused-region comparison

- Home: large output percentage, centered dome state, full-width slider and
  quick levels form one coherent control surface.
- Create: preset cards, labeled controls and the live curve preview keep the
  complex pattern model understandable on a 390 px viewport.
- Help/Advanced: first-use guidance is visible before technical controls;
  diagnostics remain available without dominating everyday use.
- Navigation: Home, Create, Pattern and More remain reachable at all tested
  heights with clear selected-state treatment.

## Interaction verification

- Theme switching passed in light and dark modes.
- Manual 50% and Off commands passed against the real device.
- Pattern generation, multipart upload, validation, start and library refresh
  passed against LittleFS.
- Autonomous playback passed: frame position advanced while the interface was
  no longer involved (`227` to `323` during the check).
- Firmware smoothing passed with monotonic intermediate output samples before
  reaching the requested target.
- Test pattern cleanup passed; the final device state is stopped and off.
- No new console error was observed after the final firmware reload.

## Comparison history

1. First pass found a P1 blank page: the 23 KB UI was copied into scarce heap
   memory. Fixed by streaming the page directly from flash with `send_P`.
2. Second pass found a P1 pattern-save failure: the legacy raw upload path did
   not trigger ESP8266 upload callbacks. Fixed with multipart upload in web,
   Flutter IO and Flutter web clients plus atomic temporary-file promotion.
3. Mobile review found no actionable overflow or obscured primary action. The
   bottom navigation intentionally overlays the safe-area edge and content has
   matching bottom padding.
4. Post-fix desktop and mobile captures verified the final Home, Create,
   Library and Help states on the physical controller.

## Findings

No actionable P0, P1 or P2 findings remain.

## Follow-up polish

- P3: audio-system capture is represented in the architecture but still needs
  platform-specific implementation and latency testing.
- P3: the AI Pattern Kit is documented as an extension point but is not yet an
  in-product cloud dependency.

## Final result

final result: passed
