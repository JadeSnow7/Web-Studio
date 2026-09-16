#!/usr/bin/env python3
"""Produce repeatable terminal load output and record process samples.

This utility deliberately reports only process observations.  It does not
claim to measure frame time, input latency, or GPU work.
"""

from __future__ import annotations

import argparse
import json
import platform
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


CPU_TIME = re.compile(r"^(?:(?P<hours>\d+):)?(?P<minutes>\d+):(?P<seconds>\d+(?:\.\d+)?)$")
PS_FIELDS = ("pid", "ppid", "etime", "time", "%cpu", "rss", "command")


def parse_cpu_time(value: str) -> float:
    """Parse macOS ps cumulative CPU time into seconds."""
    text = value.strip()
    match = CPU_TIME.fullmatch(text)
    if not match:
        raise ValueError(f"unsupported ps CPU time: {value!r}")
    hours = float(match.group("hours") or 0)
    minutes = float(match.group("minutes"))
    seconds = float(match.group("seconds"))
    return hours * 3600 + minutes * 60 + seconds


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def deterministic_line(kind: str, line: int) -> str:
    if kind == "ascii":
        return f"ASCII line={line:06d} ansi=\x1b[38;5;{line % 256}m payload={line * 17 % 1000003:07d}\x1b[0m"
    # Keep combining marks and a supplementary-plane emoji in every row so
    # the same code-point sequence exercises width handling on each run.
    return f"Unicode line={line:06d} 中文 e\u0301 cafe\u0301 🚀 rgb=\x1b[38;2;{line % 256};{(line * 3) % 256};{(line * 7) % 256}m{line * 19 % 1000003:07d}\x1b[0m"


def write_load(kind: str, lines: int, stream: Any = None) -> tuple[int, int, int]:
    if kind not in {"ascii", "unicode"}:
        raise ValueError(f"unsupported load kind: {kind}")
    if lines < 0:
        raise ValueError("lines must be non-negative")
    output = stream or sys.stdout.buffer
    begin = f"BEGIN TERMINAL-BENCHMARK kind={kind} requested_lines={lines}\n".encode()
    output.write(begin)
    payload_bytes = 0
    actual_lines = 0
    for line in range(lines):
        encoded = (deterministic_line(kind, line) + "\n").encode("utf-8")
        output.write(encoded)
        payload_bytes += len(encoded)
        actual_lines += 1
    total_bytes = len(begin) + payload_bytes
    done = b""
    for _ in range(3):
        done = f"DONE TERMINAL-BENCHMARK kind={kind} lines={actual_lines} payload_bytes={payload_bytes} total_bytes={total_bytes} note=output_bytes_not_pty_bytes\n".encode()
        next_total = len(begin) + payload_bytes + len(done)
        if next_total == total_bytes:
            break
        total_bytes = next_total
    output.write(done)
    output.flush()
    return actual_lines, payload_bytes, total_bytes


def ps_sample(pid: int) -> dict[str, Any]:
    command = ["ps", "-p", str(pid), "-o", ",".join(f"{field}=" for field in PS_FIELDS)]
    monotonic_started = time.monotonic()
    sample: dict[str, Any] = {
        "timestamp": utc_now(),
        "monotonic_started": monotonic_started,
        "monotonic_ended": monotonic_started,
        "argv": command,
        "returncode": None,
        "stdout": "",
        "stderr": "",
    }
    try:
        completed = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError as exc:
        sample["monotonic_ended"] = time.monotonic()
        sample["error_type"] = type(exc).__name__
        sample["error"] = str(exc)
        sample["observation_status"] = "permission_error" if isinstance(exc, PermissionError) else "ps_error"
        return sample
    sample["monotonic_ended"] = time.monotonic()
    sample["returncode"] = completed.returncode
    sample["stdout"] = completed.stdout
    sample["stderr"] = completed.stderr
    lines = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    if completed.returncode != 0:
        stderr = completed.stderr.lower()
        sample["observation_status"] = "permission_error" if "operation not permitted" in stderr or "permission denied" in stderr else "process_exited" if "no such process" in stderr or "no process" in stderr else "ps_error"
    elif not lines:
        sample["observation_status"] = "format_error"
    else:
        row = lines[-1]
        values = row.split(None, 6)
        if len(values) >= 6:
            try:
                sample["pid"] = int(values[0])
                sample["cumulative_cpu_seconds"] = parse_cpu_time(values[3])
                sample["rss_kb"] = int(values[5])
                sample["command"] = values[6] if len(values) == 7 else ""
                sample["observation_status"] = "observed"
            except (TypeError, ValueError):
                sample["observation_status"] = "format_error"
        else:
            sample["observation_status"] = "format_error"
    return sample


