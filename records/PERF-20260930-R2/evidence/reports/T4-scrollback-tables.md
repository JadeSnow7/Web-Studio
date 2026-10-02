
**workload=ascii, lines fed=10000** (medians of 15 fresh-process runs = 3 batches x 5)

| config | effective MAX_BYTES / MAX_LINES | retained rows (med) | footprint delta MB after feed (med) | after free MB | feed CPU s/MiB | resize step ms med / max single | resize total ms (12 steps, med) | rows after 12 resizes | snapshot µs (empty→full) |
|---|---|---|---|---|---|---|---|---|---|
| default | 10000 / unlimited | 398 | 2.29 | 1.56 | 0.00065 | 0.057 / 0.156 | 0.72 | 398 | 132→134 |
| bytes_1MB | 1000000 / unlimited | 398 | 2.28 | 1.54 | 0.00066 | 0.057 / 0.145 | 0.70 | 398 | 134→137 |
| bytes_4MB | 4000000 / unlimited | 2876 | 5.18 | 1.56 | 0.00077 | 0.287 / 0.433 | 3.20 | 2876 | 132→134 |
| bytes_10MB | 10000000 / unlimited | 8186 | 11.03 | 1.56 | 0.00107 | 0.816 / 1.562 | 9.62 | 8186 | 133→136 |
| bytes_25MB | 25000000 / unlimited | 9956 | 12.62 | 1.59 | 0.00117 | 1.022 / 29.885 | 11.90 | 9956 | 134→135 |
| bytes_50MB | 50000000 / unlimited | 9956 | 12.60 | 1.57 | 0.00112 | 1.006 / 11.809 | 11.66 | 9956 | 133→136 |
| lines_10000_only | 10000 / 10000 | 398 | 2.29 | 1.56 | 0.00065 | 0.058 / 0.142 | 0.72 | 398 | 134→135 |
| lines_10000_nobytes | unlimited / 10000 | 9956 | 12.62 | 1.57 | 0.00110 | 0.482 / 9.391 | 6.25 | 4908 | 133→133 |
| lines_50000_nobytes | unlimited / 50000 | 9956 | 12.62 | 1.57 | 0.00110 | 1.014 / 4.979 | 12.22 | 9956 | 133→137 |
| lines_100000_nobytes | unlimited / 100000 | 9956 | 12.60 | 1.57 | 0.00119 | 1.016 / 2.400 | 12.19 | 9956 | 130→135 |

**workload=ascii, lines fed=50000** (medians of 15 fresh-process runs = 3 batches x 5)

| config | effective MAX_BYTES / MAX_LINES | retained rows (med) | footprint delta MB after feed (med) | after free MB | feed CPU s/MiB | resize step ms med / max single | resize total ms (12 steps, med) | rows after 12 resizes | snapshot µs (empty→full) |
|---|---|---|---|---|---|---|---|---|---|
| default | 10000 / unlimited | 396 | 1.57 | 0.79 | 0.00062 | 0.059 / 0.779 | 0.73 | 396 | 131→136 |
| bytes_1MB | 1000000 / unlimited | 396 | 1.56 | 0.77 | 0.00063 | 0.058 / 0.122 | 0.68 | 396 | 134→135 |
| bytes_4MB | 4000000 / unlimited | 2874 | 4.44 | 0.79 | 0.00067 | 0.291 / 0.788 | 3.53 | 2874 | 134→140 |
| bytes_10MB | 10000000 / unlimited | 8184 | 10.58 | 0.79 | 0.00072 | 0.815 / 3.210 | 9.25 | 8184 | 134→135 |
| bytes_25MB | 25000000 / unlimited | 21282 | 25.77 | 0.82 | 0.00094 | 2.179 / 5.536 | 26.44 | 21282 | 131→134 |
| bytes_50MB | 50000000 / unlimited | 42876 | 49.14 | 0.87 | 0.00117 | 4.619 / 12.128 | 57.31 | 42876 | 135→137 |
| lines_10000_only | 10000 / 10000 | 396 | 1.56 | 0.77 | 0.00063 | 0.060 / 0.146 | 0.73 | 396 | 133→136 |
| lines_10000_nobytes | unlimited / 10000 | 9954 | 12.63 | 0.80 | 0.00100 | 0.479 / 1.517 | 6.08 | 4906 | 133→135 |
| lines_50000_nobytes | unlimited / 50000 | 49956 | 56.39 | 0.88 | 0.00125 | 2.635 / 13.590 | 36.71 | 24933 | 132→136 |
| lines_100000_nobytes | unlimited / 100000 | 49956 | 56.39 | 0.88 | 0.00122 | 5.256 / 11.817 | 65.05 | 49956 | 131→134 |

