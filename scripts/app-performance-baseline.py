#!/usr/bin/env python3
"""Bounded non-UI application baseline sampler using the existing libproc sampler."""
from __future__ import annotations
import argparse, hashlib, importlib.util, json, math, os, sys, time
from pathlib import Path
from typing import Any

MAX_DURATION, MAX_INTERVAL, MIN_INTERVAL = 20.0, 20.0, 0.01
DEFAULT_INTERVAL = 0.25
spec = importlib.util.spec_from_file_location("terminal_m2_investigate", Path(__file__).with_name("terminal-m2-investigate.py"))
if spec is None or spec.loader is None: raise RuntimeError("cannot load terminal sampler")
m2 = importlib.util.module_from_spec(spec); spec.loader.exec_module(m2)

def monotonic() -> float: return m2.mono()

def binary_sha256(path: str) -> str | None:
    try:
        d = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""): d.update(chunk)
        return d.hexdigest()
    except OSError: return None

def validate_identity(pid: int, expected_path: str) -> dict[str, Any]:
    ident = m2.identity(pid); expected = os.path.realpath(os.path.expanduser(expected_path))
    if ident.get("status") != "alive": raise ValueError(f"target identity unavailable: {ident.get('status')}")
    observed = ident.get("executable_path")
    if not isinstance(observed, str) or os.path.realpath(observed) != expected: raise ValueError("target executable does not match expected executable")
    if not isinstance(ident.get("uuid"), str) or not ident["uuid"]:
        raise ValueError("target process UUID unavailable")
    if not isinstance(ident.get("start_abstime"), int) or ident["start_abstime"] <= 0:
        raise ValueError("target process start time unavailable")
    digest = binary_sha256(observed)
    if digest is None: raise ValueError("target executable hash cannot be determined")
    ident = dict(ident); ident.update({"expected_executable": expected, "binary_sha256": digest, "status": "validated"}); return ident

def observation(value: Any) -> dict[str, Any]: return {"value": value, "verified": False, "source": "caller_observation"}

def sample_once(usage: Any, sampled_at: float) -> dict[str, Any]:
    try: row = dict(usage.sample())
    except (OSError, ValueError, RuntimeError) as exc: return {"status":"failed", "error":type(exc).__name__, "sampled_at_monotonic":sampled_at}
    row["sampled_at_monotonic"] = sampled_at
    if row.get("status") != "observed": row.update({"status":"failed", "error":row.get("error_type", "sampler_unavailable")}); return row
    for key in ("cpu_user_seconds", "cpu_system_seconds", "resident_bytes"):
        value = row.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            row.update({"status":"failed", "error":f"invalid_{key}"}); return row
    total_cpu = row["cpu_user_seconds"] + row["cpu_system_seconds"]
    if not math.isfinite(total_cpu):
        row.update({"status":"failed", "error":"invalid_cumulative_cpu_seconds"}); return row
    row["cumulative_cpu_seconds"] = total_cpu
    row["cpu_counter_semantics"] = "libproc cumulative user+system process time"
    row["rss_bytes_discrete"] = row["resident_bytes"]
    row["rss_semantics"] = "discrete resident_bytes sample; not peak RSS"
    return row

