# Mixed Unicode diagnostic batch (not an acceptance baseline)

Six alternating pairs; 10,000 plain UTF-8/CRLF lines, 510,000 bytes, identical fixture SHA256 4195511c3237c5d36c1b5f1ad82c19b3db5cbc03ec6e4aac83185cfb2fa744da. Two warmups and reset per fresh App. 134×45 ready grid. All measured write/DSR intervals fell inside the sampled App CPU envelope.

**Configuration mismatch discovered after collection:** frozen legacy contains coverage instrumentation; VT does not. This batch is retained for diagnosis only. It neither confirms nor disproves the older colored-Unicode three-run result. Actual fallback, exact intermediate displayed work and full retained history were not proven equal.

| Pair | Backend | App CPU s | Envelope s | Write + DSR round trip ms | Final sampled RSS MiB | Sampled maximum RSS MiB |
|---:|---|---:|---:|---:|---:|---:|
| 1 | legacy | 0.027935 | 4.9973 | 9.432 | 145.81 | 145.81 |
| 1 | vt | 0.029815 | 4.9976 | 4.311 | 162.41 | 164.55 |
| 2 | legacy | 0.025464 | 4.9576 | 9.385 | 139.91 | 139.95 |
| 2 | vt | 0.033325 | 4.9550 | 4.752 | 162.27 | 164.45 |
| 3 | legacy | 0.019385 | 4.9683 | 6.561 | 143.12 | 143.22 |
| 3 | vt | 0.031643 | 4.9638 | 4.397 | 154.58 | 156.77 |
| 4 | legacy | 0.033374 | 4.9970 | 10.945 | 145.59 | 145.64 |
| 4 | vt | 0.031814 | 4.9967 | 5.355 | 160.69 | 162.83 |
| 5 | legacy | 0.051682 | 4.9851 | 14.604 | 139.52 | 139.56 |
| 5 | vt | 0.174823 | 4.9654 | 6.319 | 174.92 | 186.86 |
| 6 | legacy | 0.035209 | 4.9658 | 9.054 | 139.67 | 139.72 |
| 6 | vt | 0.026870 | 4.9636 | 3.530 | 154.81 | 160.03 |

RSS maximum is discrete sampled maximum, not a reliable peak. Final RSS is one sample, not proven stable retained memory. DSR is write/parse/query/reply round trip, not presentation or input-to-display latency. CPU is App only; generator CPU is not included.

VT pair 5 consumed 0.174823 CPU seconds; 0.168581 CPU seconds occurred after the first sample following the DSR reply (that sample was 5.895 ms after reply). This establishes delayed App work in the envelope, not its function or cause. Keep the outlier; no exclusion reason has been established.

The version-bound batch command exited 0 but record result is revision_changed because default.profraw changed. Do not relabel the historical record as passed. Raw per-run samples, commands, DSR results, ancestry, AX and PNG files remain in mixed-matrix-02/.
