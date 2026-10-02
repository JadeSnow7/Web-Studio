#!/usr/bin/env python3
"""Bounded non-UI coordinator for M2 paired terminal measurements."""
from __future__ import annotations
import argparse, hashlib, json, os, random, subprocess, sys, time, uuid, math, re
from pathlib import Path

MAX_WAIT = 60.0
ACTIVE_PROCS=[]
LAST_RUN_DIR=None
def clock(): return time.clock_gettime(getattr(time, "CLOCK_MONOTONIC_RAW", time.CLOCK_MONOTONIC))
def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as f: json.dump(value, f, ensure_ascii=False, sort_keys=True); f.write("\n")
def replace_json(path, value):
    tmp=path.with_suffix(path.suffix+".tmp")
    with tmp.open("w", encoding="utf-8") as f: json.dump(value, f, ensure_ascii=False, sort_keys=True); f.write("\n")
    os.replace(tmp,path)
def wait_file(path, deadline):
    while clock()<deadline:
        if path.exists(): return json.loads(path.read_text(encoding="utf-8"))
        time.sleep(.05)
    raise TimeoutError(path.name)
def process_summary(pid):
    if not pid: return {"status":"unavailable"}
    r=subprocess.run(["ps","-p",str(pid),"-o","pid=,pcpu=,rss="],capture_output=True,text=True,check=False)
    fields=r.stdout.split()
    return {"status":"observed","pid":int(fields[0]),"cpu_percent":float(fields[1]),"rss_kb":int(fields[2])} if len(fields)>=3 else {"status":"exited"}
def background_snapshot(exclude=()):
    excluded={int(x) for x in exclude if x}
    try: ps=subprocess.run(["ps","-axo","pid=,pcpu=,rss="],capture_output=True,text=True,check=False,timeout=3)
    except (OSError,subprocess.TimeoutExpired): return {"status":"unavailable","monotonic":clock()}
    if ps.returncode!=0: return {"status":"unavailable","monotonic":clock()}
    rows=[]
    for raw in ps.stdout.splitlines():
        fields=raw.split()
        if len(fields)!=3 or not fields[0].isdigit(): continue
        try: row={"pid":int(fields[0]),"cpu_percent":float(fields[1]),"rss_kb":int(fields[2])}
        except ValueError: continue
        if not math.isfinite(row["cpu_percent"]) or row["cpu_percent"]<0 or row["rss_kb"]<0: continue
        if row["pid"] not in excluded: rows.append(row)
    rows.sort(key=lambda x:(-x["cpu_percent"],-x["rss_kb"],x["pid"]))
    result={"status":"observed","monotonic":clock(),"process_count":len(rows),"cpu_percent_sum":sum(x["cpu_percent"] for x in rows),"rss_kb_sum":sum(x["rss_kb"] for x in rows),"top5":rows[:5]}
    for cmd in (["memory_pressure","-Q"],["pmset","-g","therm"]):
        try:
            r=subprocess.run(cmd,capture_output=True,text=True,check=False,timeout=3)
            if cmd[0]=="memory_pressure":
                m=re.search(r"free percentage:\s*([0-9]+(?:\.[0-9]+)?)%",r.stdout,re.I)
                result[cmd[0]]={"status":"observed","free_percent":float(m.group(1))} if r.returncode==0 and m else {"status":"unavailable"}
            else:
                if "No thermal warning level has been recorded" in r.stdout: result[cmd[0]]={"status":"no_recorded_warning"}
                elif r.returncode!=0 or "Error" in r.stdout: result[cmd[0]]={"status":"unavailable"}
                else:
                    limits={k:float(v) for k,v in re.findall(r"(CPU_Speed_Limit|Scheduler_Limit)\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)",r.stdout)}
                    result[cmd[0]]={"status":"observed","limits":limits} if limits else {"status":"unavailable"}
        except (OSError,subprocess.TimeoutExpired): result[cmd[0]]={"status":"unavailable"}
    return result
