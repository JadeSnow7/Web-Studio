# Address toolbar acceptance — 2026-09-12

The pane header (type icon, resource picker and focus dot) is removed. The native toolbar now contains an editable address capsule followed by a same-workspace tab menu. Sidebar groups and persistent resource runtimes are retained.

Address routing supports HTTP(S), bare hosts, `ssh://user@host:port`, SSH shorthand, `terminal`, `terminal://`, and absolute/home-relative local directory paths. Local/SSH destinations create sibling resources; they do not relabel or replace a running terminal's working directory. Invalid input is retained with an error. Selecting another tab cancels the edit and synchronizes the address.

## Verified

- Final source: 86 tests in 5 suites passed, including model, parser, captured-target, web resource reading, Agent controller/transport and provider settings tests. Log: `/private/tmp/web-studio-address-test-final.log`; result: `/private/tmp/web-studio-address/Logs/Test/Test-Web Studio-2026.09.12_21-51-47-+0800.xcresult`.
- Normal signed app build passed. Log: `/private/tmp/web-studio-address-build-final.log`.
- Strict native UI ownership audit: zero findings. `/private/tmp/web-studio-address-premium-audit.json`.
- `git diff --check` passed.
- Native CUA interaction confirmed header removal, direct input loading Example Domain, Cmd-L from web content selecting the complete URL, consecutive navigation from example.com to example.org, new-tab address clearing, invalid SSH text preservation and Escape cancellation.
- The preceding toolbar build also verified menu switching back to an existing web resource, restoring its page and address, and local-terminal routing displaying the existing sandbox failure. Final native input changes preserve those model/runtime paths.

## Limits

- The existing app sandbox still denies controlling-TTY setup. This change routes local/SSH addresses to real terminal resources but does not establish a working interactive shell or remote SSH login.
- UI test source compiled with the test action; the XCUITest UI suite was not executed in this task. Native CUA checks above are separate evidence.
- Full IME, accessibility, appearance and minimum-window matrices were not rerun. AppKit owns text composition; no claim of complete input-method coverage is made.
- No runtime entitlements, provider credentials, signing policy, or unrelated existing working-tree changes were altered by this task.
