# Adaptive page toolbar — 2026-09-13

The native toolbar now displays a softened, local snapshot of the focused web page's visible top strip. The effect ends at the content boundary and does not move or cover page content. Existing native toolbar controls and runtime ownership are retained. Blank resources and unavailable snapshots fall back to the existing shell/system surface.

`PageChromeBackdrop` owns presentation and a cancellable 900ms refresh loop. `WebTabRuntime` captures at most 120pt of the visible page, with a 512pt snapshot width. Only an active app/key window can capture; overlapping captures are suppressed. Navigation generations reject stale completions. Reduce Transparency cancels sampling and uses an opaque semantic background. Captures stay in memory and are not sent to an Agent or written to disk.

This is a blurred extension of visible page pixels, not Safari's private rendering implementation or a seamless continuation of arbitrary webpage artwork. Refresh may lag scrolling by about one second. Video/GPU-only content and prolonged compositor stalls were not qualified.

## Verification

- Reviewed source changes in ContentView.swift, StudioDesign.swift, WebRuntime.swift and PageChromeTests.swift; DESIGN.md and UX-CONTRACT.md updated for the new visual behavior. Existing dirty work was preserved.
- `xcodebuild build-for-testing` passed with temporary ad hoc signing and derived data at `/private/tmp/web-studio-adaptive`.
- Serial manifest unit suites plus initial PageChromeTests: 97 passed, zero failures. Result: `/private/tmp/web-studio-adaptive/Logs/Test/Test-Web Studio-2026.09.13_12-07-41-+0800.xcresult`.
- Final review corrected accessibility task invalidation and post-capture window checks, keyed the backdrop by resource ID, and removed an ineffective test. Final focused PageChromeTests: 2 passed, zero failures, with recompilation. Result: `/private/tmp/web-studio-adaptive/Logs/Test/Test-Web Studio-2026.09.13_12-08-49-+0800.xcresult`. These two tests establish noncreating runtime lookup and inert windowless capture, not visual correctness or stale-image race proof.
- Primary agent independently read both xcresult summaries. Earlier parallel test execution reported host contention; the serial run passed.
- Strict Premium audit: zero findings. Official DESIGN.md lint: zero errors, one existing `nativeRadii` schema/export warning. `git diff --check` passed.
- Native CUA on an independently identified preview bundle verified a pink/purple SVG page, a dynamic dark background, blue after scrolling, white after navigation, blank-tab reset, error fallback, address focus, and narrower window layout. In split view, the band followed the focused white or blue page.
- Split initially rendered blank until a window resize, after which both existing pages appeared. WorkspaceSplitView was not changed in this task; this layout issue remains unresolved and is not counted as full split-layout acceptance.
- The final rebuilt preview was relaunched and the image-page effect rechecked. Preview: `/private/tmp/Web Studio Page Chrome.app`; local fixture server: `http://127.0.0.1:8769/`. Original user windows were not closed. The preview and fixture server are left available for inspection.
- System accessibility settings were not changed. Reduce Transparency and high-contrast behavior were source-reviewed; system dark appearance, fullscreen, and a complete UI automation suite were not reverified.

API basis: Apple's [WKSnapshotConfiguration](https://developer.apple.com/documentation/webkit/wksnapshotconfiguration) and [snapshot rectangle](https://developer.apple.com/documentation/webkit/wksnapshotconfiguration/rect) documentation.