def wait_result(path, command_id, deadline):
    offset=0
    while clock()<deadline:
        if path.exists():
            with path.open(encoding="utf-8") as f:
                f.seek(offset)
                while True:
                    raw=f.readline()
                    if not raw: break
                    offset += len(raw.encode("utf-8"))
                    try: row=json.loads(raw)
                    except json.JSONDecodeError: continue
                    if row.get("id")==command_id:
                        if row.get("dsr",{}).get("matches") is False: raise RuntimeError("dsr_mismatch")
                        return row
        time.sleep(.05)
    raise TimeoutError("result:"+command_id)
def ancestry(pid, root):
    chain=[]; current=pid
    for _ in range(8):
        raw=subprocess.run(["ps","-p",str(current),"-o","ppid="],capture_output=True,text=True,check=False).stdout.strip()
        if not raw.isdigit(): break
        parent=int(raw); chain.append({"pid":current,"ppid":parent})
        if parent==root: return chain
        if parent<=1: break
        current=parent
    raise RuntimeError("child_ancestry_mismatch")
def command(control, op, **fields):
    row={"id":str(uuid.uuid4()),"op":op,**fields}
    with control.open("a",encoding="utf-8") as f: f.write(json.dumps(row,ensure_ascii=False,sort_keys=True)+"\n"); f.flush()
    return row["id"]
def validate_scene(scene, scenario):
    if scene.get("status")!="observed" or scene.get("visible")!=(scenario=="visible-idle"): raise RuntimeError("scene_mismatch")
def validate_sample(path, returncode):
    if returncode != 0 or not path.exists(): raise RuntimeError("sampler_failed")
    data=json.loads(path.read_text(encoding="utf-8"))
    if data.get("sampling_status")!="valid": raise RuntimeError("invalid_sampler_result")
    return data
def validate_ui_actions(path, start, end, scene):
    if not path.exists(): raise RuntimeError("missing_ui_actions")
    data=json.loads(path.read_text(encoding="utf-8"))
    if data.get("status")!="observed" or data.get("scene")!=scene or data.get("verified") is not True: raise RuntimeError("invalid_ui_actions")
    count=data.get("action_count")
    if not isinstance(count,int) or not 2<=count<=40: raise RuntimeError("invalid_ui_action_count")
    if not isinstance(data.get("started_monotonic"),(int,float)) or not isinstance(data.get("ended_monotonic"),(int,float)): raise RuntimeError("invalid_ui_action_times")
    if not start < data["started_monotonic"] < data["ended_monotonic"] < end: raise RuntimeError("ui_actions_outside_sample")
    return data
def validate_concurrent_result(row, *, require_dsr=False):
    if row.get("status") != "complete": raise RuntimeError("concurrent_result_failed")
    if require_dsr:
        if row.get("dsr_matches") is not True: raise RuntimeError("concurrent_dsr_mismatch")
        return row
    if [x.get("seq") for x in row.get("received", [])] != list(range(20)): raise RuntimeError("concurrent_input_mismatch")
    if [x.get("seq") for x in row.get("output", [])] != list(range(200)): raise RuntimeError("concurrent_output_mismatch")
    if [x.get("seq") for x in row.get("echoes", [])] != list(range(20)): raise RuntimeError("concurrent_echo_mismatch")
    if row.get("dsr", {}).get("status") != "observed": raise RuntimeError("concurrent_dsr_mismatch")
    return row
def validate_concurrent_window(row, sample_start, sample_end):
    if not sample_start <= row.get("started", 0) <= row.get("ended", 0) <= row.get("dsr", {}).get("reply_end", 0) <= sample_end:
        raise RuntimeError("concurrent_outside_sample")
def set_stage(path, run_id, stage, **extra): replace_json(path,{"schema":"web-studio.terminal-m2.current.v1","run_id":run_id,"stage":stage,"monotonic":clock(),**extra})

def find_apps(root):
    paths=[]
    for app in sorted(Path(root).glob("*.app")):
        bins=list((app/"Contents"/"MacOS").glob("*"))
        if bins: paths.append(bins[0])
    return paths
