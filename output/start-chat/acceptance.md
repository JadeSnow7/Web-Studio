# Start page and Agent chat acceptance

Date: 2026-09-13. Scope: implement the approved start-page mockup and simplify the Agent sidebar into a chat surface. This report supersedes the earlier UI-runner limitation only for the checks below.

## Implemented

- Blank/new tabs show Web, local terminal and SSH entry actions, user-added fixed destinations, and up to five actual recently used resources. No sample destinations are seeded.
- Fixed destinations retain their destination after the original resource closes; web entries reuse the originating blank tab. Existing pane/group routing remains intact. Recent rows and Agent resource rows have full-width click targets.
- Agent opens by default with a scrollable user/assistant transcript and bottom composer. Resource selection, exact snapshot preview, provider settings and per-question request details open through buttons.
- New Chat cancels active reads/requests and clears the draft, selection, preview, messages and retained runs. Generation checks reject late results. Drafts survive advanced-panel opening and dismissal.
- Native appearance follows the system, with existing light/dark application test overrides and minimum-window behavior. The new start page and chat are Chinese; existing shell/settings labels retain their current language.

## Verification

- Final source compiled and signed for local execution during the successful final UI-test run.
- **94 tests in 5 suites passed:** model, Agent controller, service/transport, resource reads and provider settings. See [unit log](web-studio-start-unit.log).
- **5 targeted native UI cases passed across the initial run and focused reruns:** blank launch/new tab; add session-pinned entry; chat draft/panel/new-chat; minimum window/light-dark controls; resource selection/blank preview failure/provider settings. The initial run exposed hit-target and test-focus issues; these were fixed and the failing cases rerun successfully. Unrelated native UI cases were not part of this acceptance run.
- UI evidence: [initial targeted run](web-studio-start-ui.log), [fixed-entry rerun](web-studio-start-ui-rerun.log), [final resource/preview/settings pass](web-studio-start-ui-hit-target.log).
- Manual native-window checks confirmed local HTTP navigation, actual recency after creating a new tab, clicking the empty center of a recent row, fixed-entry navigation, exact resource text and metadata preview, multiline draft preservation, and the final start/chat layout. The temporary local HTTP fixture was stopped after verification.
- Strict design audit: zero findings. DESIGN lint: zero errors and one inherited nativeRadii export-schema warning. See [audit](design-audit.json) and [lint](design-lint.json). git diff --check passed.

## Boundaries

Pins, recent resources and chat history are session-only. The visible transcript does not change the API context contract: each request sends its current question and explicitly selected frozen snapshots. A configured provider, selected resources and successful preview are still required to send.

No live external model request or authenticated SSH connection was accepted in this iteration. The previously documented sandbox PTY restriction remains; terminal entry UI does not establish interactive terminal success. Existing compiler isolation warnings remain separate from passing tests.

Pre-existing working-tree changes were preserved. No commit, push, release or system appearance setting was changed.
