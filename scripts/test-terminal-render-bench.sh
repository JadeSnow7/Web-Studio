#!/bin/sh
# Headless render / terminal-core benchmark driver (Release only: swiftc -O, clang -O2).
#   single tree : test-terminal-render-bench.sh --output DIR [--source-root ROOT] [--repetitions N]
#   compare     : test-terminal-render-bench.sh --output DIR --source-root CONTROL --compare-root CANDIDATE [--repetitions N] [--noise-floor results.json]
# ROOT is a tree containing "Web Studio/" and "Vendor/GhosttyVT/" (scripts/module.modulemap is used when present).
# Compare mode runs N alternating pairs (control,candidate | candidate,control | ...) strictly serially.
set -eu
SOURCE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=
COMPARE_ROOT=
REPS=6
NOISE_FLOOR=
USAGE="usage: $0 --output DIR [--source-root ROOT] [--compare-root ROOT2] [--repetitions N] [--noise-floor FILE]"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-root) [ "$#" -ge 2 ] || { echo "missing source root" >&2; exit 64; }; SOURCE_ROOT=$2; shift 2 ;;
    --compare-root) [ "$#" -ge 2 ] || { echo "missing compare root" >&2; exit 64; }; COMPARE_ROOT=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || { echo "missing output" >&2; exit 64; }; OUTPUT=$2; shift 2 ;;
    --repetitions) [ "$#" -ge 2 ] || { echo "missing repetitions" >&2; exit 64; }; REPS=$2; shift 2 ;;
    --noise-floor) [ "$#" -ge 2 ] || { echo "missing noise floor file" >&2; exit 64; }; NOISE_FLOOR=$2; shift 2 ;;
    *) echo "$USAGE" >&2; exit 64 ;;
  esac
done
[ -n "$OUTPUT" ] || { echo "--output is required" >&2; exit 64; }
case "$OUTPUT" in /private/tmp/*) ;; *) echo "output must be under /private/tmp" >&2; exit 64 ;; esac
case "$REPS" in ''|*[!0-9]*) echo "--repetitions must be a positive integer" >&2; exit 64 ;; esac
[ "$REPS" -ge 1 ] || { echo "--repetitions must be >= 1" >&2; exit 64; }
[ ! -e "$OUTPUT" ] || { echo "output exists; refusing overwrite" >&2; exit 64; }
BUILD="${OUTPUT}-build"
[ ! -e "$BUILD" ] || { echo "build output exists; refusing overwrite" >&2; exit 64; }
if [ -n "$NOISE_FLOOR" ]; then [ -f "$NOISE_FLOOR" ] || { echo "noise floor file not found" >&2; exit 64; }; fi
check_root() {
  [ -f "$1/Web Studio/TerminalMetalRenderer.swift" ] && [ -f "$1/Vendor/GhosttyVT/lib/libghostty-vt.a" ] || { echo "not a source root: $1" >&2; exit 64; }
}
check_root "$SOURCE_ROOT"
SOURCE_ROOT=$(CDPATH= cd -P -- "$SOURCE_ROOT" && pwd)
if [ -n "$COMPARE_ROOT" ]; then check_root "$COMPARE_ROOT"; COMPARE_ROOT=$(CDPATH= cd -P -- "$COMPARE_ROOT" && pwd); fi
mkdir -p "$BUILD"
mkdir -m 700 "$OUTPUT"

# build_tree LABEL ROOT BUILD_DIR  -> BUILD_DIR/terminal-render-bench + build-manifest.json
build_tree() {
  label=$1; root=$2; bdir=$3
  mkdir -p "$bdir/module-cache"
  moddir="$root/scripts"
  if [ ! -f "$moddir/module.modulemap" ]; then
    moddir="$bdir/modulemap"; mkdir -p "$moddir"
    printf 'module StudioVTCoreC { header "%s/Web Studio/StudioVTCore.h" export * }\n' "$root" > "$moddir/module.modulemap"
  fi
  clang -O2 -std=c11 -DWEB_STUDIO_VT -DGHOSTTY_STATIC \
    -I"$root/Vendor/GhosttyVT/include" -I"$root/Web Studio" \
    -c "$root/Web Studio/StudioVTCore.c" -o "$bdir/studio-vt-core.o"
  swiftc -O -DWEB_STUDIO_VT -module-cache-path "$bdir/module-cache" \
    -I"$moddir" -Xcc -DWEB_STUDIO_VT -Xcc -I -Xcc "$root/Vendor/GhosttyVT/include" \
    "$root/Web Studio/TerminalVTCore.swift" \
    "$root/Web Studio/TerminalVisuals.swift" \
    "$root/Web Studio/TerminalMetalRenderer.swift" \
    "$SCRIPT_ROOT/terminal-render-bench.swift" \
    "$bdir/studio-vt-core.o" "$root/Vendor/GhosttyVT/lib/libghostty-vt.a" \
    -framework Metal -framework MetalKit -framework AppKit -framework CoreText \
    -framework Security -framework CoreServices -framework Foundation -framework CoreFoundation \
    -o "$bdir/terminal-render-bench"
  src_hash=$(shasum -a 256 \
    "$SCRIPT_ROOT/terminal-render-bench.swift" \
    "$root/Web Studio/TerminalVTCore.swift" \
    "$root/Web Studio/TerminalVisuals.swift" \
    "$root/Web Studio/TerminalMetalRenderer.swift" \
    "$root/Web Studio/StudioVTCore.c" | shasum -a 256 | awk '{print $1}')
  bin_hash=$(shasum -a 256 "$bdir/terminal-render-bench" | awk '{print $1}')
  cat > "$bdir/build-manifest.json" <<EOF
{"label":"$label","configuration":"Release","optimization":"swiftc -O; clang -O2","source_root":"$root","source_digest":"$src_hash","binary_sha256":"$bin_hash","binary":"$bdir/terminal-render-bench"}
EOF
  cp "$bdir/build-manifest.json" "$OUTPUT/build-manifest-$label.json"
}

digest_of() { sed -n 's/.*"source_digest":"\([0-9a-f]*\)".*/\1/p' "$1/build-manifest.json"; }

