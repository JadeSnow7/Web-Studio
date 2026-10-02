# M2 performance investigation protocol v1

Owner: main thread; tools: coder (scripts/terminal-m2-*). Existing evidence is immutable.

## Conditions and scope
Frozen Release normalized copies are the primary baseline; source build identity must be read from prior build evidence, not inferred from current HEAD. Fresh App/session each measured round. Two warmups, reset history, then ready handshake before sampling. Six pairs per scenario, alternating VT/legacy and legacy/VT. Pilot runs are not pooled. Record each run identity, executable SHA, grid, cell dimensions, font/fallback limits, appearance, scale, focus, visibility, input hash/bytes, actual history and event window.

## Metrics
App user+system CPU seconds from validated proc_pid_rusage, percent = CPU seconds / monotonic elapsed * 100; ps cross-check only. RSS sampled bytes is not peak. Child processes separate. Generator write completion, DSR response round trip, parse completion, and presentation are distinct. No presentation or input latency claim without verified event correlation. AX/screenshots occur outside primary CPU windows; when essential to validate interaction, report observer workload explicitly. Independent tracing/allocation runs never pool with uninstrumented baseline.

## Cases
visible-idle and hidden-idle 20 seconds; ASCII, Chinese and mixed Unicode 10000 lines; scroll 10000-line history with matched actual line traversal; fixed resize sequence; concurrent numbered input/output 20 seconds. Fixtures use deterministic UTF-8 and explicit CRLF with raw tty, SHA256 manifests. Warmup/reset and ready are outside measured windows. Failures, unequal work, out-of-window operations, missing replies, process mismatches, pressure/thermal changes are retained and classified rather than silently discarded.

## Profiling security and limits
Launch measurement/profiler processes with explicit minimal environment; never print inherited environment or raw trace metadata. Raw traces stay in mode-0700 temporary directories. Sanitize exports before reading/archiving and report only validation status. Pilot cap 5 seconds/256 MiB; expanded cap 20 seconds/1 GiB, stop on either bound. Do not sample baseline during tracing/export/cleanup. Zero events is unavailable evidence, nested GPU intervals are not utilization.

## Decisions
Only measured hotspots plus reproducible scenario differences can justify at most two isolated, one-factor optimizations. Verify same instrumentation/configuration for control/variant; correctness and uninstrumented results both required. Otherwise continue investigation without production changes. Performance budgets remain proposed pending user confirmation. Default legacy, no M3, no commits/push/merge/deploy. Preserve manual IME/VoiceOver receipts and unrelated running Apps.
