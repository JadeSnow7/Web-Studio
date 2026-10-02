# Clean Release idle results

Six alternating paired repeats, each fresh process/session, 2 warmups then reset + 10000 mixed lines, 20-second idle. No builds/profilers/AX within samples. UI/geometry checks before sample, final content captures after it. No exclusions.

| Scenario | Backend | n | CPU seconds median | Single-core % median [min,max] | Last sampled RSS MiB median |
|---|---|---:|---:|---|---:|
| visible-idle | vt | 6 | 0.047190 | 0.2362 [0.1847,0.9365] | 156.812 |
| visible-idle | legacy | 6 | 0.071949 | 0.3602 [0.2142,0.5382] | 143.742 |
| hidden-idle | vt | 6 | 0.019499 | 0.0976 [0.0734,0.1065] | 157.539 |
| hidden-idle | legacy | 6 | 0.049285 | 0.2469 [0.2315,0.4567] | 138.023 |

| Scenario | Pair | VT CPU s | Legacy CPU s | VT minus legacy s |
|---|---:|---:|---:|---:|
| visible-idle | 1 | 0.187279 | 0.080547 | +0.106731 |
| visible-idle | 2 | 0.161147 | 0.107452 | +0.053694 |
| visible-idle | 3 | 0.036887 | 0.071393 | -0.034506 |
| visible-idle | 4 | 0.039024 | 0.072505 | -0.033481 |
| visible-idle | 5 | 0.049547 | 0.045196 | +0.004351 |
| visible-idle | 6 | 0.044832 | 0.042830 | +0.002003 |
| hidden-idle | 1 | 0.021272 | 0.091294 | -0.070022 |
| hidden-idle | 2 | 0.019876 | 0.085288 | -0.065412 |
| hidden-idle | 3 | 0.015919 | 0.048565 | -0.032646 |
| hidden-idle | 4 | 0.019194 | 0.048276 | -0.029082 |
| hidden-idle | 5 | 0.014661 | 0.050004 | -0.035343 |
| hidden-idle | 6 | 0.019803 | 0.046283 | -0.026479 |

Raw runs: clean-idle-matrix-04/. Full samples, expected identity, 3 verified fixture loads, window visibility, background snapshots and result index: clean-idle-results.json. Batch version-bound execution: clean-idle-matrix-execution-v4.json (passed). Observer/RSS/thermal/fallback limitations in REPORT.md still apply. No sustained-output-hidden result, no child CPU attribution, no reliable memory peak or retention proof. Visible focus observed before sampling; continuous focus was not instrumented. The one higher VT visible sample remains included. No performance acceptance decision.
