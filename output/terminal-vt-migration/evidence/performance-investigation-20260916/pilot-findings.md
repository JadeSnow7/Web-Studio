# Live pilot findings

- Real VT Release process 43330, child 44168. Reset DSR returned row=1,column=1. Mixed fixture wrote 510000 bytes and DSR returned row=45,column=1. AX/screenshot independently show final line 009999. These are pipeline feasibility checks, not paired baseline measurements.
- The child used system Python 3.9.6 whose time.monotonic starts near process zero. Controller Python 3.14.6 uses a different monotonic reference. Cross-process events must use explicit CLOCK_MONOTONIC_RAW; old pilot durations are within-child only.
- libproc pilot user+system decoded as 0.064864716 seconds when dividing ticks by 1e9, but ps reports 2.70 seconds for the same process. Ratio approximately 41.6667. CPU unit conversion is blocked pending actual mach_timebase_info verification. RSS 110166016 bytes equals ps 107584 KiB.
- No tool counters from this pilot qualify as final performance evidence. Old three-round measurements used ps and are not retroactively affected by this newly introduced libproc issue.

Corrected CPU cross-check: mach_timebase_info=125/3, libproc total 3.0124609167 s versus ps 3.01 s; RSS bytes/1024 also matches. See counter-pilot-corrected.json. First working Time Profiler invocation produced 44,811,656 bytes but was killed by the 15s wall watchdog during recording/finish; no trace validity conclusion. Original wrapper command placement failure and wall-timeout remain retained.
