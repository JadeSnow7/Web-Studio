# T3: VT backend key ordering and silent input drops

Lane: `/private/tmp/ws-vt-perf/r2/T3/src` (baseline commit kept, nothing committed). Patch: `../patch.diff` (3 files, +222/-12). All commands run with `TMPDIR=/private/tmp/ws-vt-perf/tmp`.

## Root cause (baseline line numbers)
1. Ordering: `TerminalVTBackend.swift:98-106` `encodeKey` does `queue.async { encode; transport.write(data) }`. `TerminalPTYTransport.swift:111-124` `write` reserves admission on the caller thread and then does `queue.async { input.append; drain }` (line 119). `sendRaw` (`TerminalVTBackend.swift:109-112`) calls `transport.write` directly from the caller thread. `backend.queue === transport.queue`. Main thread `encodeKey(A); sendRaw(B)` enqueues [encode-A, write-B]. Running encode-A enqueues write-A behind write-B, so the child receives "BA".
2. Drops: `write` returns false when `data.count > inputLimit - reservedInput`. The results of `encodeKey` (line 103), `focus` (193), `mouse` (194) and the query reply in `consume` (216) are discarded with `_ =`. While a large paste holds the 256 KiB admission, keys, focus/mouse reports and DSR/DA replies vanish without any signal.

## Tests (scripts/terminal-vt-backend-smoke.swift, new `InputOrderSmoke`; failures are collected, not trapped, so one run shows every broken guarantee)
- O1: serial queue stalled with `usleep`, then `encodeKey('a')` + `sendRaw('b')` must arrive as "ab". Then 600 mixed tokens (encodeKey / sendRaw / paste) with periodic stalls; the exact byte stream is compared. The child is `stty raw -echo; exec cat` and the stream is read back from `onOutput`.
- O2: 6000 mixed tokens with no artificial stall.
- D1: the child does not read (gate file). Bulk admission is filled exactly (a 256 KiB `sendRaw`, then 1-byte top-ups until refused). Then a key, a focus report (DECSET 1004), a mouse report (1000/1006) and a DSR reply are sent. Once the child reads, all four must arrive after the paste.
- D2: 69536 interactive key bytes with a full bulk budget. Exactly 65536 are admitted and delivered in order; exactly 4000 are dropped and counted/reported through `onInputDropped` (not `onError`); `reservedInput == 256K+64K` while stuck; bulk is still refused; `reservedInput` returns to 0 after delivery.
- D3: `reservedInput == 0` after `closeAndWait` with a pending backlog, and after natural child exit with a pending backlog. Writes are refused after close.
D2/D3 use new test accessors (`reservedInputForTesting`, `droppedInteractiveBytes`, `onInputDropped`), so they cannot compile on the baseline. Only O1, O2 and D1 were run against it.

### Baseline failure evidence: `baseline-fail.log` (exit=1)
```
O1: encodeKey('a') then sendRaw('b') on a busy queue reached the child as "ba" instead of "ab"
O1: mixed key/raw/paste stream reordered under backlog: first mismatch at byte 0 ... actual ...babeacdf expected ...ababcdef
O2: mixed key/raw/paste stream reordered without stall: ... actual ...beacdfhk expected ...abcdefgh
D1: key 'a' encoded while the paste budget was full was silently dropped (tail="")
D1: focus report was silently dropped / mouse report was silently dropped / cursor-position query reply was silently dropped
```
An earlier draft of D1 passed on the baseline because the kernel PTY buffer absorbed about 1 KiB of the paste and freed admission. D1 now tops the admission up to exactly full, and the log above is from that final version.

## Fix
- `TerminalPTYTransport.swift:115-136` `write(_:interactive:)`:
  - Before: `queue.async { append; drain }` always.
  - After: if already on the transport queue (`DispatchQueue.getSpecific(queueKey)`), call `appendAdmittedInput(data)` immediately and defer only the drain with `queue.async { drainWrites() }`. Off-queue callers keep one queued block that appends then drains.
  - Reason: the bytes enter `input` at call time for queue-internal callers, so encode-then-write cannot be overtaken by a write enqueued earlier by another thread.
  - The drain is deliberately deferred. `consume` runs inside `readAvailable`; a synchronous drain that fails would call `requestClose` and re-enter `readAvailable` while `inOutput` is set, which would discard output.