if [ -n "$COMPARE_ROOT" ]; then
  build_tree control "$SOURCE_ROOT" "$BUILD/control"
  build_tree candidate "$COMPARE_ROOT" "$BUILD/candidate"
else
  build_tree tree "$SOURCE_ROOT" "$BUILD/tree"
fi

# run_one BUILD_DIR LABEL REP OUTFILE
run_one() {
  echo "run $2 repetition $3"
  "$1/terminal-render-bench" --output "$4" --repetition "$3" --label "$2" --source-digest "$(digest_of "$1")"
  sleep 1
}

if [ -n "$COMPARE_ROOT" ]; then
  mkdir -p "$OUTPUT/pairs"
  : > "$OUTPUT/pairs/order.txt"
  i=1
  while [ "$i" -le "$REPS" ]; do
    n=$(printf '%02d' "$i")
    if [ $((i % 2)) -eq 1 ]; then first=control; second=candidate; else first=candidate; second=control; fi
    echo "pair $n: $first then $second" | tee -a "$OUTPUT/pairs/order.txt"
    run_one "$BUILD/$first" "$first" "$i" "$OUTPUT/pairs/pair-$n-$first.json"
    run_one "$BUILD/$second" "$second" "$i" "$OUTPUT/pairs/pair-$n-$second.json"
    i=$((i + 1))
  done
  MODE=compare
else
  mkdir -p "$OUTPUT/raw"
  i=1
  while [ "$i" -le "$REPS" ]; do
    run_one "$BUILD/tree" tree "$i" "$OUTPUT/raw/rep-$(printf '%02d' "$i").json"
    i=$((i + 1))
  done
  MODE=single
fi

cat > "$OUTPUT/summarize.py" <<'PYEOF'
#!/usr/bin/env python3
"""Summarize terminal-render-bench raw repetitions. All time values are seconds (lower is better)."""
import glob, json, os, statistics, sys

mode, out = sys.argv[1], sys.argv[2]
noise_file = sys.argv[3] if len(sys.argv) > 3 else None
load = lambda p: json.load(open(p))
med = statistics.median

def stats(v):
    m = med(v)
    return {"values": v, "median": m, "min": min(v), "max": max(v),
            "spread_rel": ((max(v) - min(v)) / m) if m > 0 else None}

def hash_summary(reps_hashes):
    res = {}
    for k in sorted(reps_hashes[0]):
        vals = [h[k] for h in reps_hashes]
        res[k] = {"sha256": vals[0] if len(set(vals)) == 1 else None, "stable_across_repetitions": len(set(vals)) == 1, "values": vals}
    return res

def env(reps):
    return [{"repetition": r["repetition"], "thermal_state": r["environment"]["thermal_state"], "low_power_mode": r["environment"]["low_power_mode"],
             "loadavg_before": r["environment"]["loadavg_before"], "loadavg_after": r["environment"]["loadavg_after"], "gate_retries": r["config"]["render_gate_retries"]} for r in reps]

manifests = {os.path.basename(p)[len("build-manifest-"):-5]: load(p) for p in glob.glob(os.path.join(out, "build-manifest-*.json"))}

if mode == "single":
    reps = [load(p) for p in sorted(glob.glob(os.path.join(out, "raw", "rep-*.json")))]
    keys = sorted(reps[0]["scalars"])
    result = {
        "schema": "terminal-render-bench.summary.v1", "mode": "single", "repetitions": len(reps), "builds": manifests,
        "config": reps[0]["config"], "metrics": {k: stats([r["scalars"][k] for r in reps]) for k in keys},
        "pixel_hashes": hash_summary([r["hashes"] for r in reps]), "validation": reps[0]["validation"], "environment": env(reps),
    }
    json.dump(result, open(os.path.join(out, "results.json"), "w"), indent=2, sort_keys=True)
    print("%-52s %12s %12s %12s %8s" % ("metric", "median", "min", "max", "spread"))
    for k in keys:
        s = result["metrics"][k]
        print("%-52s %12.6f %12.6f %12.6f %7.1f%%" % (k, s["median"], s["min"], s["max"], 100 * (s["spread_rel"] or 0)))
    bad = [k for k, v in result["pixel_hashes"].items() if not v["stable_across_repetitions"]]
    print("pixel hashes: %d keys, unstable across repetitions: %s" % (len(result["pixel_hashes"]), bad or "none"))
