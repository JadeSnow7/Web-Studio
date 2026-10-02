#!/usr/bin/env python3
"""Real-TTY child workload and bounded macOS process sampler for M2."""
from __future__ import annotations
import argparse, ctypes, errno, hashlib, json, os, re, select, sys, termios, time, uuid, tty, fcntl
from pathlib import Path
from typing import Any

MAX_SECONDS = 20.0
SAMPLER_MAX_SECONDS = 25.0
MAX_BYTES = 1024 * 1024 * 1024
DSR = b"\x1b[6n"
CURSOR = re.compile(rb"\x1b\[(\d+);(\d+)R")

CLOCK = getattr(time, "CLOCK_MONOTONIC_RAW", time.CLOCK_MONOTONIC)
def mono() -> float: return time.clock_gettime(CLOCK)
def ticks_to_seconds(ticks: int, numer: int, denom: int) -> float:
    if numer <= 0 or denom <= 0: raise ValueError("invalid mach timebase")
    return ticks * numer / denom / 1_000_000_000
def append(path: Path, row: dict[str, Any]) -> None:
    with path.open("a", encoding="utf-8") as f: f.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
def exclusive(path: Path, row: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as f: f.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")

def fixture(kind: str, lines: int) -> bytes:
    if kind not in {"ascii", "chinese", "mixed"} or not 0 <= lines <= 1_000_000: raise ValueError("invalid fixture")
    rows = []
    for i in range(lines):
        if kind == "ascii": text = f"ASCII line={i:06d} payload={i * 17 % 1000003:07d}"
        elif kind == "chinese": text = f"中文第{i:06d}行 性能测量"
        else: text = f"Mixed line={i:06d} 中文 e\u0301 🚀 payload={i * 19 % 1000003:07d}"
        rows.append(text + "\r\n")
    return "".join(rows).encode("utf-8")

def write_all(fd: int, payload: bytes, deadline: float) -> tuple[int, float, str | None]:
    sent = 0
    flags = fcntl.fcntl(fd, fcntl.F_GETFL); fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    try:
        while sent < len(payload):
            if mono() >= deadline: return sent, mono(), "write_timeout"
            try: sent += os.write(fd, payload[sent:])
            except InterruptedError: continue
            except BlockingIOError: select.select([], [fd], [], max(0, deadline-mono()))
            except OSError as e: return sent, mono(), "permission_error" if e.errno in (errno.EPERM, errno.EACCES) else "write_error"
        return sent, mono(), None
    finally: fcntl.fcntl(fd, fcntl.F_SETFL, flags)

class ProcUsage:
    def __init__(self, pid: int):
        self.pid, self.source, self.lib = pid, "unavailable", None
        self.buf_type = ctypes.c_uint8 * 512
        self.timebase = (1, 1)
        if sys.platform == "darwin":
            try:
                self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
                self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
                self.lib.proc_pid_rusage.restype = ctypes.c_int
                self.source = "libproc.proc_pid_rusage"
                class Timebase(ctypes.Structure):
                    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
                info = Timebase()
                ctypes.CDLL(None).mach_timebase_info(ctypes.byref(info))
                if info.denom: self.timebase = (info.numer, info.denom)
            except OSError: pass
    def sample(self) -> dict[str, Any]:
        if not self.lib: return {"status":"unavailable", "source":self.source, "error_type":"unsupported_platform"}
        buf = self.buf_type(); rc = self.lib.proc_pid_rusage(self.pid, 4, ctypes.byref(buf))
        if rc != 0:
            e = ctypes.get_errno()
            return {"status":"permission_error" if e in (errno.EPERM, errno.EACCES) else "process_exited", "source":self.source, "returncode":rc, "errno":e}
        u = ctypes.cast(buf, ctypes.POINTER(ctypes.c_uint64))
        raw_uuid = bytes(buf[:16]).hex()
        numer, denom = self.timebase
        return {"status":"observed", "source":self.source, "uuid":raw_uuid,
                "cpu_time_unit":"mach_absolute_ticks", "mach_timebase_numer":numer, "mach_timebase_denom":denom,
                "cpu_user_ticks":int(u[2]), "cpu_system_ticks":int(u[3]),
                "cpu_user_seconds":ticks_to_seconds(int(u[2]), numer, denom), "cpu_system_seconds":ticks_to_seconds(int(u[3]), numer, denom),
                "resident_bytes":int(u[8]), "physical_footprint_bytes":int(u[9]), "start_abstime":int(u[10])}

def executable_path(pid: int) -> str | None:
    if sys.platform != "darwin": return None
    try:
        lib = ctypes.CDLL("/usr/lib/libproc.dylib"); buf = ctypes.create_string_buffer(4096)
        lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        n = lib.proc_pidpath(pid, buf, len(buf)); return os.fsdecode(buf.value) if n > 0 else None
    except OSError: return None

def identity(pid: int) -> dict[str, Any]:
    if pid <= 0: return {"status":"invalid_pid"}
    try: os.kill(pid, 0)
    except ProcessLookupError: return {"status":"process_exited"}
    except PermissionError: return {"status":"permission_error"}
    usage = ProcUsage(pid).sample(); path = executable_path(pid)
    return {"status":"alive", "pid":pid, "executable_path":path, **{k:usage.get(k) for k in ("uuid","start_abstime")}}

def await_dsr(fd: int, timeout: float, expected: dict[str,int]) -> dict[str, Any]:
    t0 = mono(); sent, end, err = write_all(fd, DSR, t0 + timeout)
    if err: return {"status":"failed", "error_type":err, "write_end":end}
    data = b""; deadline = t0 + timeout
    while mono() < deadline:
        ready, _, _ = select.select([fd], [], [], min(.05, deadline-mono()))
        if ready:
            try: data += os.read(fd, 4096)
            except OSError as e: return {"status":"failed", "error_type":"permission_error" if e.errno in (errno.EPERM,errno.EACCES) else "read_error"}
            m = CURSOR.search(data)
            if m:
                row, col = int(m.group(1)), int(m.group(2)); return {"status":"observed", "write_end":end, "reply_end":mono(), "observed":{"row":row,"column":col}, "expected":expected, "matches":expected == {"row":row,"column":col}}
    return {"status":"failed", "error_type":"dsr_timeout", "write_end":end}

def child_main(argv: list[str]) -> int:
    p=argparse.ArgumentParser(); p.add_argument("--output",required=True); a=p.parse_args(argv)
    out=Path(a.output)
    if out.exists(): raise FileExistsError(out)
    out.mkdir(parents=True); control,result=out/"control.jsonl",out/"result.jsonl"; rid=str(uuid.uuid4())
    if not os.isatty(0) or not os.isatty(1): raise RuntimeError("stdin_stdout_must_be_tty")
    saved=termios.tcgetattr(0); tty.setraw(0)
    try:
        try: size = {"columns":os.get_terminal_size(1).columns,"rows":os.get_terminal_size(1).lines}
        except OSError: size = None
        tool_hash=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        exclusive(out/"ready.jsonl", {"schema":"web-studio.terminal-m2.ready.v2","run_id":rid,"pid":os.getpid(),"monotonic":mono(),"clock_source":"CLOCK_MONOTONIC_RAW" if CLOCK==getattr(time,"CLOCK_MONOTONIC_RAW",-1) else "CLOCK_MONOTONIC","terminal_size":size,"tool_sha256":tool_hash})
        offset=0
        while True:
            if control.exists():
                with control.open(encoding="utf-8") as f:
                    f.seek(offset); chunk=f.read(); complete=chunk.rsplit("\n",1)
                    rows=complete[0].splitlines(True) if len(complete)==2 else []
                    offset += len(complete[0])+1 if len(complete)==2 else 0
                for raw in rows:
                    try: cmd=json.loads(raw)
                    except json.JSONDecodeError: append(result,{"run_id":rid,"status":"failed","error_type":"control_json"}); continue
                    if not isinstance(cmd,dict) or not isinstance(cmd.get("id"),str) or not cmd.get("id"): append(result,{"run_id":rid,"status":"failed","error_type":"missing_command_id"}); continue
                    cid=cmd["id"]; op=cmd.get("op")
                    if op=="quit": append(result,{"run_id":rid,"id":cid,"status":"ok"}); return 0
                    if op=="query-size":
                        try:
                            size = os.get_terminal_size(1)
                            append(result,{"run_id":rid,"id":cid,"op":op,"status":"observed","monotonic":mono(),"columns":size.columns,"rows":size.lines})
                        except OSError as exc:
                            append(result,{"run_id":rid,"id":cid,"op":op,"status":"failed","error_type":type(exc).__name__})
                        continue
                    if op=="reset":
                        t0=mono(); n,e,err=write_all(1,b"\x1bc\x1b[2J\x1b[3J\x1b[H",t0+3); dsr=await_dsr(0,3,{"row":1,"column":1}); append(result,{"run_id":rid,"id":cid,"op":op,"started_monotonic":t0,"bytes_written":n,"write_end":e,"error_type":err,"dsr":dsr}); continue
                    if op=="load":
                        kind=cmd.get("kind"); count=int(cmd.get("lines",0)); payload=fixture(kind,count); t0=mono(); n,we,err=write_all(1,payload,t0+min(float(cmd.get("timeout",MAX_SECONDS)),MAX_SECONDS)); grid=int(cmd.get("grid_rows",45)); dsr=await_dsr(0,min(float(cmd.get("timeout",3)),MAX_SECONDS),{"row":grid,"column":1}) if not err else {"status":"skipped","error_type":err}; append(result,{"run_id":rid,"id":cid,"op":op,"kind":kind,"lines":count,"fixture_bytes":len(payload),"fixture_sha256":hashlib.sha256(payload).hexdigest(),"started_monotonic":t0,"bytes_written":n,"write_end":we,"error_type":err,"dsr":dsr,"completion":"write plus DSR round trip; not presentation"}); continue
                    if op=="concurrent":
                        started=mono(); deadline=started+min(float(cmd.get("seconds",0)),MAX_SECONDS); rate=max(1,int(cmd.get("rate",1))); received=0; outputs=0; seqs=[]; partial=b""; next_output=started
                        while mono()<deadline:
                            wait=max(0,min(.05,deadline-mono(),next_output-mono())); ready,_,_=select.select([0],[],[],wait)
                            if ready:
                                partial+=os.read(0,4096); received=len(partial)
                                while b"\n" in partial:
                                    raw,partial=partial.split(b"\n",1); m=re.fullmatch(rb"INPUT seq=(\d+)",raw.rstrip(b"\r"))
                                    if m: seqs.append(int(m.group(1))); write_all(1,b"ECHO seq="+m.group(1)+b"\r\n",deadline)
                            if mono()>=next_output:
                                n,_,_=write_all(1,f"OUTPUT seq={outputs}\r\n".encode(),deadline); outputs+=1 if n else 0; next_output+=1.0/rate
                        append(result,{"run_id":rid,"id":cid,"op":op,"started_monotonic":started,"ended_monotonic":mono(),"stdin_bytes_received":received,"input_sequences":seqs,"output_count":outputs,"completion":"real stdin lines echoed"}); continue
                    append(result,{"run_id":rid,"id":cid,"status":"failed","error_type":"invalid_command","op":op})
            time.sleep(.01)
    finally: termios.tcsetattr(0,termios.TCSANOW,saved)

def sample_main(a: argparse.Namespace) -> int:
    if not a.expected_path: raise ValueError("expected_path_required")
    if a.duration <= 0 or a.duration > SAMPLER_MAX_SECONDS or a.interval <= 0 or a.interval > SAMPLER_MAX_SECONDS: raise ValueError("duration_interval_out_of_bounds")
    ident=identity(a.pid)
    if ident.get("status")!="alive" or ident.get("executable_path")!=a.expected_path: raise RuntimeError("identity_mismatch")
    usage=ProcUsage(a.pid); first=usage.sample(); samples=[first | {"monotonic": mono()}]; end=mono()+a.duration
    while mono()<end:
        s=usage.sample(); s["monotonic"]=mono(); samples.append(s); time.sleep(min(a.interval,max(0,end-mono())))
    valid=[s for s in samples if s.get("status")=="observed"]
    if len(samples)<2 or len(valid)!=len(samples): status="incomplete_samples"
    else:
        keys=("cpu_user_seconds","cpu_system_seconds"); status="valid"
        if any(b.get(k,0)<a0.get(k,0) for k in keys for a0,b in zip(valid,valid[1:])): status="invalid_counter_decrease"
        if any(s.get("uuid")!=ident.get("uuid") or s.get("start_abstime")!=ident.get("start_abstime") for s in valid): status="pid_reuse"
    exclusive(Path(a.output),{"schema":"web-studio.terminal-m2.sample.v2","pid":a.pid,"identity":ident,"first":first,"samples":samples,"clock_source":"CLOCK_MONOTONIC_RAW" if CLOCK==getattr(time,"CLOCK_MONOTONIC_RAW",-1) else "CLOCK_MONOTONIC","sampling_status":status}); return 0 if status=="valid" else 1

def main(argv: list[str]|None=None) -> int:
    raw=list(sys.argv[1:] if argv is None else argv)
    try:
        if "--child" in raw: return child_main(raw[raw.index("--child")+1:])
        p=argparse.ArgumentParser(); sub=p.add_subparsers(dest="cmd",required=True)
        f=sub.add_parser("fixture"); f.add_argument("--kind",choices=("ascii","chinese","mixed"),required=True); f.add_argument("--lines",type=int,default=10000)
        i=sub.add_parser("identity"); i.add_argument("--pid",type=int,required=True)
        s=sub.add_parser("sample"); s.add_argument("--pid",type=int,required=True); s.add_argument("--duration",type=float,default=5); s.add_argument("--interval",type=float,default=.25); s.add_argument("--output",required=True); s.add_argument("--expected-path",required=True)
        a=p.parse_args(raw)
        if a.cmd=="fixture": sys.stdout.buffer.write(fixture(a.kind,a.lines)); return 0
        if a.cmd=="identity": print(json.dumps(identity(a.pid),sort_keys=True)); return 0
        return sample_main(a)
    except (OSError,ValueError,RuntimeError,FileExistsError,TimeoutError) as e: print(json.dumps({"status":"failed","error_type":type(e).__name__}),file=sys.stderr); return 2
if __name__=="__main__": raise SystemExit(main())
