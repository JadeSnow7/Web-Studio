# Seamless toolbar background — 2026-09-12

The root backdrop Group now ignores only the top container safe area inside the background builder. Both the native effect and opaque Reduce Transparency fallback extend behind the toolbar. Foreground content keeps its original safe-area layout; native toolbar/background suppression and window lifecycle are unchanged.

Final Debug arm64 build passed (build.log). git diff --check passed. Reviewed final source diff: view background scope only, plus design documentation.

Manual final preview at /private/tmp/Web Studio Seamless.app: toolbar and main shell share a continuous background with no horizontal dark/transparent band, traffic lights and capsules remain visible, sidebar and Agent content retain their original vertical positions. Verified 1100x720 and 900x600 layout, native overflow, Agent shortcut and Command-L address focus. Screenshots workspace.png and narrow.png. Unit/UI test suites were not rerun for this background-only change. System accessibility fallback was source-reviewed, not manually toggled.