- `appendAdmittedInput` (`TerminalPTYTransport.swift:138`) is the old block body, factored out: release the admission if closing/finished/no fd, otherwise append.
- `TerminalPTYTransport.swift:17-19`, `:115-118`: `interactiveAllowance = 64 KiB`. `interactive: true` writes are admitted while `reserved + n <= 256K + 64K`. Bulk writes keep `<= 256K`.
- `TerminalPTYTransport.swift`: added `isAcceptingInput` and `reservedInputForTesting`.
- `TerminalVTBackend.swift:107,197,198,228` (baseline 103,193,194,216): `encodeKey`, `focus`, `mouse` and the query reply in `consume` now go through `writeInteractive` (`:213`). Before, they called `_ = transport.write(...)`.
- `writeInteractive`: if the transport still accepts input but refuses the write (allowance exhausted), it adds to the atomic `droppedInteractiveBytes` and calls the new non-fatal `onInputDropped(count)`. It is not routed through `onError`, because `TerminalVTSession.onError` sets `state = .failed`, which would look like a dead terminal. Refusals after close/exit are silent, since there is nothing to deliver to.
- Unchanged: `sendRaw` (bulk, returns accepted or not to its caller), `paste`, the 256 KiB bulk budget, PTY back-pressure, close/exit paths, the `TerminalBackend` protocol. `TerminalVTSession.swift` and `TerminalVTView.swift` were not touched, because all API changes are additive. `onInputDropped` is not wired into the Session yet.

## Why the order holds in every interleaving
There is a single FIFO serial queue, and admission reservation is separate from ordering.
- Main thread `encodeKey(A)` then `sendRaw(B)`: the block E_A is enqueued before W_B. E_A runs first and appends A to `input` inside E_A. W_B runs later and appends B, so the order is A, B. `sendRaw(B)` then `encodeKey(A)` is the same, with W_B first.
- Queue-internal writers (`encodeKey` block, `focus`, `mouse`, `consume`, `paste` when already on the queue) append to `input` synchronously in their own execution order. Nothing can be inserted between their code and the append.
- `paste` from a non-queue thread uses `queue.sync`. Its block sits in FIFO behind everything enqueued earlier by that thread, and once running it appends immediately. The O1/O2 tests include this case.
- Draining: `drainWrites` only removes from the head of `input`; deferred drains are idempotent (empty input just cancels the write source).
- Not guaranteed, and not a regression: order between writes from two different threads with no happens-before relation. There is also a benign inversion between admission order and enqueue order for such racing threads.

## Drop policy and limits
Chosen: a separate bounded interactive allowance (64 KiB above the bulk limit) plus explicit accounting and reporting on overflow.
- Why not report-only: DSR/DA replies and key presses must not disappear merely because a paste is pending. An allowance keeps them lossless in practice.
- Why bounded: unbounded interactive writes would remove PTY back-pressure protection against a child that never reads (for example, a key-repeat or query flood).
- Limits:
  - Interactive bytes can still be dropped after 64 KiB of stuck interactive input. That is thousands of keystrokes, or a query flood from a non-reading child. Such drops are counted and reported through `onInputDropped`, but are not shown in the UI yet.
  - Interactive bytes also consume the shared `reservedInput`, so they can briefly reduce bulk headroom by up to 64 KiB.
  - A write issued before `start` or after the fd is gone is still released silently (baseline behaviour, out of scope).
  - `sendRaw`/`paste` (bulk) still return false when the budget is full. This is explicit to the caller, and `TerminalVTSession.sendRaw` ignores it (`_ =`, pre-existing).

## `reservedInput` released exactly once per admitted byte
Every admitted byte is reserved once, under `admissionLock`, in `write`. After that it is owned by exactly one path:
1. Appended to `input`, then released in `drainWrites` by the number of bytes `write(2)` accepted (`removeFirst(n)` and `releaseAdmission(n)` together).
2. Cleared together with `input`: `requestClose`, `finish` and the `drainWrites` error path each do `input.removeAll` followed by `releaseAdmissionAll`, which zeroes the counter.
3. Not appended because closing/finished/no fd: `appendAdmittedInput` calls `releaseAdmission(n)`.

On the new on-queue path there is no in-flight window: the append happens synchronously, so a byte is either in `input` (path 1 or 2) or released (path 3). The deferred `drainWrites` does not touch admission, so it cannot double-release. For the off-queue path the baseline race is unchanged, and the `max(0, ...)` clamp plus `acceptingInput = false` after close cover it. D3 checks `reservedInput == 0` after close and after child exit with a backlog, and D2 checks it after full delivery. I did not test the `drainWrites` write-error path (EIO) in isolation.

## Gates (all exit 0; logs in `gates/`)
- `sh scripts/test-terminal-vt-backend.sh` x3 after the fix: run1 exit 0, run2 exit 0, run3 exit 0 (`gates/vt-backend-run{1,2,3}.log`). One more run after the mutation restore: exit 0.
- `test-terminal-vt-host.sh` exit 0
- `test-terminal-vt-core.sh` exit 0
- `test-terminal-vt-core-asan.sh` exit 0
- `test-terminal-pty-transport.sh` exit 0
- `test-terminal-pty-transport-swift.sh` exit 0
- `test-terminal-vt-visuals.sh` exit 0
- `test-terminal-metal.sh` exit 0

## Mutations (`mut/`)
- Ordering fix reverted (`if false && DispatchQueue.getSpecific(...)`): exit 1, O1 (both checks) and O2 fail with "ba"/reordered streams; D tests pass (`mut/mutA-ordering.log`).
- Drop fix reverted (`writeInteractive` uses `interactive: false`): exit 1, 4 D1 checks fail (key, focus, mouse, DSR reply) plus 3 D2 checks; O tests pass (`mut/mutB-drop.log`).
- Both restored. The files were diffed against the saved fixed copies and are identical.