**workload=ascii, lines fed=100000** (medians of 15 fresh-process runs = 3 batches x 5)

| config | effective MAX_BYTES / MAX_LINES | retained rows (med) | footprint delta MB after feed (med) | after free MB | feed CPU s/MiB | resize step ms med / max single | resize total ms (12 steps, med) | rows after 12 resizes | snapshot µs (empty→full) |
|---|---|---|---|---|---|---|---|---|---|
| default | 10000 / unlimited | 482 | 1.56 | 0.79 | 0.00065 | 0.064 / 0.264 | 0.77 | 482 | 133→135 |
| bytes_1MB | 1000000 / unlimited | 482 | 1.56 | 0.77 | 0.00062 | 0.063 / 0.111 | 0.78 | 482 | 133→134 |
| bytes_4MB | 4000000 / unlimited | 2960 | 4.44 | 0.79 | 0.00064 | 0.288 / 0.437 | 3.30 | 2960 | 132→133 |
| bytes_10MB | 10000000 / unlimited | 8270 | 10.58 | 0.79 | 0.00068 | 0.825 / 1.370 | 9.45 | 8270 | 132→135 |
| bytes_25MB | 25000000 / unlimited | 21368 | 25.77 | 0.82 | 0.00080 | 2.166 / 4.158 | 25.27 | 21368 | 133→136 |
| bytes_50MB | 50000000 / unlimited | 42962 | 50.81 | 0.87 | 0.00093 | 4.564 / 13.510 | 55.60 | 42962 | 133→135 |
| lines_10000_only | 10000 / 10000 | 482 | 1.56 | 0.77 | 0.00062 | 0.064 / 0.189 | 0.77 | 482 | 138→137 |
| lines_10000_nobytes | unlimited / 10000 | 9686 | 12.24 | 0.80 | 0.00099 | 0.475 / 1.969 | 5.82 | 4857 | 133→136 |
| lines_50000_nobytes | unlimited / 50000 | 49688 | 58.61 | 0.88 | 0.00118 | 2.647 / 13.763 | 35.84 | 24885 | 134→134 |
| lines_100000_nobytes | unlimited / 100000 | 99956 | 112.05 | 1.03 | 0.00128 | 5.260 / 30.551 | 86.68 | 49910 | 133→135 |

**workload=mixed, lines fed=10000** (medians of 15 fresh-process runs = 3 batches x 5)

| config | effective MAX_BYTES / MAX_LINES | retained rows (med) | footprint delta MB after feed (med) | after free MB | feed CPU s/MiB | resize step ms med / max single | resize total ms (12 steps, med) | rows after 12 resizes | snapshot µs (empty→full) |
|---|---|---|---|---|---|---|---|---|---|
| default | 10000 / unlimited | 398 | 1.46 | 0.97 | 0.00668 | 0.245 / 0.730 | 3.07 | 398 | 133→144 |
| bytes_1MB | 1000000 / unlimited | 398 | 1.44 | 0.95 | 0.00695 | 0.234 / 0.865 | 3.08 | 398 | 134→143 |
| bytes_4MB | 4000000 / unlimited | 2168 | 4.05 | 0.97 | 0.00669 | 1.311 / 4.252 | 17.60 | 2168 | 130→144 |
| bytes_10MB | 10000000 / unlimited | 6062 | 9.85 | 0.97 | 0.00667 | 3.962 / 15.099 | 51.54 | 6062 | 134→141 |
| bytes_25MB | 25000000 / unlimited | 9956 | 15.61 | 0.98 | 0.00671 | 6.657 / 22.198 | 86.83 | 9956 | 134→148 |
| bytes_50MB | 50000000 / unlimited | 9956 | 15.61 | 0.98 | 0.00664 | 6.682 / 19.860 | 85.16 | 9956 | 133→146 |
| lines_10000_only | 10000 / 10000 | 398 | 1.43 | 0.95 | 0.00663 | 0.234 / 0.807 | 3.08 | 398 | 134→145 |
| lines_10000_nobytes | unlimited / 10000 | 9956 | 15.61 | 0.98 | 0.00669 | 3.151 / 10.894 | 44.38 | 4812 | 134→143 |
| lines_50000_nobytes | unlimited / 50000 | 9956 | 15.61 | 0.98 | 0.00667 | 6.768 / 24.540 | 85.91 | 9956 | 132→145 |
| lines_100000_nobytes | unlimited / 100000 | 9956 | 15.61 | 0.98 | 0.00672 | 6.723 / 28.945 | 87.10 | 9956 | 134→144 |

