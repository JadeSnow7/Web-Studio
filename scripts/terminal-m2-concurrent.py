#!/usr/bin/env python3
"""Bounded real-TTY concurrent input/output fixture."""
import argparse, errno, fcntl, hashlib, json, os, re, resource, select, sys, termios, time, tty, uuid
from pathlib import Path
MAX=20.0; LIMIT=1024*1024; LINE=4096; CURSOR=re.compile(rb"\x1b\[(\d+);(\d+)R")
CLOCK=getattr(time,"CLOCK_MONOTONIC_RAW",time.CLOCK_MONOTONIC)
def mono(): return time.clock_gettime(CLOCK)
def append(p,row):
    with p.open("a",encoding="utf-8") as f: f.write(json.dumps(row,sort_keys=True)+"\n")
def write_all(fd,data,deadline):
    old=fcntl.fcntl(fd,fcntl.F_GETFL); fcntl.fcntl(fd,fcntl.F_SETFL,old|os.O_NONBLOCK); n=0
    try:
        while n<len(data):
            if mono()>=deadline:return n,mono(),"timeout"
            try:
                wrote=os.write(fd,data[n:])
                if wrote==0:return n,mono(),"zero_write"
                n+=wrote
            except InterruptedError:continue
            except BlockingIOError:select.select([], [fd], [], max(0,deadline-mono()))
            except OSError as e:return n,mono(),"permission_error" if e.errno in (errno.EPERM,errno.EACCES) else "write_error"
        return n,mono(),None
    finally:fcntl.fcntl(fd,fcntl.F_SETFL,old)
def usage():
    x=resource.getrusage(resource.RUSAGE_SELF); return {"user_seconds":x.ru_utime,"system_seconds":x.ru_stime,"max_rss":x.ru_maxrss}
def result(path,rid,row):append(path,{"run_id":rid,**row})
def final_status(received, outputs, partial, errors):
    if partial:return "failed_partial_input"
    if errors:return "failed_"+errors[0]
    if [x["seq"] for x in received]!=list(range(20)):return "failed_input_sequence"
    if len(outputs)!=200:return "failed_output_count"
    return "complete"