## Unverified / residual risk
- No `xcodebuild`, GUI or UI test was run. The app target and `TerminalVTSession`/`TerminalVTView` were not compiled; the API change is additive (a defaulted parameter, new members), so they should be unaffected.
- The `onInputDropped` UI surfacing and Session wiring are not done.
- The tests that pass depend on shell/`cat` timing (bounded `eventually` waits of 4-10 s). They passed 4 out of 4 times after the fix.
- The `stty raw ... cat` fixture relies on macOS PTY semantics. The kernel PTY buffer absorbed about 1 KiB before back-pressure, and tests do not assume that exact number.
- Ordering across two racing caller threads, and the write-error (EIO) path in isolation, are not covered.
- The Swift async-lock warnings in the smoke build are pre-existing.

## Deviations from the brief
- `scripts/terminal-vt-backend-fixture.c`, `scripts/test-terminal-vt-backend.sh` and `scripts/terminal-pty-transport-swift-smoke.swift` were not changed. The new tests use `/bin/sh` scripts with `cat` and gate files, so no C fixture change was needed.
- D2/D3 could not be run against the baseline because they need the new accessors. The baseline failure evidence covers O1, O2 and D1 only.
- `report.md` and `patch.diff` are the only files added to the deliverables dir besides logs and helper scripts (`rungates.sh`, `run3.sh`, `mutA.sh`, `mutB.sh`).

---
# Addendum: committed typed text (IME / multi-character insertText)

## Gap
`TerminalVTView.insertText` (`TerminalVTView.swift:335`) sent committed multi-character text via `session.sendRaw`, then `TerminalVTSession.sendRaw` (`_ = backend.sendRaw`), then the bulk 256 KiB limit. It was silently dropped while a paste held the admission.

## Test first (`typed-fail.log`, exit=1)
The new `typedTextKeepsOrderAndSurvivesFullPasteBudget` (T1/T2) was run with its `typed(...)` helper pointing at `backend.sendRaw`, which is what the View called. Five T2 checks failed on the then-current lane state, so the failures are behavioural, not compile errors:
- committed text refused while a paste held the admission
- typed text within the allowance refused
- refusal beyond the allowance not counted or reported
- admission not bounded at limit+allowance
- delivered stream differs from the admitted bytes

T1 (order of encodeKey vs typed text, with the queue stalled, then 300 mixed tokens) already passed on `sendRaw`, thanks to the earlier ordering fix. It is a regression guard for the new path, not a failing test.

## Fix
- `TerminalVTBackend.swift:119`, new `sendTyped(_:) -> Bool`:
  - It calls `writeInteractive(data)`, i.e. `transport.write(data, interactive: true)`, with the same `scrollToBottom`/`scheduleFrame` follow-up as `sendRaw`.
  - A refusal while the transport is accepting input is counted (`droppedInteractiveBytes`) and reported through `onInputDropped`. That callback now runs on the caller thread for this path, and the doc comment says so.
  - It returns whether the bytes were accepted.
- `writeInteractive` now returns `Bool` and is documented as callable from any thread. Its behaviour is unchanged for the queue-internal callers.
- `TerminalVTSession.swift:92`: `sendTyped` forwards to the backend. `TerminalVTView.swift:335`: `insertText` uses `session?.sendTyped`. Both are one-line changes.
- Unchanged: `sendRaw`, `send(data:)` and the `TerminalBackend` protocol (programmatic sends stay bulk). The single-character key path (`session.encode`, then `encodeKey`) was already interactive.
- `onInputDropped` is still not wired to any UI, per the coordinator; overflow drops are only counted. This is a product decision left open.

## Verification
| Check | Result |
|---|---|
| `test-terminal-vt-backend.sh` x3 | exit 0, 0, 0 (`gates/typed-backend-run{1,2,3}.log`) |
| `test-terminal-vt-host.sh` | exit 0 (compiles `TerminalVTView` + `TerminalVTSession`) |
| `test-terminal-vt-visuals.sh` | exit 0 (compiles `TerminalVTView` + `TerminalVTSession`) |
| `test-terminal-pty-transport-swift.sh` | exit 0 |
| Mutation: `sendTyped` uses bulk `transport.write(data)` | exit 1, the same 5 T2 checks fail (`mut/mutC-typed.log`); restored and diffed identical |

The other gates (core, core-asan, pty-transport, metal) were not re-run; their inputs did not change in this step.

## Residual
- The full app target and UI tests were still not built or run.
- `typedTextKeepsOrderAndSurvivesFullPasteBudget` T1 does not fail on either variant; ordering is mutation-checked by `mutA` (`mut/mutA-ordering.log`) only.
- `patch.diff` was regenerated and covers 5 files (+273/-13): `TerminalPTYTransport.swift`, `TerminalVTBackend.swift`, `TerminalVTSession.swift`, `TerminalVTView.swift` and `scripts/terminal-vt-backend-smoke.swift`.