**workload=mixed, lines fed=50000** (medians of 15 fresh-process runs = 3 batches x 5)

| config | effective MAX_BYTES / MAX_LINES | retained rows (med) | footprint delta MB after feed (med) | after free MB | feed CPU s/MiB | resize step ms med / max single | resize total ms (12 steps, med) | rows after 12 resizes | snapshot µs (empty→full) |
|---|---|---|---|---|---|---|---|---|---|
| default | 10000 / unlimited | 396 | 1.46 | 0.98 | 0.00731 | 0.242 / 0.856 | 3.22 | 396 | 134→147 |
| bytes_1MB | 1000000 / unlimited | 396 | 1.44 | 0.95 | 0.00675 | 0.232 / 0.730 | 3.07 | 396 | 137→146 |
| bytes_4MB | 4000000 / unlimited | 2166 | 4.06 | 0.95 | 0.00689 | 1.392 / 6.458 | 18.57 | 2166 | 132→148 |
| bytes_10MB | 10000000 / unlimited | 6060 | 9.85 | 0.98 | 0.00673 | 4.032 / 15.872 | 51.40 | 6060 | 139→143 |
| bytes_25MB | 25000000 / unlimited | 15972 | 24.54 | 1.02 | 0.00674 | 11.102 / 42.210 | 149.59 | 15972 | 133→149 |
| bytes_50MB | 50000000 / unlimited | 32256 | 48.69 | 1.05 | 0.00673 | 23.102 / 76.742 | 308.44 | 32256 | 130→143 |
| lines_10000_only | 10000 / 10000 | 396 | 1.44 | 0.97 | 0.00669 | 0.236 / 1.030 | 3.08 | 396 | 134→143 |
| lines_10000_nobytes | unlimited / 10000 | 9954 | 15.61 | 1.00 | 0.00689 | 3.220 / 11.893 | 46.75 | 4814 | 134→148 |
| lines_50000_nobytes | unlimited / 50000 | 49956 | 74.94 | 1.08 | 0.00681 | 17.688 / 104.676 | 250.37 | 24920 | 132→144 |
| lines_100000_nobytes | unlimited / 100000 | 49956 | 74.94 | 1.08 | 0.00674 | 35.627 / 306.088 | 479.70 | 49956 | 133→146 |

**workload=mixed, lines fed=100000** (medians of 15 fresh-process runs = 3 batches x 5)