def child(argv):
    p=argparse.ArgumentParser();p.add_argument("--output",required=True);a=p.parse_args(argv);out=Path(a.output)
    out=out.expanduser().resolve()
    if out.exists():raise FileExistsError(out)
    if not os.isatty(0) or not os.isatty(1):raise RuntimeError("stdin_stdout_must_be_tty")
    out.mkdir(parents=True);control=out/"control.jsonl";res=out/"result.jsonl";events=out/"events.jsonl";rid=str(uuid.uuid4());saved=termios.tcgetattr(0);tty.setraw(0);offset=0
    try:
        size=os.get_terminal_size(1)
        with (out/"ready.jsonl").open("x") as f:f.write(json.dumps({"run_id":rid,"pid":os.getpid(),"grid":{"columns":size.columns,"rows":size.lines},"tool_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"clock_source":"CLOCK_MONOTONIC_RAW"})+"\n")
        seen_ids=set()
        while True:
            if control.exists():
                with control.open(encoding="utf-8") as f:
                    f.seek(offset)
                    while True:
                        raw=f.readline()
                        if not raw:break
                        if not raw.endswith("\n"): break
                        offset+=len(raw.encode())
                        if len(raw)>LINE: result(res,rid,{"status":"failed","error_type":"control_line_limit"}); continue
                        try:c=json.loads(raw)
                        except json.JSONDecodeError: result(res,rid,{"status":"failed","error_type":"control_json"});continue
                        if not isinstance(c,dict) or not isinstance(c.get("id"),str):result(res,rid,{"status":"failed","error_type":"missing_command_id"});continue
                        cid=c["id"];op=c.get("op")
                        if cid in seen_ids: result(res,rid,{"id":cid,"status":"failed","error_type":"duplicate_command_id"}); continue
                        seen_ids.add(cid)
                        if op=="reset":
                            t=mono();n,we,e=write_all(1,b"\x1bc\x1b[2J\x1b[3J\x1b[H\x1b[6n",t+3); reply=b""; m=None
                            while mono()<t+3 and not m:
                                ready,_,_=select.select([0],[],[],.05)
                                if ready:
                                    chunk=os.read(0,4096)
                                    if not chunk: break
                                    reply+=chunk; m=CURSOR.search(reply)
                            ok=bool(m and m.group(1)==b"1" and m.group(2)==b"1")
                            result(res,rid,{"id":cid,"op":op,"status":"complete" if ok and not e else "failed","started":t,"bytes":n,"write_end":we,"dsr_matches":ok,"error_type":e or (None if ok else "dsr_mismatch_or_timeout")}); continue
                        if op=="start":
                            if c.get("seconds",20)!=20 or c.get("interval",.1)!=.1: result(res,rid,{"id":cid,"status":"failed","error_type":"invalid_schedule"}); continue
                            t=mono();append(events,{"id":cid,"run_id":rid,"event":"start-loop","monotonic":t,"clock_source":"CLOCK_MONOTONIC_RAW"});before=usage();received=[];partial=b"";input_bytes=0;outs=[];echoes=[];total=0;outdigest=hashlib.sha256();indigest=hashlib.sha256();echodigest=hashlib.sha256();errors=[]; deadline=t+MAX
                            while mono()<deadline:
                                now=mono();
                                if len(outs)<200 and now>=t+len(outs)*.1:
                                    payload=f"OUTPUT seq={len(outs)}\r\n".encode();n,te,e=write_all(1,payload,deadline);total+=n;outdigest.update(payload[:n]);outs.append({"seq":len(outs),"scheduled":t+len(outs)*.1,"actual":te,"bytes":n})
                                    if e: errors.append(e);break
                                ready,_,_=select.select([0],[],[],.01)
                                if ready:
                                    data=os.read(0,4096)
                                    if not data: errors.append("eof"); break
                                    input_bytes+=len(data); partial+=data; indigest.update(data)
                                    if input_bytes>LIMIT or len(partial)>4096: errors.append("input_limit"); break
                                    while b"\n" in partial:
                                        raw,partial=partial.split(b"\n",1); raw=raw.rstrip(b"\r");m=re.fullmatch(rb"INPUT seq=(\d+)",raw)
                                        if not m: errors.append("input_protocol"); break
                                        seq=int(m.group(1));received.append({"seq":seq,"monotonic":mono(),"bytes":len(raw)+1});
                                        ep=f"ECHO seq={seq}\r\n".encode();en,ee,err=write_all(1,ep,deadline);total+=en;echodigest.update(ep[:en]); echoes.append({"seq":seq,"actual":ee,"bytes":en})
                                        if err: errors.append("echo_write"); break
                                    if errors: break
                            status=final_status(received,outs,partial,errors); loop_end=mono(); dsr={"status":"skipped"}
                            if status=="complete":
                                n,write_end,write_error=write_all(1,b"\x1b[6n",loop_end+1); reply=b""; match=None
                                while mono()<loop_end+1 and not match:
                                    ready,_,_=select.select([0],[],[],.02)
                                    if ready:
                                        chunk=os.read(0,4096)
                                        if not chunk: break
                                        reply+=chunk; match=CURSOR.search(reply)
                                dsr={"status":"observed" if match and not write_error else "failed","write_end":write_end,"reply_end":mono(),"bytes_written":n,"observed":{"row":int(match.group(1)),"column":int(match.group(2))} if match else None,"error_type":write_error or (None if match else "dsr_timeout"),"completion":"DSR round trip; not presentation"}
                                if dsr["status"] != "observed": status="failed_dsr"
                            after=usage(); result(res,rid,{"id":cid,"op":op,"status":status,"started":t,"ended":loop_end,"received":received,"input_bytes":input_bytes,"input_sha256":indigest.hexdigest(),"output":outs,"echoes":echoes,"total_bytes":total,"output_sha256":outdigest.hexdigest(),"echo_sha256":echodigest.hexdigest(),"errors":errors,"usage_before":before,"usage_after":after,"cpu_delta":{"user_seconds":after["user_seconds"]-before["user_seconds"],"system_seconds":after["system_seconds"]-before["system_seconds"]},"dsr":dsr,"completion":"child loop, echo writes and DSR round trip; not presentation"});continue
                        if op=="quit":result(res,rid,{"id":cid,"status":"ok"});return 0
                        result(res,rid,{"id":cid,"status":"failed","error_type":"invalid_command"})
            time.sleep(.01)
    finally:termios.tcsetattr(0,termios.TCSANOW,saved)
def main():
    raw=sys.argv[1:]
    try:return child(raw[raw.index("--child")+1:]) if "--child" in raw else (_ for _ in ()).throw(RuntimeError("child_only"))
    except (OSError,ValueError,RuntimeError,FileExistsError) as e:print(json.dumps({"status":"failed","error_type":type(e).__name__}),file=sys.stderr);return 2
if __name__=="__main__":raise SystemExit(main())
