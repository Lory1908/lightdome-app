# LightDome visual QA

## Evidence

- Source visual truth:
  - `C:\Users\loryc\AppData\Local\Temp\codex-clipboard-e1a58403-b1c3-4ba1-a5f5-23a0e17fe20b.png` (primary visual language)
  - `C:\Users\loryc\AppData\Local\Temp\codex-clipboard-94b2a26d-63d4-43f6-b073-011ca9cff590.png` (secondary information-density reference)
  - `C:\Users\loryc\AppData\Local\Temp\codex-clipboard-446c43e5-8410-42ba-ae7c-deb67aacaa9c.png` (functional lighting-control reference)
- Rendered implementation:
  - Flutter Web preview: `http://127.0.0.1:4181`
  - ESP8266 control UI: `http://lightdome.local/`
  - ESP8266 setup UI: `http://lightdome.local/wifi`
  - Screenshots were captured and inspected in the Codex in-app browser during this build; the capture surface does not expose a file-backed screenshot path.
- Viewports and density:
  - Flutter mobile: 393 × 852 CSS px at device scale 1.
  - Flutter desktop: 1787 × 1245 CSS px at device scale 1.
  - Firmware pages: 1265 × 711 CSS px at device scale 1.
  - The moodboard images are presentation boards rather than same-screen mocks, so comparison was normalized around component scale, hierarchy, palette, density, and interaction language rather than pixel-for-pixel geometry.
- States checked: light theme, dark theme, disconnected device, dashboard, settings, firmware control, firmware setup, password visibility.

## Required fidelity surfaces

- Fonts and typography: passed. System UI fonts preserve offline operation and closely match the compact grotesk hierarchy in the references. Display, title, label, and supporting-text weights are distinct and remain readable in both themes.
- Spacing and layout rhythm: passed. The implementation uses a consistent 12–24 px rhythm, 16–26 px radii, integrated cards, restrained borders, and compact navigation. Mobile and desktop layouts do not overflow.
- Colors and visual tokens: passed. Dark graphite and warm ivory bases, warm light accent, cool connection accent, muted outlines, and semantic error colors remain legible in both themes.
- Image quality and asset fidelity: passed for the adapted product scope. The references are moodboards containing product photography and RGB controls; LightDome is a mono fixture, so those assets were intentionally not copied. Material icons and native controls are used instead of approximate raster or handmade icon assets.
- Copy and content: passed. Labels are concise Italian product copy, setup steps are explicit, and credential handling is explained without exposing secrets.

## Full-view comparison

The revised surfaces match the selected references in their key design traits: dark integrated surfaces, strong but sparse light accents, large primary controls, compact secondary data, low-noise borders, and a floating mobile navigation treatment. The light theme preserves the same hierarchy instead of becoming a plain white Material layout.

## Focused-region comparison

- Dashboard hero: lamp state, connection state, output percentage, and primary actions form one integrated control region, matching the references' device-card hierarchy.
- Setup network form: progress steps, selectable network rows, signal/security metadata, password visibility, and status feedback are grouped into one focused card.
- Theme controls: both app and firmware pages switch between independently designed light and dark token sets.

## Comparison history

1. First implementation pass:
   - P2: desktop app header did not align with the centered content column.
   - P2: setup step separators rendered with mojibake because the firmware page omitted an explicit UTF-8 charset.
   - P3: the technical pattern placeholder displayed literal newline escapes.
2. Fixes:
   - Constrained the app header to the same 1180 px content width.
   - Added UTF-8 metadata to both firmware pages.
   - Replaced the placeholder escapes with HTML line breaks.
3. Post-fix evidence:
   - Rebuilt and recaptured app mobile light/dark views.
   - Flashed the firmware, reloaded both device pages, verified the corrected setup labels, theme switching, password visibility, and empty browser error logs.

## Findings

No actionable P0, P1, or P2 findings remain.

## Follow-up polish

- P3: the populated Wi-Fi network-row appearance was not recaptured after the visual redesign because `/wifi/scan` is intentionally restricted to clients on `LightDome-Setup`. The same endpoint and selection logic were previously hardware-tested; the unpopulated form and all other visible states were verified after flashing.

## Final result

final result: passed
