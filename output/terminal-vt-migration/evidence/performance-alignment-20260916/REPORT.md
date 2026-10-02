# Ghostty/VT performance alignment probe

Date: 2026-09-16. Source revision: `ced7edc25bd6ab6434712ce4da0b4bd16afad499`.

## Baseline

The VT reference remains the recorded AppKit/CoreText measurement in
`../performance-normalization/vt-font-metrics-2x.json`: 13pt system monospaced,
backing scale 2, 17×35px cells, and 16/12pt content insets. The isolated
legacy Release binary was already built at
`/private/tmp/web-studio-m2-legacy-20260916/Build/Products/Release/Web Studio.app`
with bundle identifier `com.huaodong.Web-Studio.M2PerformanceLegacy20260916`.
Hashes and the source revision are in `identity.txt`.

## Probe implementation and execution

`../../../../scripts/terminal-performance-probe.swift` links the pinned
`Vendor/GhosttyKit.xcframework` archive, initializes AppKit with activation
prohibited, creates an off-screen NSView/NSWindow matching the host's
`userdata`, `wantsLayer`, surface context, and resource path, loads a supplied
Ghostty config and requests the real `ghostty_surface_size` after setting a
900×560pt, 2× surface. It also calls the published
`ghostty_surface_quicklook_font` API and records CoreText family, PostScript
name, and point size. It does not order or activate a window. The complete
build argv is reproducible through `../../../../scripts/terminal-performance-probe-build.sh`;
the `-x` argv and warnings are in `probe-build-argv.log`.

The initial sandbox run failed to create a surface. The required host retry
then succeeded for both configs; raw JSON is in `probe-runtime-font-grid.log`.
The resource path was the same path used by `GhosttyTerminalRuntime`:
`Contents/Resources/ghostty/ghostty`.

The tuned isolated config sets `adjust-cell-width = 1` and
`adjust-cell-height = 4`. Ghostty documents these as changes to the original
font metric, with integer values representing pixel adjustments; this is why
the measured base `16×31` became the target `17×35`. At 900×560pt and 2×:

| config | resolved font | cell px | grid | content px |
| --- | --- | --- | --- | --- |
| tuned candidate | `.AppleSystemUIFontMonospaced-Regular`, `.AppleSystemUIFontMonospaced`, 13pt | 17×35 | 102×30 | 1800×1120 |
| production | `JetBrainsMono-Regular`, `JetBrains Mono`, 13pt | 16×34 | 112×32 | 1800×1120 |

The candidate therefore has exact VT cell and content dimensions in this
isolated probe. The font identity is also directly observed through the
published quicklook font API; it is not inferred from the config string. The
candidate remains an isolated fixture and was not installed into production.

## Result

Status: `passed` for resolved font identity and `ghostty_surface_size` equality
against the VT 900×560/2× target in the isolated tuned fixture. Status remains
`undetermined` for on-screen raster appearance, frame time, GPU, input latency,
and performance budget. The probe's off-screen surface is evidence of the
Ghostty resolved metrics, not visual screenshot acceptance. No production
config, app source, or vendor dependency was changed.