def summarize_samples(samples: list[dict[str, Any]], expected_pid: int | None = None) -> dict[str, Any]:
    """Summarize only fields observed from valid ps samples."""
    valid = [s for s in samples if s.get("observation_status") == "observed" and (expected_pid is None or s.get("pid") == expected_pid) and "cumulative_cpu_seconds" in s and "rss_kb" in s]
    statuses = {s.get("observation_status") for s in samples}
    process_state = "observed"
    for candidate in ("permission_error", "process_exited", "ps_error", "format_error"):
        if candidate in statuses:
            process_state = candidate
            break
    cpu_delta = None
    cpu_share = None
    actual_elapsed = None
    cpu_sampling_status = "insufficient"
    if len(valid) >= 2:
        decreases = any(current["cumulative_cpu_seconds"] < previous["cumulative_cpu_seconds"] for previous, current in zip(valid, valid[1:]))
        cpu_delta = valid[-1]["cumulative_cpu_seconds"] - valid[0]["cumulative_cpu_seconds"]
        actual_elapsed = max(0.0, valid[-1]["monotonic_ended"] - valid[0]["monotonic_started"])
        if decreases:
            cpu_sampling_status = "invalid_counter_decrease"
            cpu_delta = None
        elif actual_elapsed > 0:
            cpu_share = cpu_delta / actual_elapsed * 100
            cpu_sampling_status = "sufficient"
        else:
            cpu_sampling_status = "insufficient_elapsed_time"
    return {
        "sample_count": len(samples),
        "valid_sample_count": len(valid),
        "cpu_time_delta_seconds": cpu_delta,
        "actual_sample_elapsed_seconds": actual_elapsed,
        "interval_cpu_percent_estimate": cpu_share,
        "cpu_sampling_status": cpu_sampling_status,
        "process_state": process_state,
        "rss_kb_min": min((s["rss_kb"] for s in valid), default=None),
        "rss_kb_max": max((s["rss_kb"] for s in valid), default=None),
        "process_disappeared": process_state == "process_exited",
    }


def sample_process(pid: int, duration: float, interval: float, output: Path) -> int:
    if pid <= 0 or duration <= 0 or interval <= 0:
        raise ValueError("pid, duration, and interval must be positive")
    output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    samples: list[dict[str, Any]] = []
    while True:
        sample = ps_sample(pid)
        samples.append(sample)
        if time.monotonic() - started >= duration:
            break
        time.sleep(min(interval, max(0.0, duration - (time.monotonic() - started))))
    summary = summarize_samples(samples, expected_pid=pid)
    ended_at = utc_now()
    result = {
        "schema_version": 1,
        "pid": pid,
        "started_at": samples[0]["timestamp"] if samples else utc_now(),
        "ended_at": ended_at,
        "cli_argv": list(sys.argv),
        "cwd": str(Path.cwd()),
        "duration_requested_seconds": duration,
        "interval_requested_seconds": interval,
        "system": {"platform": platform.platform(), "release": platform.release(), "python": sys.version},
        "sampling": {
            "source": "ps cumulative CPU time and RSS",
            "cpu_percent": "interval estimate from cumulative CPU delta / actual monotonic time between first and last valid ps samples; ps historical %CPU is retained only as raw output",
            "precision": "ps output precision and wall-clock scheduling introduce sampling error",
            "frame_time": "unavailable",
            "input_latency": "unavailable",
            "gpu": "unavailable",
            "rss": "discrete samples and min/max range, not peak RSS",
            "scope": "one explicitly selected process; CPU percentage may exceed 100% on multicore systems",
            "time_boundary": "sample elapsed time includes ps command execution and scheduling overhead",
        },
        "limitations": [
            "load payload byte counts describe this process output, not bytes transmitted through a PTY",
            "CPU and RSS observations describe one PID only; RSS min/max is not a peak measurement",
        ],
        "samples": samples,
        "summary": {
            **summary,
        },
    }
    with output.open("x", encoding="utf-8", newline="\n") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    return 0 if summary["cpu_sampling_status"] == "sufficient" and summary["process_state"] == "observed" else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    output = subparsers.add_parser("output")
    output.add_argument("--kind", choices=("ascii", "unicode"), required=True)
    output.add_argument("--lines", type=int, default=10000)
    sample = subparsers.add_parser("sample")
    sample.add_argument("--pid", type=int, required=True)
    sample.add_argument("--duration", type=float, required=True)
    sample.add_argument("--interval", type=float, required=True)
    sample.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "output":
            write_load(args.kind, args.lines)
            return 0
        return sample_process(args.pid, args.duration, args.interval, args.output)
    except (FileExistsError, OSError, ValueError) as exc:
        print(f"terminal-benchmark: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