| config | effective MAX_BYTES / MAX_LINES | retained rows (med) | footprint delta MB after feed (med) | after free MB | feed CPU s/MiB | resize step ms med / max single | resize total ms (12 steps, med) | rows after 12 resizes | snapshot µs (empty→full) |
|---|---|---|---|---|---|---|---|---|---|
| default | 10000 / unlimited | 482 | 1.59 | 0.97 | 0.00681 | 0.293 / 0.950 | 3.82 | 482 | 133→144 |
| bytes_1MB | 1000000 / unlimited | 482 | 1.57 | 0.97 | 0.00677 | 0.295 / 0.959 | 3.69 | 482 | 132→144 |
| bytes_4MB | 4000000 / unlimited | 2252 | 4.21 | 0.98 | 0.00690 | 1.432 / 5.652 | 18.54 | 2252 | 131→145 |
| bytes_10MB | 10000000 / unlimited | 6146 | 9.98 | 0.98 | 0.00676 | 4.059 / 14.939 | 53.23 | 6146 | 134→144 |
| bytes_25MB | 25000000 / unlimited | 16058 | 24.69 | 1.02 | 0.00678 | 11.097 / 39.194 | 147.71 | 16058 | 133→145 |
| bytes_50MB | 50000000 / unlimited | 32342 | 48.84 | 1.05 | 0.00702 | 22.627 / 74.658 | 291.38 | 32342 | 134→144 |
| lines_10000_only | 10000 / 10000 | 482 | 1.57 | 0.97 | 0.00667 | 0.275 / 1.028 | 3.59 | 482 | 131→143 |
| lines_10000_nobytes | unlimited / 10000 | 9686 | 15.24 | 1.00 | 0.00681 | 3.146 / 10.001 | 45.05 | 4769 | 134→147 |
| lines_50000_nobytes | unlimited / 50000 | 49688 | 74.56 | 1.08 | 0.00683 | 17.152 / 58.405 | 244.85 | 24880 | 134→144 |
| lines_100000_nobytes | unlimited / 100000 | 99956 | 149.11 | 1.20 | 0.00671 | 34.467 / 202.941 | 488.58 | 49888 | 130→142 |

**workload=mixed44, lines fed=100000** (medians of 5 fresh-process runs = 3 batches x 5)

| config | effective MAX_BYTES / MAX_LINES | retained rows (med) | footprint delta MB after feed (med) | after free MB | feed CPU s/MiB | resize step ms med / max single | resize total ms (12 steps, med) | rows after 12 resizes | snapshot µs (empty→full) |
|---|---|---|---|---|---|---|---|---|---|
| default | 10000 / unlimited | 482 | 1.44 | 0.98 | 0.00510 | 0.229 / 1.404 | 2.82 | 482 | 183→157 |
| bytes_1MB | 1000000 / unlimited | 482 | 1.41 | 0.97 | 0.00496 | 0.227 / 0.703 | 2.79 | 482 | 144→153 |
| bytes_4MB | 4000000 / unlimited | 2252 | 3.56 | 0.98 | 0.00555 | 1.348 / 3.999 | 19.81 | 2252 | 171→187 |
| bytes_10MB | 10000000 / unlimited | 6146 | 8.26 | 0.98 | 0.00580 | 4.121 / 8.446 | 52.84 | 6146 | 172→183 |
| bytes_25MB | 25000000 / unlimited | 16058 | 20.22 | 1.02 | 0.00577 | 9.239 / 20.406 | 114.39 | 16058 | 171→184 |
| bytes_50MB | 50000000 / unlimited | 32342 | 39.83 | 1.05 | 0.00552 | 20.936 / 40.221 | 249.62 | 32342 | 166→183 |
| lines_10000_only | 10000 / 10000 | 482 | 1.43 | 0.97 | 0.00552 | 0.256 / 0.595 | 3.11 | 482 | 175→181 |
| lines_10000_nobytes | unlimited / 10000 | 9686 | 12.52 | 1.75 | 0.00567 | 2.982 / 11.953 | 37.60 | 4769 | 165→184 |
| lines_50000_nobytes | unlimited / 50000 | 49688 | 60.77 | 1.08 | 0.00541 | 16.427 / 76.207 | 212.25 | 24880 | 155→183 |
| lines_100000_nobytes | unlimited / 100000 | 99956 | 121.32 | 1.20 | 0.00554 | 36.539 / 179.723 | 459.45 | 49894 | 166→183 |

### linear fit footprint(T) = fixed + T x per-terminal (100k lines per terminal, T=1,2,4,8)

