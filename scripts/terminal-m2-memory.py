#!/usr/bin/env python3
"""Bounded, redacted heap/vmmap summaries for one verified macOS process."""
from __future__ import annotations
import argparse, ctypes, errno, fcntl, json, math, os, re, selectors, signal, subprocess, tempfile, time
from pathlib import Path

COMMAND_LIMIT = 5.0
TOTAL_LIMIT = 256 * 1024 * 1024
MAX_CAPTURE = TOTAL_LIMIT
SAFE_ENV = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"}

def mono() -> float: return time.monotonic()

def executable_path(pid: int) -> str | None:
    if pid <= 0 or os.uname().sysname != "Darwin": return None
    try:
        lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        buf = ctypes.create_string_buffer(4096)
        lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        lib.proc_pidpath.restype = ctypes.c_uint32
        return os.fsdecode(buf.value) if lib.proc_pidpath(pid, buf, len(buf)) > 0 else None
    except OSError:
        return None

def verify_identity(pid: int, expected: str) -> dict:
    expected = str(Path(expected).expanduser().resolve())
    if pid <= 0: return {"status": "invalid_pid"}
    try: os.kill(pid, 0)
    except ProcessLookupError: return {"status": "process_exited"}
    except PermissionError: return {"status": "permission_error"}
    actual = executable_path(pid)
    if actual is None: return {"status": "identity_unavailable"}
    return {"status": "observed" if actual == expected else "identity_mismatch", "path_match": actual == expected}

def _num(value: str) -> int | None:
    try:
        n = int(value.replace(",", ""))
        return n if n >= 0 else None
    except ValueError: return None

def _bytes(value: str, unit: str | None) -> int | None:
    try:
        n = float(value.replace(",", "")); scale = {None: 1, "B": 1, "K": 1024, "KB": 1024, "KIB": 1024, "M": 1024**2, "MB": 1024**2, "MIB": 1024**2, "G": 1024**3, "GB": 1024**3, "GIB": 1024**3}.get((unit or "B").upper())
        if scale is None or not math.isfinite(n) or n < 0: return None
        return int(n * scale)
    except (ValueError, OverflowError): return None

def parse_heap(text: str) -> dict:
    # heap's numeric summary is accepted only with its COUNT/BYTES header,
    # a nodes total, and internally consistent count/byte/average rows.
    lines = text.splitlines()
    if not any(re.search(r"\bCOUNT\b.*\bBYTES\b", line, re.I) for line in lines):
        return {"status": "unavailable", "reason": "unknown_format"}
    nodes = {_num(m.group(1)) for line in lines for m in [re.search(r"(\d[\d,]*)\s+nodes\b", line, re.I)] if m}
    nodes.discard(None)
    rows = []
    for line in lines:
        m = re.match(r"^\s*(\d[\d,]*)\s+(\d[\d,]*)\s+(\d+(?:\.\d+)?)\s+.+?\s*$", line)
        if not m: continue
        count, bytes_ = _num(m.group(1)), _num(m.group(2))
        try: average = float(m.group(3))
        except ValueError: average = -1
        if count is None or bytes_ is None or not math.isfinite(average) or average < 0:
            return {"status": "unavailable", "reason": "invalid_numeric_row"}
        if count == 0 or abs(bytes_ / count - average) >= .11:
            return {"status": "unavailable", "reason": "average_mismatch"}
        rows.append((count, bytes_))
    if len(nodes) != 1 or not rows or sum(x[0] for x in rows) != next(iter(nodes)):
        return {"status": "unavailable", "reason": "node_total_mismatch"}
    return {"status": "observed", "total_nodes": next(iter(nodes)), "total_bytes": sum(x[1] for x in rows)}

def parse_vmmap(text: str) -> dict:
    footprint = None; malloc = None
    for line in text.splitlines():
        low = line.lower()
        fm = re.search(r"^\s*physical\s+footprint:\s*(\d[\d,]*(?:\.\d+)?)\s*(b|k|kb|kib|m|mb|mib|g|gb|gib)?\s*$", low)
        if fm: footprint = _bytes(fm.group(1), fm.group(2))
    if footprint is None: return {"status": "unavailable", "reason": "unknown_format", "malloc": {"status": "unavailable", "reason": "unverified_schema"}}
    out = {"status": "observed", "malloc": {"status": "unavailable", "reason": "unverified_schema"}}
    if footprint is not None: out["physical_footprint_bytes"] = footprint
    if malloc is not None: out["malloc_bytes"] = malloc
    return out