def collect(pid: int, expected_path: str, output: Path, duration: float, interval: float, context: dict[str, Any]) -> dict[str, Any]:
    if output.exists(): raise FileExistsError(str(output))
    if not 0 < duration <= MAX_DURATION: raise ValueError(f"duration must be > 0 and <= {MAX_DURATION:g} seconds")
    if not MIN_INTERVAL <= interval <= MAX_INTERVAL: raise ValueError(f"interval must be between {MIN_INTERVAL:g} and {MAX_INTERVAL:g} seconds")
    ident = validate_identity(pid, expected_path)
    usage = m2.ProcUsage(pid)
    started = monotonic()
    deadline = started + duration
    samples = []
    while True:
        now = monotonic(); samples.append(sample_once(usage, now))
        if now >= deadline: break
        time.sleep(min(interval, max(0.0, deadline - now)))
    ended = monotonic()
    valid = [s for s in samples if s.get("status") == "observed"]
    sample_identity_stable = all(
        sample.get("uuid") == ident["uuid"]
        and sample.get("start_abstime") == ident["start_abstime"]
        for sample in valid
    )
    regression = any(
        b["cumulative_cpu_seconds"] < a["cumulative_cpu_seconds"]
        for a, b in zip(valid, valid[1:])
    )
    end_ident = m2.identity(pid)
    end_path = end_ident.get("executable_path")
    end_hash = binary_sha256(end_path) if isinstance(end_path, str) else None
    stable = (
        end_ident.get("status") == "alive"
        and end_ident.get("uuid") == ident["uuid"]
        and end_ident.get("start_abstime") == ident["start_abstime"]
        and os.path.realpath(end_path or "") == ident["expected_executable"]
        and end_hash == ident["binary_sha256"]
    )
    failure = None
    if len(valid) < 2: failure = "insufficient_valid_samples"
    elif len(valid) != len(samples): failure = "failed_sample"
    elif not sample_identity_stable: failure = "sample_identity_changed"
    elif regression: failure = "cpu_counter_regression"
    elif not stable: failure = "pid_reuse_or_identity_changed"
    status = "valid" if failure is None else "failed"
    return {
        "schema": "web-studio.app-performance-baseline.v2",
        "sampling_status": status,
        "failure": failure,
        "pid": pid,
        "identity": ident,
        "identity_end": end_ident,
        "identity_stable": stable,
        "binary_hash_stable": end_hash == ident["binary_sha256"],
        "sample_identity_stable": sample_identity_stable,
        "duration_requested_seconds": duration,
        "duration_observed_seconds": ended - started,
        "interval_requested_seconds": interval,
        "sample_count_observed": len(samples),
        "sample_count_valid": len(valid),
        "sample_count_failed": len(samples) - len(valid),
        "samples": samples,
        "cumulative_cpu_seconds_delta": (
            valid[-1]["cumulative_cpu_seconds"] - valid[0]["cumulative_cpu_seconds"]
            if status == "valid" else None
        ),
        "rss_bytes_discrete_min": min((s["rss_bytes_discrete"] for s in valid), default=None),
        "rss_bytes_discrete_max": max((s["rss_bytes_discrete"] for s in valid), default=None),
        "rss_peak": None,
        "rss_note": "RSS values are discrete observations; peak RSS is unavailable from this sampler.",
        "context": {
            key: observation(context.get(key))
            for key in ("backend", "scenario", "resource_count", "visibility")
        },
        "started_monotonic": started,
        "ended_monotonic": ended,
    }

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__); p.add_argument("--pid",type=int,required=True); p.add_argument("--expected-executable",required=True); p.add_argument("--duration",type=float,required=True); p.add_argument("--interval",type=float,default=DEFAULT_INTERVAL); p.add_argument("--output",required=True); p.add_argument("--backend"); p.add_argument("--scenario"); p.add_argument("--resource-count",type=int); p.add_argument("--visibility"); a=p.parse_args(argv); out=Path(a.output).expanduser().resolve()
    try:
        result=collect(a.pid,a.expected_executable,out,a.duration,a.interval,{"backend":a.backend,"scenario":a.scenario,"resource_count":a.resource_count,"visibility":a.visibility}); out.parent.mkdir(parents=True,exist_ok=True)
        with out.open("x",encoding="utf-8") as f: json.dump(result,f,ensure_ascii=False,sort_keys=True); f.write("\n")
        return 0 if result["sampling_status"] == "valid" else 1
    except (FileExistsError,ValueError,OSError) as exc: print(json.dumps({"status":"failed","error":str(exc)},ensure_ascii=False),file=sys.stderr); return 2
if __name__ == "__main__": raise SystemExit(main())