| config | workload | fixed MB | per-terminal MB (marginal) | max residual MB | 4 terminals MB | 8 terminals MB |
|---|---|---|---|---|---|---|
| bytes_1MB | ascii | 0.73 | 0.83 | 0.01 | 4.1 | 7.4 |
| bytes_1MB | mixed | 0.73 | 0.85 | 0.01 | 4.1 | 7.5 |
| bytes_4MB | ascii | 1.11 | 3.66 | 0.49 | 15.7 | 30.4 |
| bytes_4MB | mixed | 0.74 | 3.47 | 0.01 | 14.6 | 28.5 |
| bytes_10MB | ascii | 0.74 | 9.86 | 0.02 | 40.2 | 79.6 |
| bytes_10MB | mixed | 0.74 | 9.25 | 0.01 | 37.7 | 74.7 |
| bytes_25MB | ascii | 0.75 | 25.04 | 0.03 | 100.9 | 201.1 |
| bytes_25MB | mixed | 0.74 | 23.95 | 0.02 | 96.6 | 192.4 |
| bytes_50MB | ascii | 1.07 | 50.03 | 0.49 | 201.2 | 401.3 |
| bytes_50MB | mixed | 0.74 | 48.11 | 0.01 | 193.2 | 385.6 |

### multi-terminal (100k lines per terminal)

| config | workload | T | footprint MB total (med) | per terminal MB | single-terminal MB | ratio total/(T*single) |
|---|---|---|---|---|---|---|
| bytes_1MB | ascii | 2 | 2.41 | 1.20 | 1.56 | 0.774 |
| bytes_1MB | ascii | 4 | 4.05 | 1.01 | 1.56 | 0.650 |
| bytes_1MB | ascii | 8 | 7.39 | 0.92 | 1.56 | 0.593 |
| bytes_1MB | mixed | 2 | 2.44 | 1.22 | 1.57 | 0.776 |
| bytes_1MB | mixed | 4 | 4.13 | 1.03 | 1.57 | 0.656 |
| bytes_1MB | mixed | 8 | 7.54 | 0.94 | 1.57 | 0.599 |
| bytes_4MB | ascii | 2 | 8.91 | 4.46 | 4.44 | 1.004 |
| bytes_4MB | ascii | 4 | 15.56 | 3.89 | 4.44 | 0.876 |
| bytes_4MB | ascii | 8 | 30.36 | 3.79 | 4.44 | 0.855 |
| bytes_4MB | mixed | 2 | 7.70 | 3.85 | 4.21 | 0.914 |
| bytes_4MB | mixed | 4 | 14.63 | 3.66 | 4.21 | 0.869 |
| bytes_4MB | mixed | 8 | 28.54 | 3.57 | 4.21 | 0.847 |
| bytes_10MB | ascii | 2 | 20.48 | 10.24 | 10.58 | 0.967 |
| bytes_10MB | ascii | 4 | 40.17 | 10.04 | 10.58 | 0.949 |
| bytes_10MB | ascii | 8 | 79.61 | 9.95 | 10.58 | 0.940 |
| bytes_10MB | mixed | 2 | 19.25 | 9.63 | 9.98 | 0.965 |
| bytes_10MB | mixed | 4 | 37.73 | 9.43 | 9.98 | 0.945 |
| bytes_10MB | mixed | 8 | 74.74 | 9.34 | 9.98 | 0.936 |
| bytes_25MB | ascii | 2 | 50.86 | 25.43 | 25.77 | 0.987 |
| bytes_25MB | ascii | 4 | 100.89 | 25.22 | 25.77 | 0.979 |
| bytes_25MB | ascii | 8 | 201.06 | 25.13 | 25.77 | 0.975 |
| bytes_25MB | mixed | 2 | 48.66 | 24.33 | 24.69 | 0.985 |
| bytes_25MB | mixed | 4 | 96.53 | 24.13 | 24.69 | 0.977 |
| bytes_25MB | mixed | 8 | 192.36 | 24.05 | 24.69 | 0.974 |
| bytes_50MB | ascii | 2 | 101.63 | 50.82 | 50.81 | 1.000 |
| bytes_50MB | ascii | 4 | 201.00 | 50.25 | 50.81 | 0.989 |
| bytes_50MB | ascii | 8 | 401.36 | 50.17 | 50.81 | 0.987 |
| bytes_50MB | mixed | 2 | 96.96 | 48.48 | 48.84 | 0.993 |
| bytes_50MB | mixed | 4 | 193.15 | 48.29 | 48.84 | 0.989 |
| bytes_50MB | mixed | 8 | 385.60 | 48.20 | 48.84 | 0.987 |
