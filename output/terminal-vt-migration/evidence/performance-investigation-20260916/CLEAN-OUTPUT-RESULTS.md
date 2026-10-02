# Clean Release output results

Six paired repeats per scenario. Both builds explicitly disable ENABLE_CODE_COVERAGE and CLANG_COVERAGE_MAPPING; no LLVM profile symbols in either binary. Version-bound build and batch records passed. These are overall backend measurements with matching requested font/geometry and fixture bytes; actual fallback and intermediate rendering work remain unproven.

| Scenario | Backend | n | CPU seconds median [min, max] | Write + DSR ms median [min, max] | Last sampled RSS MiB median [min, max] |
|---|---|---:|---|---|---|
| ascii | vt | 6 | 0.0271 [0.0212, 0.0288] | 3.4053 [3.0880, 3.8184] | 154.9141 [152.3125, 157.7656] |
| ascii | legacy | 6 | 0.0218 [0.0161, 0.0229] | 6.0522 [5.3307, 6.5207] | 132.6328 [126.3281, 133.9688] |
| chinese | vt | 6 | 0.0257 [0.0217, 0.0269] | 2.6300 [2.2972, 2.8671] | 155.3047 [152.9375, 172.6562] |
| chinese | legacy | 6 | 0.0187 [0.0171, 0.0399] | 4.9432 [4.3550, 6.1623] | 135.8203 [133.9844, 152.5938] |
| mixed | vt | 6 | 0.0290 [0.0279, 0.0444] | 4.0772 [3.8924, 4.7714] | 156.7891 [155.2500, 173.6250] |
| mixed | legacy | 6 | 0.0225 [0.0207, 0.0354] | 8.0317 [6.2077, 14.1668] | 136.9375 [136.3125, 152.7969] |

## All repeats

| Scenario | Pair | VT CPU s | Legacy CPU s | VT minus legacy s |
|---|---:|---:|---:|---:|
| ascii | 1 | 0.021227 | 0.016091 | +0.005136 |
| ascii | 2 | 0.028815 | 0.021895 | +0.006920 |
| ascii | 3 | 0.028075 | 0.022883 | +0.005193 |
| ascii | 4 | 0.024208 | 0.021834 | +0.002374 |
| ascii | 5 | 0.026714 | 0.020756 | +0.005957 |
| ascii | 6 | 0.027422 | 0.021826 | +0.005597 |
| chinese | 1 | 0.021665 | 0.017128 | +0.004537 |
| chinese | 2 | 0.024838 | 0.018413 | +0.006425 |
| chinese | 3 | 0.026485 | 0.017311 | +0.009174 |
| chinese | 4 | 0.026691 | 0.018927 | +0.007764 |
| chinese | 5 | 0.026913 | 0.020977 | +0.005936 |
| chinese | 6 | 0.024698 | 0.039864 | -0.015166 |
| mixed | 1 | 0.027878 | 0.020691 | +0.007187 |
| mixed | 2 | 0.044433 | 0.025683 | +0.018750 |
| mixed | 3 | 0.029791 | 0.035405 | -0.005614 |
| mixed | 4 | 0.028403 | 0.022536 | +0.005867 |
| mixed | 5 | 0.029014 | 0.022459 | +0.006555 |
| mixed | 6 | 0.028941 | 0.022513 | +0.006428 |

All 36 measured intervals fit within their CPU envelope; sampler status valid, expected DSR and 3 loads (2 warmups + measurement) checked. No samples excluded. Raw runs in clean-output-matrix-01/. Detailed values, workload hashes, binary hashes, ancestry, RSS samples and background summaries indexed in clean-output-results.json.

CPU is App user+system delta across approximately 5 seconds, excluding child CPU and not a throughput or display-latency metric. DSR is write plus query round trip, not presentation. RSS is discrete; no reliable allocation peak established. Background CPU uses smoothed ps values and includes other processes; summing RSS does not equal unique physical memory. No-recorded thermal warning is not a measured thermal state.

Terminal final screens were captured while child remained alive. Main inspected final mixed pair: visible numbered rows 009956–009999 plus cursor row match, combining accent/Chinese/rocket appear. This does not establish whole-history identity or identical CoreText/Ghostty fallback. Original colored fixture and accumulated-history protocol differ from this plain/reset protocol, so original 0.15/0.07 seconds is not directly comparable.

No performance acceptance decision; budgets remain proposed. No renderer optimization has been made.
