# Transparent toolbar — 2026-09-12

The native window titlebar is transparent with no separator. Window backing is clear/non-opaque; workspace, sidebar and Agent backgrounds do not extend into the toolbar safe area. Native toolbar items, capsule styles, standard window controls and toolbar placement are unchanged. Window delegate/lifecycle logic is unchanged.

- Build passed: `/private/tmp/web-studio-transparent-build.log`.
- Official DESIGN lint and strict native ownership audit passed with no errors or warnings.
- `git diff --check` passed.
- Native CUA check on the independently signed `/private/tmp/Web Studio Transparent.app` confirmed removal of the continuous top-bar fill, native capsules, colored traffic lights when active, and working Cmd-L focus. Existing user windows were not closed. Manual dragging, light/high-contrast appearance and a complete UI automation suite were not rerun; native titlebar behavior remains in place.
- `window.png` is a window-only capture; the screenshot capture flattens transparent areas onto white, and standard traffic lights follow the system active/inactive appearance.
- No model/runtime/security/concurrency settings were changed and no unit tests were added for this appearance-only edit.
