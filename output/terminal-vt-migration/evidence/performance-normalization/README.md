# Legacy/VT normalization candidate

This directory is evidence and a candidate fixture only. Production
Vendor/ghostty/web-studio.conf and application bundles were not changed.

vt-font-metrics-2x.json was produced by an AppKit/CoreText one-off measurement
of the VT source's NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
at backing scale 2. The resolved font is:

- family .AppleSystemUIFontMonospaced
- PostScript name .AppleSystemUIFontMonospaced-Regular
- display name .SF NS Mono Light Regular
- 13pt
- cell width 8.5pt / 17px and cell height 17.5pt / 35px after the exact VT
  rounding formula
- content inset 16pt left/right and 12pt top/bottom

The family is constructible by AppKit using its private family/PostScript name,
but it is absent from NSFontManager.shared.availableFontFamilies on this
machine. Therefore Ghostty acceptance of the font-family value is
unverified; Ghostty's own font discovery may reject it or choose a fallback.
The vendored Ghostty documentation says font-family values should come from
its +list-fonts discovery (ghostty.1.md:42-52), so this is not a verified
portable font choice.

The candidate config mirrors VT colors and padding using Ghostty's documented
background, foreground, cursor-color, selection-background, window-padding-x/y,
and window-vsync settings. adjust-cell-width/height are explicitly zero because
the VT measurement gives no Ghostty base metric from which to calculate an
adjustment. Ghostty documents adjustment values as changes to the original
font-derived metric (ghostty.5.md:457-483), and says cell height adjustment
also vertically centers the font (ghostty.5.md:474-483); it does not provide an
exact target metric without measuring the running Ghostty surface.

Strict normalization is therefore feasible only as a two-step empirical
procedure: launch an isolated legacy Release surface with this candidate,
record ghostty_surface_size cell pixels and the geometry probe, then tune font
choice/adjustments and repeat. Until that occurs, the candidate is a proposal
and existing CPU/RSS results remain exploratory.
