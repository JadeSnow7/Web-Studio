# Frosted glass acceptance — 2026-09-12

Implemented native behind-window frost for the workbench, matching sidebar/Agent scrims, glass capsules and action buttons, glass floating panels, and material field backing. The transparent native toolbar band and traffic lights remain. Embedded WebKit/terminal content is unchanged.

## Verification
- Final Debug arm64 build passed with temporary ad-hoc signing; see build.log.
- git diff --check passed.
- DESIGN.md lint: zero errors, one inherited warning for the custom nativeRadii map (native points intentionally not exported as CSS units).
- Strict design audit: zero findings; see design-audit.json.
- Manually checked the final independent preview app at /private/tmp/Web Studio Glass.app: 1100x720 workspace, 900x600 narrow layout with native toolbar overflow, Agent visibility shortcut, Provider settings selected endpoint focus and capsule actions, command search focus, Escape dismissal.
- Screenshots: workspace.png, narrow.png, provider.png, commands.png. Window-only screenshots flatten transparent desktop regions; they do not independently prove blur sampling behind the window.
- Reduce Transparency opaque fallback and increased-contrast borders were reviewed in source, not exercised by changing system accessibility settings. Alternate appearance was not manually exercised this round.
- StudioModel prefix and WindowLifecycle match the pre-change baseline. This appearance-only round did not rerun unit tests or the previously blocked XCUITest automation suite. No external provider request, credential change, or terminal session was started.