else:
    order = [l.strip() for l in open(os.path.join(out, "pairs", "order.txt")) if l.strip()]
    pairs = []
    for p in sorted(glob.glob(os.path.join(out, "pairs", "pair-*-control.json"))):
        pairs.append((load(p), load(p.replace("-control.json", "-candidate.json"))))
    noise = load(noise_file)["noise_floor"] if noise_file else None
    keys = sorted(pairs[0][0]["scalars"])
    metrics = {}
    counts = {"improvement": 0, "regression": 0, "within_noise_or_mixed": 0}
    for k in keys:
        c = [a["scalars"][k] for a, _ in pairs]
        d = [b["scalars"][k] for _, b in pairs]
        rel = [((y - x) / x) if x > 0 else None for x, y in zip(c, d)]
        rr = [r for r in rel if r is not None]
        m = {"control": stats(c), "candidate": stats(d), "pair_rel_delta": rel,
             "median_ratio_candidate_over_control": (med(d) / med(c)) if med(c) > 0 else None,
             "median_rel_delta": ((med(d) - med(c)) / med(c)) if med(c) > 0 else None,
             "paired_delta_median": med(rr) if rr else None,
             "max_abs_pair_rel_delta": max(abs(r) for r in rr) if rr else None,
             "pairs_improved": sum(1 for x, y in zip(c, d) if y < x), "pairs_worse": sum(1 for x, y in zip(c, d) if y > x), "pairs": len(pairs)}
        m["unreliable_pair_delta_gt_30pct"] = bool(m["max_abs_pair_rel_delta"] is not None and m["max_abs_pair_rel_delta"] > 0.30)
        if noise and k in noise:
            nf = noise[k]["max_abs_pair_rel_delta"] or 0.0
            md = m["median_rel_delta"] or 0.0
            n = len(pairs)
            need = n - 1
            if m["pairs_worse"] >= need and md > nf: v = "regression"
            elif m["pairs_improved"] >= need and md < -nf: v = "improvement"
            else: v = "within_noise_or_mixed"
            m["baseline_noise_floor_max_abs_rel"] = nf
            m["verdict_vs_noise_floor"] = v
            counts[v] += 1
        metrics[k] = m
    hashes = {}
    for k in sorted(pairs[0][0]["hashes"]):
        cv = [a["hashes"][k] for a, _ in pairs]
        dv = [b["hashes"][k] for _, b in pairs]
        hashes[k] = {"control": sorted(set(cv)), "candidate": sorted(set(dv)),
                     "control_stable": len(set(cv)) == 1, "candidate_stable": len(set(dv)) == 1,
                     "equal": len(set(cv)) == 1 and set(cv) == set(dv)}
    result = {
        "schema": "terminal-render-bench.summary.v1", "mode": "compare", "pairs": len(pairs), "order": order, "builds": manifests,
        "config": pairs[0][0]["config"], "metrics": metrics, "pixel_hashes": hashes,
        "pixel_hashes_all_equal": all(h["equal"] for h in hashes.values()),
        "verdict_counts_vs_noise_floor": counts if noise else None,
        "environment": {"control": env([a for a, _ in pairs]), "candidate": env([b for _, b in pairs])},
    }
    json.dump(result, open(os.path.join(out, "summary.json"), "w"), indent=2, sort_keys=True)
    print("%-48s %11s %11s %7s %6s %9s" % ("metric", "ctrl median", "cand median", "ratio", "impr", "maxpair%"))
    for k in keys:
        m = result["metrics"][k]
        print("%-48s %11.6f %11.6f %7.3f %3d/%-2d %8.1f%%" % (k, m["control"]["median"], m["candidate"]["median"], m["median_ratio_candidate_over_control"] or 0, m["pairs_improved"], m["pairs"], 100 * (m["max_abs_pair_rel_delta"] or 0)))
    print("pixel hashes: %d keys, all equal control==candidate: %s" % (len(hashes), result["pixel_hashes_all_equal"]))
    for k, h in hashes.items():
        if not h["equal"]: print("  PIXEL MISMATCH or unstable:", k, "control_stable=%s candidate_stable=%s" % (h["control_stable"], h["candidate_stable"]))
    if noise: print("verdicts vs baseline noise floor:", counts)
PYEOF
if [ -n "$NOISE_FLOOR" ]; then python3 "$OUTPUT/summarize.py" "$MODE" "$OUTPUT" "$NOISE_FLOOR"; else python3 "$OUTPUT/summarize.py" "$MODE" "$OUTPUT"; fi
echo "terminal render bench complete: mode=$MODE repetitions=$REPS output=$OUTPUT"