def run_bounded(argv: list[str], deadline: float, tempdir: Path, max_bytes: int = MAX_CAPTURE) -> tuple[str, bytes]:
    if mono() >= deadline: return "timeout", b""
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                stdin=subprocess.DEVNULL, env=SAFE_ENV, cwd=str(tempdir),
                                start_new_session=True)
    except OSError as exc:
        return ("permission_error" if exc.errno in (errno.EPERM, errno.EACCES) else "launch_error"), b""
    data = bytearray(); sel = selectors.DefaultSelector(); fd = proc.stdout.fileno(); flags = fcntl.fcntl(fd, fcntl.F_GETFL); fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK); sel.register(fd, selectors.EVENT_READ)
    try:
        while True:
            remaining = deadline - mono()
            if remaining <= 0: return "timeout", bytes(data)
            events = sel.select(min(.1, remaining))
            for key, _ in events:
                try: chunk = os.read(key.fd, 65536)
                except BlockingIOError: continue
                if chunk:
                    data.extend(chunk)
                    if len(data) > max_bytes: return "size_cap", bytes(data)
                else: sel.unregister(key.fd)
            rc = proc.poll()
            if rc is not None:
                while True:
                    try: chunk = os.read(fd, 65536)
                    except BlockingIOError: break
                    if not chunk: break
                    data.extend(chunk)
                    if len(data) > max_bytes: return "size_cap", bytes(data)
                return ("ok" if rc == 0 else "tool_failed"), bytes(data)
    finally:
        if proc.poll() is None:
            try: os.killpg(proc.pid, signal.SIGKILL)
            except OSError: pass
            try: proc.wait(timeout=.5)
            except subprocess.TimeoutExpired: pass
        try: proc.stdout.close()
        except (OSError, AttributeError): pass
        sel.close()

def main(argv=None) -> int:
    p = argparse.ArgumentParser(); p.add_argument("--pid", type=int, required=True); p.add_argument("--expected-executable", required=True); p.add_argument("--output", required=True)
    a = p.parse_args(argv); out = Path(a.output).expanduser().resolve()
    if out.exists(): raise FileExistsError(out)
    ident = verify_identity(a.pid, a.expected_executable)
    if ident.get("status") != "observed":
        out.parent.mkdir(parents=True, exist_ok=True); out.open("x").write(json.dumps({"schema":"web-studio.terminal-m2.memory.v1","status":"failed","error_type":ident["status"]})+"\n"); return 1
    root = Path(tempfile.mkdtemp(prefix="web-studio-m2-memory-", dir="/private/tmp")); os.chmod(root, 0o700)
    started = mono(); results = {}; status = "complete"; remaining_bytes = TOTAL_LIMIT
    try:
        for name, argv, parser in (("heap", ["/usr/bin/heap", "-q", "-s", "--noContent", str(a.pid)], parse_heap), ("vmmap", ["/usr/bin/vmmap", "-summary", str(a.pid)], parse_vmmap)):
            state, raw = run_bounded(argv, min(started + 10, mono() + COMMAND_LIMIT), root, remaining_bytes)
            remaining_bytes -= len(raw)
            results[name] = parser(raw.decode("utf-8", "replace")) if state == "ok" else {"status": "unavailable", "reason": state}
            if state not in ("ok",): status = "failed_" + state
            if state == "size_cap": break
        for name in ("heap", "vmmap"):
            results.setdefault(name, {"status": "unavailable", "reason": "total_size_cap"})
    finally:
        for child in root.iterdir(): child.unlink(missing_ok=True)
        root.rmdir()
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("x") as f: json.dump({"schema":"web-studio.terminal-m2.memory.v1","status":status,"pid":a.pid,"identity_status":"observed","heap":results["heap"],"vmmap":results["vmmap"]}, f, sort_keys=True); f.write("\n")
    return 0 if status == "complete" else 1

if __name__ == "__main__": raise SystemExit(main())
