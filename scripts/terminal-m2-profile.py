#!/usr/bin/env python3
"""Bounded, secret-safe xctrace wrapper for the M2 investigation.

The wrapper intentionally emits metadata only. xctrace's stdout/stderr are
captured in a mode-0700 temporary directory and are never copied to the
terminal or result JSON. It does not launch or alter the profiled process.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import re
import stat
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

PILOT_SECONDS, PILOT_BYTES = 5.0, 256 * 1024 * 1024
EXTENDED_SECONDS, EXTENDED_BYTES = 20.0, 1024 * 1024 * 1024
WALL_WATCHDOG_SECONDS = 50.0
SAMPLE_DURATION_SECONDS, SAMPLE_WALL_SECONDS = 5.0, 20.0
ENV_ALLOWLIST = ("HOME", "PATH", "TMPDIR", "LANG")


def monotonic() -> float:
    return time.monotonic()


def safe_env(tmpdir: Path | None = None) -> dict[str, str]:
    """Return a fixed, minimal environment; never inherit arbitrary variables."""
    return {"HOME": os.environ.get("HOME", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": str(tmpdir or os.environ.get("TMPDIR", "/tmp")),
            "LANG": os.environ.get("LANG", "C.UTF-8")}


def executable_for_pid(pid: int) -> str | None:
    if pid <= 0:
        return None
    if sys.platform == "darwin":
        try:
            lib = ctypes.CDLL("/usr/lib/libproc.dylib")
            buf = ctypes.create_string_buffer(4096)
            lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
            n = lib.proc_pidpath(pid, buf, len(buf))
            if n > 0:
                return os.fsdecode(buf.value)
        except OSError:
            pass
    try:
        p = subprocess.run(["ps", "-p", str(pid), "-o", "comm="],
                           capture_output=True, text=True, timeout=2,
                           env={"PATH": "/usr/bin:/bin"}, check=False)
        value = p.stdout.strip()
        return value or None
    except (OSError, subprocess.SubprocessError):
        return None


def validate_target(pid: int, expected: str) -> dict[str, Any]:
    if pid <= 0:
        raise ValueError("pid must be positive")
    try:
        os.kill(pid, 0)
    except ProcessLookupError as exc:
        raise ValueError("target process is not alive") from exc
    except PermissionError as exc:
        raise ValueError("target process cannot be inspected") from exc
    actual = executable_for_pid(pid)
    if not actual:
        raise ValueError("target executable cannot be determined")
    wanted = os.path.realpath(expected)
    matches = os.path.realpath(actual) == wanted
    if not matches:
        raise ValueError("target executable does not match expected executable")
    return {"pid": pid, "expected_executable": wanted,
            "observed_executable": os.path.basename(actual), "status": "validated"}


def tree_size(path: Path) -> int:
    if not path.exists():
        return 0
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def private_parent(path: Path) -> None:
    if path.exists() and stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise ValueError("output directory must be private")
    path.mkdir(parents=True, mode=0o700, exist_ok=True)


def _trace_command(xctrace: str, pid: int, trace: Path, seconds: float) -> list[str]:
    prefix = [xctrace]
    if Path(xctrace).name == "xcrun":
        prefix.append("xctrace")
    return prefix + ["record", "--quiet", "--template", "Time Profiler", "--attach",
                     str(pid), "--time-limit", f"{seconds:g}s", "--no-prompt",
                     "--output", str(trace)]


def classify_error(data: bytes, *, timed_out: bool = False) -> str:
    if timed_out:
        return "timeout"
    text = data.decode("utf-8", "replace").lower()
    if "unknown command" in text or "unknown option" in text:
        return "unknown_command"
    if "permission" in text or "not permitted" in text or "denied" in text:
        return "permission_denied"
    if "attach" in text or "examine process" in text:
        return "attach_failed"
    return "other"


def record_profile(pid: int, expected: str, output: Path, *, extended: bool,
                   xctrace: str = "xcrun", poll: float = 0.1,
                   finish_timeout: float = 5.0) -> dict[str, Any]:
    seconds, limit = ((EXTENDED_SECONDS, EXTENDED_BYTES) if extended else
                      (PILOT_SECONDS, PILOT_BYTES))
    if output.exists():
        raise FileExistsError(str(output))
    target = validate_target(pid, expected)
    private_parent(output.parent)
    scratch = Path(tempfile.mkdtemp(prefix="m2-xctrace-"))
    os.chmod(scratch, 0o700)
    trace = output
    stdout_path, stderr_path = scratch / "stdout", scratch / "stderr"
    started = monotonic()
    interrupted = False
    timed_out = False
    over_limit = False
    error_class = "other"
    proc: subprocess.Popen[bytes] | None = None
    try:
        with open(stdout_path, "wb", opener=lambda p, m: os.open(p, m, 0o600)) as out, \
             open(stderr_path, "wb", opener=lambda p, m: os.open(p, m, 0o600)) as err:
            proc = subprocess.Popen(_trace_command(xctrace, pid, trace, seconds),
                                    stdout=out, stderr=err, env=safe_env(scratch), close_fds=True)
            deadline = started + WALL_WATCHDOG_SECONDS
            while proc.poll() is None:
                if tree_size(trace) > limit:
                    over_limit = True
                    proc.send_signal(signal.SIGINT)
                    interrupted = True
                    break
                if monotonic() >= deadline:
                    timed_out = True
                    proc.send_signal(signal.SIGINT)
                    interrupted = True
                    break
                time.sleep(min(poll, 0.25))
            if proc.poll() is None:
                try:
                    proc.wait(timeout=finish_timeout)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2)
                    timed_out = True
            error_class = classify_error(stderr_path.read_bytes() if stderr_path.exists() else b"",
                                         timed_out=timed_out)
    finally:
        ended = monotonic()
        # Do not retain xctrace's potentially sensitive logs.
        shutil.rmtree(scratch, ignore_errors=True)
    trace_validation = safe_export(trace, xctrace=xctrace) if trace.exists() else {"status": "missing"}
    ok = bool(proc and proc.returncode == 0 and not interrupted and not over_limit and not timed_out
              and trace_validation.get("status") == "exported")
    return {"schema": "web-studio.terminal-m2.profile.v1", "status": "recorded" if ok else "failed",
            "target": target, "trace": str(output), "mode": "extended" if extended else "pilot",
            "record_duration_requested_seconds": seconds, "wall_watchdog_seconds": WALL_WATCHDOG_SECONDS,
            "size_limit_bytes": limit,
            "trace_size_bytes": tree_size(trace), "started_monotonic": started,
            "wall_duration_seconds": ended - started, "trace_validation": trace_validation,
            "error_classification": error_class,
            "ended_monotonic": ended, "duration_seconds": ended - started,
            "returncode": proc.returncode if proc else None,
            "interrupted_for_limit_or_timeout": interrupted,
            "over_size_limit": over_limit, "timed_out": timed_out}


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def safe_export(trace: Path, *, xctrace: str = "xcrun") -> dict[str, Any]:
    if not trace.is_file() and not trace.is_dir():
        raise FileNotFoundError(str(trace))
    scratch = Path(tempfile.mkdtemp(prefix="m2-xctrace-export-"))
    os.chmod(scratch, 0o700)
    xml_path, out_path, err_path = scratch / "toc.xml", scratch / "stdout", scratch / "stderr"
    try:
        prefix = [xctrace] + (["xctrace"] if Path(xctrace).name == "xcrun" else [])
        with open(out_path, "wb", opener=lambda p, m: os.open(p, m, 0o600)) as out, \
             open(err_path, "wb", opener=lambda p, m: os.open(p, m, 0o600)) as err:
            p = subprocess.Popen(prefix + ["export", "--quiet", "--input", str(trace), "--toc", "--output", str(xml_path)],
                                 stdout=out, stderr=err, env=safe_env(scratch))
            deadline = monotonic() + 30.0
            while p.poll() is None and monotonic() < deadline and tree_size(xml_path) <= PILOT_BYTES:
                time.sleep(0.1)
            export_limited = tree_size(xml_path) > PILOT_BYTES or p.poll() is None
            if p.poll() is None:
                p.send_signal(signal.SIGINT)
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill(); p.wait(timeout=2)
            if export_limited:
                return {"schema": "web-studio.terminal-m2.export.v1", "status": "bounded_out",
                        "returncode": p.returncode, "elements": 0}
        try:
            root = ET.parse(xml_path).getroot()
        except (ET.ParseError, OSError):
            return {"schema": "web-studio.terminal-m2.export.v1", "status": "invalid_xml",
                    "returncode": p.returncode, "elements": 0}
        counts: dict[str, int] = {}
        schemas: set[str] = set()
        for element in root.iter():
            name = _local(element.tag)
            counts[name] = counts.get(name, 0) + 1
            schema = element.attrib.get("schema")
            if schema and len(schema) <= 200 and all(c.isalnum() or c in "._:-" for c in schema):
                schemas.add(schema)
        # Only structural facts leave this function; environment, arguments,
        # command lines and all text payloads are intentionally discarded.
        return {"schema": "web-studio.terminal-m2.export.v1", "status": "exported" if p.returncode == 0 else "failed",
                "returncode": p.returncode, "root": _local(root.tag),
                "elements": sum(counts.values()), "element_counts": counts,
                "schema_names": sorted(schemas), "xml_sha256": hashlib.sha256(xml_path.read_bytes()).hexdigest()}
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def parse_sample(text: str) -> dict[str, list[str]]:
    """Extract only bounded sample stack sections, with addresses/paths removed."""
    graph: list[str] = []
    top: list[str] = []
    numeric_lines = 0
    parsed_numeric_lines = 0
    rejected_numeric_lines = 0
    section = ""
    for raw_line in text.splitlines():
        lower = raw_line.strip().lower()
        if lower.startswith("call graph"):
            section = "graph"; continue
        if lower.startswith("sort by top of stack"):
            section = "top"; continue
        if lower.startswith("binary images"):
            section = ""; continue
        if lower.startswith(("total number", "sort by", "sample analysis", "analysis:", "process:", "time sampled")):
            if not lower.startswith("sort by"):
                section = ""
            continue
        if not section:
            continue
        if re.match(r"^[ \t+!|:\-]*\d+\b", raw_line):
            numeric_lines += 1
        match = re.match(r"^([ \t+!|:\-]*)(\d+)\s+(.*)$", raw_line)
        if not match:
            if section == "top":
                top_match = re.match(r"^(\s+)(.+?)\s+(\d+)\s*$", raw_line)
                if not top_match:
                    continue
                body = re.sub(r"\s+\(in [^)]+\)", "", top_match.group(2))
                body = re.sub(r"0x[0-9a-fA-F]+", "<address>", body)
                body = re.sub(r"/[^\s)]+", "<path>", body).strip()
                if body:
                    top.append(f"{top_match.group(1)}{body} {top_match.group(3)}"[:500])
            if re.match(r"^[ \t+!|:\-]*\d+\b", raw_line):
                rejected_numeric_lines += 1
            continue
        body = re.sub(r"0x[0-9a-fA-F]+", "<address>", match.group(3))
        body = re.sub(r"/[^\s)]+", "<path>", body)
        body = re.sub(r"\s+", " ", body).strip()
        if body:
            sanitized = f"{match.group(1)}{match.group(2)} {body}"
            (graph if section == "graph" else top).append(sanitized[:500])
            parsed_numeric_lines += 1
    descendants = [line for line in graph if not re.search(r"\d+\s+Thread(?:_|\b)", line)]
    return {"call_graph": graph[:10000], "call_graph_descendants": descendants[:10000], "top_of_stack": top[:10000],
            "numeric_lines": numeric_lines, "parsed_numeric_lines": parsed_numeric_lines,
            "top_line_count": len(top),
            "rejected_numeric_lines": rejected_numeric_lines, "descendant_count": len(descendants)}


ALLOWED_SAMPLE_FIELDS = {"sample-time", "thread", "process", "thread-state", "weight", "backtrace", "frame", "binary"}


def parse_time_samples(text: str, target_pid: int | None = None) -> dict[str, Any]:
    """Parse time-sample XML through id/ref links and return only safe fields."""
    root = ET.fromstring(text)
    by_id = {e.attrib["id"]: e for e in root.iter() if "id" in e.attrib}

    def resolved(e: ET.Element) -> ET.Element:
        seen: set[str] = set()
        while "ref" in e.attrib and e.attrib["ref"] in by_id and e.attrib["ref"] not in seen:
            seen.add(e.attrib["ref"]); e = by_id[e.attrib["ref"]]
        return e

    def value(e: ET.Element) -> str:
        e = resolved(e)
        return " ".join(t.strip() for t in e.itertext() if t.strip())

    rows: list[dict[str, Any]] = []; threads: set[str] = set(); self_counts: dict[str, int] = {}; inclusive: dict[str, int] = {}; unknown = 0
    for row in (e for e in root.iter() if _local(e.tag) == "row"):
        fields: dict[str, str] = {}
        elements = list(row.iter())
        for child in list(row):
            resolved_child = resolved(child)
            elements.extend(x for x in resolved_child.iter() if x not in elements)
        for child in elements:
            name = _local(child.tag)
            if name in ALLOWED_SAMPLE_FIELDS:
                fields[name] = child.attrib.get("fmt") or value(child)
            if name == "pid": fields["process"] = child.attrib.get("fmt") or value(child)
        pid_text = fields.get("process", "")
        found = re.search(r"\b(?:pid|process)?\s*[:=]?\s*(\d+)\b", pid_text, re.I)
        pid_state = "undetermined" if not found else ("target" if target_pid is None or int(found.group(1)) == target_pid else "other")
        if pid_state == "other": continue
        if pid_state == "undetermined": unknown += 1; continue
        tid = fields.get("thread", "") or "undetermined"; threads.add(tid)
        frames: list[str] = []
        for child in row.iter():
            if _local(child.tag) not in {"frame", "backtrace", "binary", "text-address"}: continue
            candidate = value(child)
            candidate = re.sub(r"0x[0-9a-fA-F]+|/[^\s)]+", "", candidate)
            match = re.search(r"[A-Za-z_][A-Za-z0-9_:$<>.\-]*", candidate)
            if match: frames.append(match.group(0))
        frames = list(dict.fromkeys(frames))
        for frame in frames: inclusive[frame] = inclusive.get(frame, 0) + 1
        if frames: self_counts[frames[0]] = self_counts.get(frames[0], 0) + 1
        rows.append({k: fields[k] for k in fields if k in ALLOWED_SAMPLE_FIELDS and k != "backtrace"} | {"pid_status": pid_state, "symbols": frames})
    return {"rows": rows, "sample_count": len(rows), "unknown_pid_rows": unknown, "unique_threads": len(threads),
            "self_counts": self_counts, "inclusive_counts": inclusive,
            "interpretation": "sample weight is a sampling weight, not an exact duration"}


def sample_profile(pid: int, expected: str, output: Path) -> dict[str, Any]:
    """Capture the macOS sample call graph with a strict 5-second bound."""
    target = validate_target(pid, expected)
    if output.exists():
        raise FileExistsError(str(output))
    private_parent(output.parent)
    scratch = Path(tempfile.mkdtemp(prefix="m2-sample-")); os.chmod(scratch, 0o700)
    raw, stdout_path, stderr_path = scratch / "sample.txt", scratch / "stdout", scratch / "stderr"
    try:
        with open(stdout_path, "wb", opener=lambda p, m: os.open(p, m, 0o600)) as out, \
             open(stderr_path, "wb", opener=lambda p, m: os.open(p, m, 0o600)) as err:
            wall_started = monotonic()
            p = subprocess.Popen(["/usr/bin/sample", str(pid), "5", "1", "-file", str(raw)],
                                 stdout=out, stderr=err, env=safe_env(scratch))
            limited = False; limit_reason = None; deadline = wall_started + SAMPLE_WALL_SECONDS
            while p.poll() is None and monotonic() < deadline:
                if tree_size(scratch) > PILOT_BYTES:
                    limited = True; limit_reason = "size"; p.send_signal(signal.SIGINT); break
                time.sleep(0.1)
            if p.poll() is None:
                limited = True; limit_reason = limit_reason or "wall"; p.send_signal(signal.SIGINT)
            try: p.wait(timeout=2)
            except subprocess.TimeoutExpired: p.kill(); p.wait(timeout=2); limit_reason = limit_reason or "finalization"
            wall_seconds = monotonic() - wall_started
        text = raw.read_text(errors="replace") if raw.exists() else ""
        parsed = parse_sample(text)
        ok = bool(p.returncode == 0 and not limited and parsed["call_graph_descendants"] and parsed["top_of_stack"]
                  and parsed["numeric_lines"] == parsed["parsed_numeric_lines"])
        result = {"schema": "web-studio.terminal-m2.sample.v1", "status": "captured" if ok else "failed",
                  "target": target, "sample_seconds": SAMPLE_DURATION_SECONDS, "wall_seconds": wall_seconds,
                  "wall_limit_seconds": SAMPLE_WALL_SECONDS, "limited": limited, "limit_reason": limit_reason,
                  "call_graph": parsed["call_graph"], "top_of_stack": parsed["top_of_stack"],
                  "descendant_count": parsed["descendant_count"], "numeric_lines": parsed["numeric_lines"],
                  "parsed_numeric_lines": parsed["parsed_numeric_lines"], "rejected_numeric_lines": parsed["rejected_numeric_lines"],
                  "sample_returncode": p.returncode,
                  "interpretation": "sample call graph; includes waiting stacks and is not CPU utilization"}
        fd = os.open(output, os.O_EXCL | os.O_CREAT | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w") as result_file: result_file.write(json.dumps(result, sort_keys=True) + "\n")
        return result
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def export_samples(trace: Path, output: Path, pid: int | None = None) -> dict[str, Any]:
    if not trace.exists() or output.exists(): raise FileExistsError(str(trace if not trace.exists() else output))
    private_parent(output.parent)
    scratch = Path(tempfile.mkdtemp(prefix="m2-samples-")); os.chmod(scratch, 0o700)
    xml, out, err = scratch / "samples.xml", scratch / "stdout", scratch / "stderr"
    try:
        with open(out, "wb", opener=lambda p, m: os.open(p, m, 0o600)) as so, open(err, "wb", opener=lambda p, m: os.open(p, m, 0o600)) as se:
            p = subprocess.Popen(["xcrun", "xctrace", "export", "--quiet", "--input", str(trace), "--xpath", '/trace-toc/run[@number="1"]/data/table[@schema="time-sample"]', "--output", str(xml)], stdout=so, stderr=se, env=safe_env(scratch))
            deadline = monotonic() + 30
            while p.poll() is None and monotonic() < deadline and tree_size(scratch) <= PILOT_BYTES: time.sleep(0.1)
            limited = tree_size(scratch) > PILOT_BYTES or p.poll() is None
            if p.poll() is None: p.send_signal(signal.SIGINT); p.wait(timeout=5)
        if limited or p.returncode != 0: result = {"schema": "web-studio.terminal-m2.samples.v1", "status": "failed", "error_classification": classify_error(err.read_bytes() if err.exists() else b"", timed_out=limited)}
        else:
            parsed = parse_time_samples(xml.read_text(errors="replace"), pid)
            usable = bool(parsed["sample_count"] and parsed["inclusive_counts"])
            result = {"schema": "web-studio.terminal-m2.samples.v1", "status": "exported" if usable else "unusable", "reason": None if usable else "no_attributable_stacks_or_pid", "target_pid": pid, **parsed}
        fd = os.open(output, os.O_EXCL | os.O_CREAT | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w") as f: f.write(json.dumps(result, sort_keys=True) + "\n")
        return result
    finally: shutil.rmtree(scratch, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    rec = sub.add_parser("record")
    rec.add_argument("--pid", type=int, required=True)
    rec.add_argument("--expected-executable", required=True)
    rec.add_argument("--output", type=Path, required=True)
    rec.add_argument("--extended", action="store_true")
    rec.add_argument("--xctrace", default="xcrun")
    exp = sub.add_parser("export")
    exp.add_argument("trace", type=Path)
    exp.add_argument("--xctrace", default="xcrun")
    smp = sub.add_parser("sample")
    smp.add_argument("--pid", type=int, required=True)
    smp.add_argument("--expected-executable", required=True)
    smp.add_argument("--output", type=Path, required=True)
    xs = sub.add_parser("export-samples")
    xs.add_argument("trace", type=Path); xs.add_argument("--output", type=Path, required=True); xs.add_argument("--pid", type=int)
    args = parser.parse_args()
    try:
        if args.command == "record":
            result = record_profile(args.pid, args.expected_executable, args.output,
                                    extended=args.extended, xctrace=args.xctrace)
        elif args.command == "export":
            result = safe_export(args.trace, xctrace=args.xctrace)
        elif args.command == "sample":
            result = sample_profile(args.pid, args.expected_executable, args.output)
        else:
            result = export_samples(args.trace, args.output, args.pid)
        print(json.dumps(result, sort_keys=True))
        return 0 if result.get("status") in {"recorded", "exported", "captured"} else 1
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(json.dumps({"schema": "web-studio.terminal-m2.profile-error.v1",
                          "status": "error", "error_type": type(exc).__name__}), flush=True)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