def parse_app_map(raw):
    try: items=json.loads(raw)
    except json.JSONDecodeError as exc: raise ValueError("invalid app map JSON") from exc
    if not isinstance(items,list) or len(items)!=2: raise ValueError("app map must contain exactly two entries")
    labels=[]; result=[]
    for item in items:
        if not isinstance(item,dict) or not isinstance(item.get("label"),str) or not re.fullmatch(r"[A-Za-z0-9_.-]+",item["label"]): raise ValueError("invalid app label")
        path=item.get("path")
        if item["label"] in labels or not isinstance(path,str) or not os.path.isabs(path) or not os.path.isfile(path) or not os.access(path,os.X_OK): raise ValueError("invalid app path or duplicate label")
        labels.append(item["label"]); result.append((item["label"],Path(path)))
    return result

def _one_run(args, app, backend, scenario, pair, order, root):
    global LAST_RUN_DIR
    rid=f"{backend}-{scenario}-{pair}-{uuid.uuid4()}"; run=root/rid; run.mkdir(parents=True)
    LAST_RUN_DIR=run
    current=run/"current.json"; set_stage(current,rid,"ui-start",backend=backend,scenario=scenario,pair=pair,order=order)
    command_line=[str(app),"--appearance-dark"]
    child_tool = "terminal-m2-concurrent.py" if scenario == "concurrent" else "terminal-m2-investigate.py"
    exchange={"pid":None,"backend":backend,"scenario":scenario,"pair":pair,"run_id":rid,"child_dir":str(run/"child"),"command":["/usr/bin/python3",str(Path(__file__).resolve().with_name(child_tool)),"--child","--output",str(run/"child")],"app_path":str(app),"app_sha256":hashlib.sha256(app.read_bytes()).hexdigest() if app.exists() else None}
    replace_json(root/"current.json",{"run_dir":str(run),"exchange":exchange,"stage":"ui-start","run_id":rid}) if (root/"current.json").exists() else write_json(root/"current.json",{"run_dir":str(run),"exchange":exchange,"stage":"ui-start","run_id":rid})
    write_json(run/"exchange.json",exchange)
    proc=None
    if not args.dry_run:
        env={"PATH":"/usr/bin:/bin","LC_ALL":"C.UTF-8","HOME":os.environ.get("HOME","/private/tmp")}
        proc=subprocess.Popen(command_line,env=env,cwd=str(run),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        ACTIVE_PROCS.append(proc)
        exchange["pid"]=proc.pid; exchange["target_process_before"] = process_summary(proc.pid); replace_json(run/"exchange.json",exchange)
        replace_json(root/"current.json",{"run_dir":str(run),"exchange":exchange,"stage":"waiting-ready","run_id":rid})
    set_stage(current,rid,"waiting-ready")
    if args.dry_run:
        write_json(run/"ui-ready.json",{"status":"dry-run","columns":134,"rows":45})
        if scenario in ("visible-idle", "hidden-idle"):
            write_json(run/"ui-scene-ready.json",{"status":"dry-run","columns":134,"rows":45})
    ui=wait_file(run/"ui-ready.json",clock()+args.setup_timeout)
    if ui.get("status")=="dry-run" and not args.dry_run: raise RuntimeError("invalid ui-ready")
    if ui.get("columns",134)!=134 or ui.get("rows",45)!=45: raise RuntimeError("grid_mismatch")
    child=run/"child"; control=child/"control.jsonl"; result=child/"result.jsonl"
    if args.dry_run: child.mkdir(exist_ok=True)
    if not args.dry_run:
        ready = wait_file(child/"ready.jsonl",clock()+args.timeout)
        child_pid=int(ready.get("pid",0)); chain=ancestry(child_pid,proc.pid)
        exchange["child_pid"]=child_pid; exchange["pid_chain"]=chain; replace_json(run/"exchange.json",exchange)
        if scenario == "concurrent":
            if ready.get("grid") != {"columns":134,"rows":45}: raise RuntimeError("child_grid_mismatch")
        elif ready.get("terminal_size") not in ({"columns":134,"rows":45},{"columns":134,"rows":45}): raise RuntimeError("child_grid_mismatch")
    if scenario == "concurrent":
        set_stage(current,rid,"waiting-warmup")
        for n in (1,2):
            set_stage(current,rid,"waiting-concurrent-input",phase_index=n)
            phase=run/f"ui-phase-{n}-ready.json"
            if args.dry_run: write_json(phase,{"status":"observed","phase":n})
            receipt=wait_file(phase,clock()+args.setup_timeout)
            if receipt.get("status")!="observed" or receipt.get("phase")!=n: raise RuntimeError("concurrent_phase_handshake")
            reset_id=command(control,"reset")
            if not args.dry_run: validate_concurrent_result(wait_result(result,reset_id,clock()+args.timeout),require_dsr=True)
            warm_id=command(control,"start",seconds=20,interval=.1)
            set_stage(current,rid,"waiting-warmup",warmup_index=n,start_id=warm_id)
            if not args.dry_run: validate_concurrent_result(wait_result(result,warm_id,clock()+args.timeout+25))
        set_stage(current,rid,"waiting-concurrent-input",phase_index=3)
        phase=run/"ui-phase-3-ready.json"
        if args.dry_run: write_json(phase,{"status":"observed","phase":3})
        receipt=wait_file(phase,clock()+args.setup_timeout)
        if receipt.get("status")!="observed" or receipt.get("phase")!=3: raise RuntimeError("concurrent_phase_handshake")
        final_reset=command(control,"reset")
        if not args.dry_run: validate_concurrent_result(wait_result(result,final_reset,clock()+args.timeout),require_dsr=True)
        set_stage(current,rid,"measuring-concurrent")
        sample=run/"sample.json"
        if args.dry_run:
            write_json(sample,{"status":"dry-run","duration":23}); sample_start=clock(); sample_end=sample_start+20; command(control,"start",seconds=20,interval=.1)
            write_json(run/"ui-actions.json",{"status":"observed","scene":scenario,"started_monotonic":sample_start+1,"ended_monotonic":sample_start+2,"action_count":2,"verified":True})
        else:
            before_snapshot=background_snapshot((proc.pid,)); sampler=subprocess.Popen(["/usr/bin/python3",str(Path(__file__).with_name("terminal-m2-investigate.py")),"sample","--pid",str(proc.pid),"--expected-path",str(app),"--duration","23","--interval",".05","--output",str(sample)],env={"PATH":"/usr/bin:/bin","LC_ALL":"C.UTF-8"},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); ACTIVE_PROCS.append(sampler)
            time.sleep(1); start_id=command(control,"start",seconds=20,interval=.1); set_stage(current,rid,"measuring-action",start_id=start_id); sampler.wait(timeout=28); data=validate_sample(sample,sampler.returncode); sample_start=data["samples"][0]["monotonic"]; sample_end=data["samples"][-1]["monotonic"]; after_snapshot=background_snapshot((proc.pid,)); measured=validate_concurrent_result(wait_result(result,start_id,clock()+args.timeout));
            if not sample_start <= measured.get("started", 0) <= measured.get("ended", 0) <= measured.get("dsr", {}).get("reply_end", 0) <= sample_end: raise RuntimeError("concurrent_outside_sample")
        actions=run/"ui-actions.json"; 
        if not args.dry_run: wait_file(actions,clock()+args.setup_timeout)
        validate_ui_actions(actions,sample_start,sample_end,scenario)
        set_stage(current,rid,"ui-finish");
        if args.dry_run: write_json(run/"ui-finish.json",{"status":"dry-run"})
        wait_file(run/"ui-finish.json",clock()+args.setup_timeout); command(control,"quit")
        if proc: proc.wait(timeout=args.timeout)
        write_json(run/"run-summary.json",{"schema":"web-studio.terminal-m2.run-summary.v1","run_id":rid,"backend":backend,"scenario":scenario,"pair":pair,"order":order,"app_path":str(app),"pid":proc.pid if proc else None,"background_before":before_snapshot if not args.dry_run else {"status":"dry-run"},"background_after":after_snapshot if not args.dry_run else {"status":"dry-run"},"status":"dry-run" if args.dry_run else "complete","sample_path":str(sample),"summary":"fixed 23s App CPU envelope; concurrent child start20s; UI actions do not establish presentation latency"})
        return
    if scenario in ("visible-idle","hidden-idle"):
        set_stage(current,rid,"warming")
        for _ in (1,2):
            reset_id=command(control,"reset"); load_id=command(control,"load",kind="mixed",lines=10000,grid_rows=45)
            if not args.dry_run: wait_result(result,reset_id,clock()+args.timeout); wait_result(result,load_id,clock()+args.timeout)
        final_reset=command(control,"reset")
        if not args.dry_run: wait_result(result,final_reset,clock()+args.timeout)
        final_load=command(control,"load",kind="mixed",lines=10000,grid_rows=45)
        if not args.dry_run: wait_result(result,final_load,clock()+args.timeout)
        if not args.dry_run: time.sleep(2)
        if not args.dry_run: time.sleep(2)
        set_stage(current,rid,"waiting-scene")
        wait_file(run/"ui-scene-ready.json",clock()+args.setup_timeout)
        scene=json.loads((run/"ui-scene-ready.json").read_text(encoding="utf-8"))
        if not args.dry_run: validate_scene(scene,scenario)
        set_stage(current,rid,"measuring")
        before_snapshot=background_snapshot((proc.pid,) if proc else ()) if not args.dry_run else {"status":"dry-run"}
        sample=run/"sample.json"
        if not args.dry_run:
            sampler=subprocess.Popen(["/usr/bin/python3",str(Path(__file__).with_name("terminal-m2-investigate.py")),"sample","--pid",str(proc.pid),"--expected-path",str(app),"--duration","20","--interval",".05","--output",str(sample)],env={"PATH":"/usr/bin:/bin","LC_ALL":"C.UTF-8"},cwd=str(run),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); ACTIVE_PROCS.append(sampler)
            sampler.wait(timeout=25)
            validate_sample(sample,sampler.returncode)
            after_snapshot=background_snapshot((proc.pid,) if proc else ())
        else: write_json(sample,{"status":"dry-run","duration":20})
        set_stage(current,rid,"ui-finish")
        if args.dry_run: write_json(run/"ui-finish.json",{"status":"dry-run"})
        wait_file(run/"ui-finish.json",clock()+args.setup_timeout)
        command(control,"quit")
        if proc:
            try: proc.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired: raise RuntimeError("failed_app_exit_timeout")
        write_json(run/"run-summary.json",{"schema":"web-studio.terminal-m2.run-summary.v1","run_id":rid,"backend":backend,"scenario":scenario,"pair":pair,"order":order,"app_path":str(app),"pid":proc.pid if proc else None,"background_before":before_snapshot,"background_after":after_snapshot if not args.dry_run else {"status":"dry-run"},"status":"dry-run" if args.dry_run else "complete","sample_path":str(sample)})
        return
    if scenario in ("history-scroll", "resize"):
        set_stage(current,rid,"warming")
        for _ in (1,2):
            reset_id=command(control,"reset"); load_id=command(control,"load",kind="mixed",lines=10000,grid_rows=45)
            if not args.dry_run: wait_result(result,reset_id,clock()+args.timeout); wait_result(result,load_id,clock()+args.timeout)
        final_reset=command(control,"reset")
        if not args.dry_run: wait_result(result,final_reset,clock()+args.timeout)
        final_load=command(control,"load",kind="mixed",lines=10000,grid_rows=45)
        if not args.dry_run: wait_result(result,final_load,clock()+args.timeout)
        if not args.dry_run: time.sleep(2)
        set_stage(current,rid,"waiting-scene")
        if args.dry_run: write_json(run/"ui-scene-ready.json",{"status":"observed","scene":scenario,"columns":134,"rows":45})
        scene=wait_file(run/"ui-scene-ready.json",clock()+args.setup_timeout)
        if scene.get("status")!="observed" or scene.get("scene")!=scenario: raise RuntimeError("scene_mismatch")
        sample=run/"sample.json"; sample_start=None; sample_end=None
        if args.dry_run:
            sample_start=clock(); sample_end=sample_start+20; write_json(sample,{"status":"dry-run","duration":20})
        else:
            before_snapshot=background_snapshot((proc.pid,))
            sampler=subprocess.Popen(["/usr/bin/python3",str(Path(__file__).with_name("terminal-m2-investigate.py")),"sample","--pid",str(proc.pid),"--expected-path",str(app),"--duration","20","--interval",".05","--output",str(sample)],env={"PATH":"/usr/bin:/bin","LC_ALL":"C.UTF-8"},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); ACTIVE_PROCS.append(sampler)
            time.sleep(1); set_stage(current,rid,"measuring-action");
            sampler.wait(timeout=25); data=validate_sample(sample,sampler.returncode); sample_start=data["samples"][0]["monotonic"]; sample_end=data["samples"][-1]["monotonic"]
            after_snapshot=background_snapshot((proc.pid,))
        actions=run/"ui-actions.json"
        if args.dry_run: write_json(actions,{"status":"observed","scene":scenario,"started_monotonic":sample_start+1,"ended_monotonic":sample_start+2,"action_count":2,"verified":True})
        if args.dry_run: sample_start, sample_end = sample_start or clock(), sample_end or clock()+3
        if not args.dry_run: wait_file(actions,clock()+args.setup_timeout)
        validate_ui_actions(actions,sample_start,sample_end,scenario)
        set_stage(current,rid,"ui-finish")
        if args.dry_run: write_json(run/"ui-finish.json",{"status":"dry-run"})
        wait_file(run/"ui-finish.json",clock()+args.setup_timeout); command(control,"quit")
        write_json(run/"run-summary.json",{"schema":"web-studio.terminal-m2.run-summary.v1","run_id":rid,"backend":backend,"scenario":scenario,"pair":pair,"order":order,"app_path":str(app),"pid":proc.pid if proc else None,"background_before":before_snapshot if not args.dry_run else {"status":"dry-run"},"background_after":after_snapshot if not args.dry_run else {"status":"dry-run"},"status":"dry-run" if args.dry_run else "complete","sample_path":str(sample),"summary":"fixed 20s App CPU envelope includes UI observation wait; no throughput or frame latency inference"})
        if proc: proc.wait(timeout=args.timeout)
        return
    set_stage(current,rid,"warming")
    for n in (1,2):
        reset_id=command(control,"reset")
        load_id=command(control,"load",kind="mixed" if scenario=="history" else scenario,lines=10000,grid_rows=45)
        if not args.dry_run: wait_result(result,reset_id,clock()+args.timeout); wait_result(result,load_id,clock()+args.timeout)
    final_reset=command(control,"reset")
    if not args.dry_run: wait_result(result,final_reset,clock()+args.timeout)
    if not args.dry_run: time.sleep(2)
    set_stage(current,rid,"measuring")
    sample=run/"sample.json"; before_snapshot=background_snapshot((proc.pid,) if proc else ()) if not args.dry_run else {"status":"dry-run"}
    if not args.dry_run:
        sampler=subprocess.Popen(["/usr/bin/python3",str(Path(__file__).with_name("terminal-m2-investigate.py")),"sample","--pid",str(proc.pid),"--expected-path",str(app),"--duration","5","--interval",".05","--output",str(sample)],env={"PATH":"/usr/bin:/bin","LC_ALL":"C.UTF-8"},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        ACTIVE_PROCS.append(sampler)
        time.sleep(1)
    load_id=command(control,"load",kind="mixed" if scenario=="history" else scenario,lines=10000,grid_rows=45)
    if args.dry_run: write_json(sample,{"status":"dry-run"})
    elif wait_result(result,load_id,clock()+args.timeout).get("dsr",{}).get("matches") is not True: raise RuntimeError("load_dsr_not_confirmed")
    if not args.dry_run:
        sampler.wait(timeout=args.timeout)
        validate_sample(sample,sampler.returncode)
        after_snapshot=background_snapshot((proc.pid,) if proc else ())
    set_stage(current,rid,"ui-finish",load_id=load_id)
    if args.dry_run: write_json(run/"ui-finish.json",{"status":"dry-run"})
    wait_file(run/"ui-finish.json",clock()+args.setup_timeout)
    command(control,"quit")
    summary={"schema":"web-studio.terminal-m2.run-summary.v1","run_id":rid,"backend":backend,"scenario":scenario,"pair":pair,"order":order,"app_path":str(app),"pid":proc.pid if proc else None,"sample_path":str(sample),"child_result_path":str(result),"background_before":before_snapshot,"background_after":after_snapshot if not args.dry_run else {"status":"dry-run"},"target_process_after":process_summary(proc.pid if proc else None),"status":"dry-run" if args.dry_run else "awaiting-verification"}
    write_json(run/"run-summary.json",summary)
    if proc:
        try: proc.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired: summary["status"]="failed_app_exit_timeout"; replace_json(run/"run-summary.json",summary); raise RuntimeError("failed_app_exit_timeout")

def one_run(args, app, backend, scenario, pair, order, root):
    try: return _one_run(args, app, backend, scenario, pair, order, root)
    except Exception as exc:
        run=LAST_RUN_DIR
        if run is not None:
            summary=run/"run-summary.json"
            data={"schema":"web-studio.terminal-m2.run-summary.v1","run_id":run.name,"backend":backend,"scenario":scenario,"pair":pair,"status":"failed","error_type":type(exc).__name__}
            if summary.exists():
                try: data={**json.loads(summary.read_text(encoding="utf-8")),"status":"failed","error_type":type(exc).__name__}
                except json.JSONDecodeError: pass
            if summary.exists(): replace_json(summary,data)
            else: write_json(summary,data)
        raise
    finally:
        for proc in list(ACTIVE_PROCS):
            if proc.poll() is None:
                try: proc.terminate(); proc.wait(timeout=2)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=2)
            ACTIVE_PROCS.remove(proc)

def main(argv=None):
    p=argparse.ArgumentParser(); p.add_argument("--output",required=True); p.add_argument("--apps-root",required=True); p.add_argument("--app-map"); p.add_argument("--start-pair",type=int,default=1); p.add_argument("--pairs",type=int,default=6); p.add_argument("--scenarios",nargs="+",choices=("ascii","chinese","mixed","visible-idle","hidden-idle","history-scroll","resize","concurrent"),default=["ascii","chinese","mixed"]); p.add_argument("--limit-runs",type=int); p.add_argument("--timeout",type=float,default=MAX_WAIT); p.add_argument("--setup-timeout",type=float,default=300); p.add_argument("--dry-run",action="store_true")
    a=p.parse_args(argv)
    if a.start_pair<1 or a.start_pair>100 or a.pairs<=0 or a.pairs>100 or a.start_pair+a.pairs-1>100 or a.timeout<=0 or a.timeout>MAX_WAIT or a.setup_timeout<=0 or a.setup_timeout>600: p.error("start-pair/pairs/timeout out of bounds")
    root=Path(a.output).expanduser().resolve()
    if root.exists(): raise SystemExit("output exists; refusing overwrite")
    if a.app_map:
        mapped=parse_app_map(a.app_map); first,second=mapped
        root_vt,root_legacy=first[1],second[1]
        labels=(first[0],second[0])
    else:
        root_vt=Path(a.apps_root)/"vt-control.app/Contents/MacOS/Web Studio VT"
        root_legacy=Path(a.apps_root)/"legacy-normalized.app/Contents/MacOS/Web Studio"
        labels=("vt","legacy")
    if not a.dry_run and (not root_vt.exists() or not root_legacy.exists()): raise SystemExit("explicit vt/legacy app mapping missing")
    vt=root_vt if root_vt.exists() else Path("/dry-run/vt")
    legacy=root_legacy if root_legacy.exists() else Path("/dry-run/legacy")
    jobs=[]
    for pair in range(a.start_pair,a.start_pair+a.pairs):
        backends=[(labels[0],vt),(labels[1],legacy)] if pair%2 else [(labels[1],legacy),(labels[0],vt)]
        for scenario in a.scenarios:
            for backend,app in backends: jobs.append((app,backend,scenario,pair,"-".join(x[0] for x in backends)))
    if a.limit_runs: jobs=jobs[:a.limit_runs]
    root.mkdir(parents=True)
    for app,b,s,pair,order in jobs: one_run(a,app,b,s,pair,order,root)
    return 0
if __name__=="__main__":
    try: raise SystemExit(main())
    except (OSError,RuntimeError,TimeoutError,ValueError) as e: print(json.dumps({"status":"failed","error_type":type(e).__name__}),file=sys.stderr); raise SystemExit(2)
