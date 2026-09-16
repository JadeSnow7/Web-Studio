# libghostty-vt

This directory is the Web Studio pinned boundary for Ghostty's standalone VT
library. It is deliberately separate from `Vendor/GhosttyKit.xcframework`.
The checked-in dependency is the M0/M1 library artifact; the M2 core and
backend adapters are opt-in source work and remain pending full app and live
acceptance.

The exact upstream source, Zig toolchain, target, and build flags are recorded
in [`DEPENDENCY.lock`](DEPENDENCY.lock). The bootstrap script clones the
official repository at that commit, verifies the commit and Zig SHA256, builds
the static library, and copies the public C headers and pkg-config metadata
here.

```sh
./scripts/build-ghostty-vt.sh
./scripts/test-ghostty-vt.sh
```

The upstream C API is explicitly unstable. The pinned commit is
`d4c88d8069912b653d707191388ca98e24751f12`, built for `aarch64-macos` with
Zig `0.16.0`; the exact checksums and flags are in
[`DEPENDENCY.lock`](DEPENDENCY.lock). Reproduce the checked-in artifact with
`./scripts/build-ghostty-vt.sh` and then run `./scripts/test-ghostty-vt.sh`.

The M0 smoke proves the linked Terminal, Render State, Formatter, key, mouse,
selection, and resize surfaces. M1 adds the Swift-owned core boundary and
render snapshot conversion. M2 adds source-level scroll, selection, paste,
focus, mouse, PWD, and PTY backend adapters. Prior arm64 Debug, core, backend
and offscreen checks passed for the opt-in target. The latest source-only
changes are unverified because Xcode 27 requires its license agreement; live
GUI acceptance and the M3 migration gate remain pending. The app default
remains the current production backend.
